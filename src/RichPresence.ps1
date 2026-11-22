<#
  RichPresence  -  a game library that shows what you're playing on Discord.

  Finds the games installed on your PC (Steam, Epic, GOG, Riot, HoYoPlay, Xbox, your own folders),
  matches each one to its official Discord app, and shows "Playing <game>" while it runs.
  Also shows Apple Music and Spotify (with lyrics) and Genshin Impact stats (name, AR, UID, WL).

  Run as a script:  powershell -ExecutionPolicy Bypass -File RichPresence.ps1
  Or compile it:    .\build.ps1   ->  dist\RichPresence.exe

    -Play <id>   launch that game right away (the desktop shortcuts use this)
    -Headless    no window; run the presence engine in the console (debugging)
    -ScanOnly    print the detected games and exit (debugging)
#>
param(
    [string]$Play = '',
    [switch]$Headless,
    [switch]$ScanOnly
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$DataDir      = if ($env:RICHPRESENCE_DATA) { $env:RICHPRESENCE_DATA } else { Join-Path $env:APPDATA 'RichPresence' }
$SettingsPath = Join-Path $DataDir 'settings.json'
$LibraryPath  = Join-Path $DataDir 'library.json'
# Discord app IDs are public (not secrets) and presence is set by each user's own Discord client,
# so everyone can share these without overlapping. Three apps = three cards at once.
$DefaultGameId  = '1552433095335215165'   # "RP 2" - card for games that have no official Discord app of their own
$DefaultMusicId = '1552437427828818050'   # "RP 3" - Apple Music card
$DefaultAppId   = '1544831111128154213'   # "Playing" - current-app card
# built-in apps that custom statuses can borrow when the user hasn't made their own Discord app (one card each)
$CustomPoolIds  = @('1553178514365358100', '1553247468957990943')
$RepoUrl      = 'https://github.com/noice912/Discord-status'
$AppVersion   = '3.2.1'     # build.ps1 reads this; bump it for every release
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

# ===========================================================================
# Settings
# ===========================================================================
function New-DefaultSettings {
    [ordered]@{
        genshin_uid            = ''
        show_music             = $true      # Apple Music
        show_spotify           = $true      # Spotify, on the same card
        show_lyrics           = $true
        show_album_art         = $true
        show_current_app       = $true
        show_watching          = $true      # Netflix, Hulu, Disney+, ... playing in a browser or their Windows app
        show_watch_title       = $true      # ...with the show/movie name
        show_watch_poster      = $true      # ...and its poster (looked up on TVMaze / Cinemeta)
        show_watch_casual      = $true      # also YouTube and Twitch
        disabled_games         = @()     # game ids switched off in the library
        extra_folders          = @()     # folders whose sub-folders are games
        custom_games           = @()     # [{name, exe}] added by hand
        start_presence_on_open = $true
        exit_when_game_closes  = $false
        start_with_windows     = $false
        official_to_discord    = $true      # let Discord detect games it knows first (keeps Recent Activity / streaks)
        official_delay_minutes = 2          # ...then show our own card after this long
        auto_update            = $true      # install new releases by itself (never while a game is running)
        close_to_tray          = $true
        custom_statuses        = @()        # your own cards: text, pictures, buttons (see the Custom status page)
        custom_mode            = 'separate' # 'separate' = one card each, 'merge' = the ticked ones become one card
        overlay_enabled        = $true      # the panel over the game
        overlay_hotkey         = 'Ctrl+Alt+G'
        overlay_controller     = $true      # ...and with the Xbox / PS button on a controller
        gamebar_button_off     = $false     # stop Windows opening Xbox Game Bar on that button (a Windows setting, put back when unticked)
        gamebar_button_before  = ''         # what that Windows setting was before we changed it ('' = we haven't)
        rgb_sync               = $false     # lights follow the screen (through OpenRGB)
        rgb_brightness         = 100
    }
}
function Load-Settings {
    $s = New-DefaultSettings
    if (Test-Path $SettingsPath) {
        try {
            $j = Get-Content $SettingsPath -Raw | ConvertFrom-Json
            foreach ($k in @($s.Keys)) { if ($null -ne $j.$k) { $s[$k] = $j.$k } }
        } catch {}
    }
    foreach ($k in 'disabled_games', 'extra_folders', 'custom_games', 'custom_statuses') { $s[$k] = @($s[$k] | Where-Object { $null -ne $_ }) }
    if ($s.custom_mode -notin 'separate', 'merge') { $s.custom_mode = 'separate' }
    return $s
}
# The Discord app IDs are fixed in the program - they are never read from (or written to) settings.
function Add-BuiltInIds($s) {
    $s['game_client_id']  = $DefaultGameId
    $s['music_client_id'] = $DefaultMusicId
    $s['app_client_id']   = $DefaultAppId
    $s['custom_client_ids'] = $CustomPoolIds
    $s
}
function Save-Settings($s) { ($s | ConvertTo-Json -Depth 5) | Set-Content -Path $SettingsPath -Encoding UTF8 }

# ===========================================================================
# SCANNER - finds installed games. Runs on a background runspace.
# ===========================================================================
$Scanner = {
    param($S, $Sync, $DataDir)
    $ErrorActionPreference = 'SilentlyContinue'
    function Log($m) { if ($Sync) { $Sync.Queue.Enqueue(("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m)) } }
    function Norm($n) { ("$n".ToLower() -replace '[^a-z0-9]', '') }

    $games = New-Object System.Collections.ArrayList
    $seen  = @{}

    # exe names that are never "the game"
    $ExcludeExe = '^(unins.*|.*setup.*|vc_?redist.*|vcredist.*|dxwebsetup|dotnet.*|.*crash.*|.*report.*|.*prereq.*|.*install.*|.*updater?|.*helper|.*cefsubprocess.*|.*bootstrap.*|.*anticheat.*|beservice.*|.*benchmark.*|.*launcher.*|elevate|.*browser|.*editor.*|.*redist.*|.*webview.*|.*service)$'

    function Get-Exes($dir) {
        $all = @(Get-ChildItem -LiteralPath $dir -Recurse -Depth 6 -File -Filter *.exe -ErrorAction SilentlyContinue)
        $good = @($all | Where-Object { $_.BaseName -notmatch $ExcludeExe })
        if ($good.Count -eq 0) { $good = $all }      # only launchers/odd names here - better than nothing
        $good | Sort-Object Length -Descending | Select-Object -First 8
    }

    function Add-Game($id, $name, $store, $install, $launch, $exeFiles, $art) {
        if (-not $name -or -not $install -or -not (Test-Path -LiteralPath $install)) { return }
        $key = $install.ToLower().TrimEnd('\')
        if ($seen.ContainsKey($key)) { return }
        if (-not $exeFiles) { $exeFiles = Get-Exes $install }
        $exeFiles = @($exeFiles)
        if ($exeFiles.Count -eq 0) { return }
        $seen[$key] = $true
        [void]$games.Add([ordered]@{
            id = $id; name = $name; store = $store; install = $install; launch = $launch
            exes = @($exeFiles | ForEach-Object { $_.BaseName.ToLower() } | Select-Object -Unique)
            icon = $exeFiles[0].FullName; art = $art; discordId = $null; matched = $false
        })
    }

    # ---- Steam
    try {
        $steam = ("$((Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath)") -replace '/', '\'
        if ($steam -and (Test-Path $steam)) {
            $libs = @($steam)
            $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
            if (Test-Path $vdf) {
                foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') }
            }
            foreach ($lib in ($libs | Select-Object -Unique)) {
                foreach ($acf in Get-ChildItem (Join-Path $lib 'steamapps') -Filter 'appmanifest_*.acf') {
                    $t = Get-Content $acf.FullName -Raw
                    $appid = [regex]::Match($t, '"appid"\s+"(\d+)"').Groups[1].Value
                    $name  = [regex]::Match($t, '"name"\s+"([^"]+)"').Groups[1].Value
                    $dir   = [regex]::Match($t, '"installdir"\s+"([^"]+)"').Groups[1].Value
                    if (-not $appid -or -not $name -or $name -match 'Steamworks|Proton|Steam Linux|Redistributable|Runtime|Wallpaper Engine|Dedicated Server|SDK') { continue }
                    $art = $null
                    $cache = Join-Path $steam "appcache\librarycache\$appid"
                    foreach ($f in 'header.jpg', 'library_600x900.jpg') { if (-not $art -and (Test-Path (Join-Path $cache $f))) { $art = Join-Path $cache $f } }
                    Add-Game "steam:$appid" $name 'Steam' (Join-Path $lib "steamapps\common\$dir") "steam://rungameid/$appid" $null $art
                }
            }
        }
    } catch { Log "Steam scan problem: $($_.Exception.Message)" }

    # ---- Epic Games
    try {
        foreach ($f in Get-ChildItem 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests' -Filter *.item) {
            $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if (-not $j.DisplayName -or -not $j.InstallLocation -or "$($j.LaunchExecutable)" -match 'Editor' -or $j.DisplayName -match 'Editor') { continue }
            Add-Game "epic:$($j.AppName)" $j.DisplayName 'Epic' $j.InstallLocation "com.epicgames.launcher://apps/$($j.AppName)?action=launch&silent=true" $null $null
        }
    } catch { Log "Epic scan problem: $($_.Exception.Message)" }

    # ---- GOG
    try {
        foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games') {
            $p = Get-ItemProperty $k.PSPath
            if ($p.gameName -and $p.path) {
                $exe = if ($p.exe) { $p.exe } else { $null }
                Add-Game "gog:$($k.PSChildName)" $p.gameName 'GOG' $p.path $exe $null $null
            }
        }
    } catch {}

    # ---- launcher folders (Riot, HoYoPlay, Xbox, EA, Ubisoft, ...) + your own folders
    $groupNames = 'epic', 'hoyoplay', 'rockstar', 'steam', 'riot games', 'origin', 'ea', 'ubisoft', 'xboxgames', 'gog galaxy', 'games', 'epic games', 'battle.net'
    $skipNames  = 'steamlibrary', 'steamapps', 'launcher', 'gamesave', 'directxredist', 'gameinputredist', 'riot client', 'common', 'downloading', 'temp'
    $roots = @('C:\Riot Games', 'C:\XboxGames', 'C:\Program Files\EA Games', 'C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\games', 'C:\Program Files\Epic Games')
    foreach ($d in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
        $roots += (Join-Path $d.Name 'Games')
    }
    $roots += @($S.extra_folders)
    $roots = $roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    function Scan-Folder($dir, $depth) {
        foreach ($c in Get-ChildItem -LiteralPath $dir -Directory) {
            $n = $c.Name.ToLower()
            if ($skipNames -contains $n) { continue }
            if (($groupNames -contains $n) -and $depth -lt 2) { Scan-Folder $c.FullName ($depth + 1); continue }
            $exes = Get-Exes $c.FullName
            if (-not $exes) { continue }
            $name = $c.Name -replace '\s+[Gg]ames?$', ''
            try { $pn = $exes[0].VersionInfo.ProductName; if ($pn -and $pn.Length -gt 2 -and $pn -notmatch 'Unreal|Unity') { $name = $pn } } catch {}
            Add-Game "folder:$($c.FullName.ToLower())" $name 'Folder' $c.FullName $exes[0].FullName $exes $null
        }
    }
    foreach ($r in $roots) { Scan-Folder $r 0 }

    # ---- games added by hand
    foreach ($cg in @($S.custom_games)) {
        if ($cg.exe -and (Test-Path -LiteralPath $cg.exe)) {
            $fi = Get-Item -LiteralPath $cg.exe
            Add-Game "custom:$($fi.FullName.ToLower())" $cg.name 'Added' $fi.DirectoryName $fi.FullName @($fi) $null
        }
    }

    # ---- an exe shared by several games (e.g. a bundled browser helper) can't identify any one of them
    $exeCount = @{}
    foreach ($g in $games) { foreach ($e in $g.exes) { $exeCount[$e] = 1 + [int]$exeCount[$e] } }
    foreach ($g in $games) {
        $unique = @($g.exes | Where-Object { $exeCount[$_] -eq 1 })
        if ($unique.Count -gt 0) { $g.exes = $unique }
    }

    # ---- match every game to its official Discord application (public "detectable games" list)
    try {
        $cache = Join-Path $DataDir 'detectable.json'
        if (-not (Test-Path $cache) -or ((Get-Date) - (Get-Item $cache).LastWriteTime).TotalDays -gt 7) {
            Log "Downloading Discord's list of known games..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            $wc.Headers['User-Agent'] = 'RichPresence (personal use)'
            $wc.Encoding = [Text.Encoding]::UTF8
            $wc.DownloadString('https://discord.com/api/v9/applications/detectable') | Set-Content $cache -Encoding UTF8
        }
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $apps = $ser.DeserializeObject((Get-Content $cache -Raw -Encoding UTF8))
        $idx = @{}; $byName = @{}
        foreach ($a in $apps) {
            $an = Norm $a['name']
            if ($an -and -not $byName.ContainsKey($an)) { $byName[$an] = $a }
            foreach ($e in $a['executables']) {
                if ($e['os'] -ne 'win32' -or $e['is_launcher']) { continue }
                $b = ("$($e['name'])" -split '[\\/]')[-1].ToLower() -replace '^>', '' -replace '\.exe$', ''
                if (-not $b) { continue }
                if (-not $idx.ContainsKey($b)) { $idx[$b] = New-Object System.Collections.ArrayList }
                [void]$idx[$b].Add($a)
            }
        }
        $generic = 'game', 'launcher', 'client', 'main', 'start', 'play', 'app', 'shipping', 'win64', 'editor', 'server'
        foreach ($g in $games) {
            $gn = Norm $g.name
            $score = @{}; $appById = @{}
            foreach ($e in $g.exes) {
                if (-not $idx.ContainsKey($e)) { continue }
                foreach ($a in $idx[$e]) {
                    $id = "$($a['id'])"; $an = Norm $a['name']; $appById[$id] = $a
                    $pts = 1
                    if ($an -eq $gn) { $pts += 10 }
                    elseif ($gn.Length -ge 4 -and $an.Length -ge 4 -and ($an.Contains($gn) -or $gn.Contains($an))) { $pts += 5 }
                    elseif ($e.Length -ge 8 -and ($generic -notcontains $e)) { $pts += 3 }
                    $score[$id] += $pts
                }
            }
            $bestId = $null; $bestPts = 0
            foreach ($k in $score.Keys) { if ($score[$k] -gt $bestPts) { $bestPts = $score[$k]; $bestId = $k } }
            if ($bestId -and $bestPts -ge 4) {
                $g.discordId = $bestId; $g.matched = $true; $hit = $appById[$bestId]
                # trust Discord's own executable list for this game over our guesses
                $official = @()
                foreach ($e in $g.exes) {
                    if (-not $idx.ContainsKey($e)) { continue }
                    foreach ($a in $idx[$e]) { if ("$($a['id'])" -eq $bestId) { $official += $e; break } }
                }
                if ($official.Count -gt 0) { $g.exes = $official }
            }
            elseif ($byName.ContainsKey($gn)) { $hit = $byName[$gn]; $g.discordId = "$($hit['id'])"; $g.matched = $true }
            else { $hit = $null }
            # tidy folder-derived names using Discord's official name
            if ($hit -and $g.store -in 'Folder', 'Added') { $g.name = "$($hit['name'])" }
        }
    } catch { Log "Couldn't match games to Discord ($($_.Exception.Message)). They will still be listed." }

    $sorted = @($games | Sort-Object { $_.name })
    ($sorted | ConvertTo-Json -Depth 4) | Set-Content -Path (Join-Path $DataDir 'library.json') -Encoding UTF8
    Log ("Found {0} games ({1} matched to Discord)." -f $sorted.Count, @($sorted | Where-Object { $_.matched }).Count)
    if ($Sync) { $Sync.ScanDone = $true }
    return $sorted
}

# ===========================================================================
# ENGINE - runs on a background runspace. Talks to Discord and watches for games.
# It never touches the UI; it only writes to $Sync.
# ===========================================================================
$Engine = {
    param($S, $Sync)
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    function Log($m) { $Sync.Queue.Enqueue(("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m)) }
    function Nap($sec) {
        $end = [datetime]::UtcNow.AddSeconds($sec)
        while (-not $Sync.Stop -and [datetime]::UtcNow -lt $end) { Start-Sleep -Milliseconds 200 }
    }

    $GameId     = "$($S.game_client_id)".Trim()
    $MusicId    = "$($S.music_client_id)".Trim()
    $AppId      = "$($S.app_client_id)".Trim()
    $GenshinUid = "$($S.genshin_uid)".Trim()
    $ShowMusic  = [bool]$S.show_music
    $ShowSpotify = [bool]$S.show_spotify
    $ShowLyrics = [bool]$S.show_lyrics
    $ShowArt    = [bool]$S.show_album_art
    $ShowApps   = [bool]$S.show_current_app
    $ShowWatching   = [bool]$S.show_watching
    $ShowWatchTitle = [bool]$S.show_watch_title
    $ShowPoster     = [bool]$S.show_watch_poster
    $ShowCasual     = [bool]$S.show_watch_casual
    $OfficialToDiscord = [bool]$S.official_to_discord
    $OfficialDelayMin  = [double]$(if ($null -ne $S.official_delay_minutes) { $S.official_delay_minutes } else { 2 })
    foreach ($pair in @(@('game', $GameId), @('music', $MusicId), @('app', $AppId))) {
        if ($pair[1] -notmatch '^\d{17,20}$') { Log "The $($pair[0]) Discord app ID isn't valid (17-20 digits). Fix it under Music & Apps > Advanced."; return }
    }

    # ---------------------------------------------------------------- Apple Music (Windows media API)
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
    function Await($op, $resultType) {
        $t = $asTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($op))
        if (-not $t.Wait(5000)) { throw "Windows media controls didn't answer in time." }
        $t.Result
    }
    [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null
    $SmtcType  = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
    $PropsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]

    # the music player to show: Apple Music and/or Spotify, whichever is playing.
    # Both playing: the one Windows calls current, else Apple Music. Neither playing: the first one found.
    function Get-MusicSession {
        $mgr = Await ($SmtcType::RequestAsync()) $SmtcType
        $cands = @()
        foreach ($s in @($mgr.GetSessions())) {
            $aum = "$($s.SourceAppUserModelId)"
            if ($ShowMusic -and $aum -match 'AppleMusic|AppleInc') { $cands += @{ Session = $s; Player = 'Apple Music' } }
            elseif ($ShowSpotify -and $aum -match '^Spotify\.exe$|SpotifyAB\.SpotifyMusic') { $cands += @{ Session = $s; Player = 'Spotify' } }
        }
        if (-not $cands.Count) { return $null }
        $playing = @($cands | Where-Object { "$($_.Session.GetPlaybackInfo().PlaybackStatus)" -eq 'Playing' })
        if ($playing.Count -eq 1) { return $playing[0] }
        if ($playing.Count -gt 1) {
            $cur = $mgr.GetCurrentSession()
            if ($cur) { foreach ($c in $playing) { if ("$($c.Session.SourceAppUserModelId)" -eq "$($cur.SourceAppUserModelId)") { return $c } } }
            foreach ($c in $playing) { if ($c.Player -eq 'Apple Music') { return $c } }
            return $playing[0]
        }
        return $cands[0]
    }

    $ArtCache = @{}; $LyricsCache = @{}
    function Get-AlbumArtUrl($artist, $title, $album) {
        if (-not $ShowArt) { return $null }
        $key = "$artist|$album|$title"
        if ($ArtCache.ContainsKey($key)) { return $ArtCache[$key] }
        $url = $null
        try {
            $term = [uri]::EscapeDataString("$artist $album $title")
            $resp = Invoke-RestMethod -Uri "https://itunes.apple.com/search?term=$term&entity=song&limit=1" -TimeoutSec 8
            if ($resp.resultCount -ge 1 -and $resp.results[0].artworkUrl100) { $url = $resp.results[0].artworkUrl100 -replace '100x100bb', '512x512bb' }
        } catch {}
        $ArtCache[$key] = $url
        return $url
    }
    function Get-SyncedLyrics($artist, $title, $album, $durationSec) {
        if (-not $ShowLyrics -or -not "$artist".Trim()) { return $null }     # no artist (a podcast, an ad): nothing to look up
        $key = "$artist|$title|$album"
        if ($LyricsCache.ContainsKey($key)) { return $LyricsCache[$key] }
        $parsed = $null
        try {
            $q = "artist_name=$([uri]::EscapeDataString($artist))&track_name=$([uri]::EscapeDataString($title))"
            if ($album)       { $q += "&album_name=$([uri]::EscapeDataString($album))" }
            if ($durationSec) { $q += "&duration=$([int]$durationSec)" }
            $resp = Invoke-RestMethod -Uri "https://lrclib.net/api/get?$q" -Headers @{ 'User-Agent' = 'RichPresence (personal use)' } -TimeoutSec 8
            if ($resp.syncedLyrics) {
                $lines = @()
                foreach ($line in ($resp.syncedLyrics -split "`n")) {
                    $m = [regex]::Match($line, '^\[(\d+):(\d+(?:\.\d+)?)\](.*)$')
                    if ($m.Success) { $lines += [pscustomobject]@{ t = [int]$m.Groups[1].Value * 60 + [double]$m.Groups[2].Value; text = $m.Groups[3].Value.Trim() } }
                }
                if ($lines.Count) { $parsed = $lines | Sort-Object t }
            }
        } catch {}
        $LyricsCache[$key] = $parsed
        return $parsed
    }
    function Get-CurrentLyricLine($lyrics, $posSec) {
        if (-not $lyrics) { return $null }
        $line = $null
        foreach ($l in $lyrics) { if ($l.t -le ($posSec + 0.3)) { $line = $l.text } else { break } }
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
        if ($line.Length -gt 128) { $line = $line.Substring(0, 125) + '...' }
        return $line
    }

    # ---------------------------------------------------------------- Foreground app (Win32)
    if (-not ('RPFG' -as [type])) {
        Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class RPFG {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    public static string Title(IntPtr h) {
        int len = GetWindowTextLength(h);
        if (len <= 0) return "";
        var sb = new StringBuilder(len + 1);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }
}
"@
    }
    $Ignore = @('discord', 'lockapp', 'searchhost', 'shellexperiencehost', 'startmenuexperiencehost', 'textinputhost',
                'systemsettings', 'applicationframehost', 'dwm', 'sihost', 'richpresence')
    $Friendly = @{
        'code' = 'Visual Studio Code'; 'devenv' = 'Visual Studio'; 'powershell' = 'PowerShell'; 'pwsh' = 'PowerShell'
        'windowsterminal' = 'Windows Terminal'; 'cmd' = 'Command Prompt'; 'chrome' = 'Google Chrome'; 'msedge' = 'Microsoft Edge'
        'firefox' = 'Firefox'; 'explorer' = 'File Explorer'; 'notepad' = 'Notepad'; 'spotify' = 'Spotify'
        'applemusic' = 'Apple Music'; 'steam' = 'Steam'; 'obs64' = 'OBS Studio'; 'photoshop' = 'Photoshop'
        'blender' = 'Blender'; 'slack' = 'Slack'; 'obsidian' = 'Obsidian'; 'winword' = 'Word'; 'excel' = 'Excel'
    }
    $IconDomain = @{
        'devenv' = 'visualstudio.microsoft.com'; 'code' = 'code.visualstudio.com'; 'chrome' = 'google.com'
        'msedge' = 'microsoft.com'; 'firefox' = 'mozilla.org'; 'spotify' = 'spotify.com'; 'applemusic' = 'music.apple.com'
        'steam' = 'store.steampowered.com'; 'slack' = 'slack.com'; 'obsidian' = 'obsidian.md'; 'obs64' = 'obsproject.com'
        'photoshop' = 'adobe.com'; 'blender' = 'blender.org'; 'winword' = 'microsoft.com'; 'excel' = 'microsoft.com'
    }
    $script:GameExeSet = @{}
    function Get-Foreground {
        $h = [RPFG]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return $null }
        $procId = 0; [RPFG]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
        if ($procId -le 0) { return $null }
        try { $p = Get-Process -Id $procId -ErrorAction Stop } catch { return $null }
        $name = $p.ProcessName.ToLower()
        if ($Ignore -contains $name -or $script:GameExeSet.ContainsKey($name)) { return $null }
        $label = $Friendly[$name]
        if (-not $label) { try { $label = $p.MainModule.FileVersionInfo.FileDescription } catch {} }
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $p.ProcessName }
        $icon = if ($IconDomain.ContainsKey($name)) { "https://www.google.com/s2/favicons?sz=128&domain=$($IconDomain[$name])" } else { $null }
        [pscustomobject]@{ Proc = $name; Label = "$label"; Title = "$([RPFG]::Title($h))"; Icon = $icon }
    }

    # ---------------------------------------------------------------- Genshin extras (Enka.Network public profile)
    $script:GenshinInfo = $null; $script:GenshinFetchedAt = [datetime]::MinValue
    function Get-GenshinInfo {
        if ($GenshinUid -notmatch '^\d{9,10}$') { return $null }
        if ($script:GenshinInfo -and ([datetime]::UtcNow - $script:GenshinFetchedAt).TotalMinutes -lt 10) { return $script:GenshinInfo }
        $script:GenshinFetchedAt = [datetime]::UtcNow
        try {
            $resp = Invoke-RestMethod -Uri "https://enka.network/api/uid/${GenshinUid}?info" -Headers @{ 'User-Agent' = 'RichPresence (personal use)' } -TimeoutSec 10
            $pi = $resp.playerInfo
            if ($pi) {
                $script:GenshinInfo = [pscustomobject]@{ Nickname = "$($pi.nickname)"; Level = [int]$pi.level; WorldLevel = [int]$pi.worldLevel }
                Log ("Genshin profile: {0}  AR {1}  WL {2}" -f $script:GenshinInfo.Nickname, $script:GenshinInfo.Level, $script:GenshinInfo.WorldLevel)
            }
        } catch { Log "Couldn't load your Genshin profile (is Character Showcase public in-game?)" }
        return $script:GenshinInfo
    }

    # ---------------------------------------------------------------- streaming (Netflix, Hulu, ... in a browser or their app)
    # The page tells the browser what's playing (Media Session), and Windows passes that on to every app, the same
    # way it does for Apple Music. The site is recognised from that info or from the browser's window titles;
    # the poster is looked up on TVMaze (shows) or iTunes (movies). Nothing is read from inside the page itself.
    if (-not ('RPWin' -as [type])) {
        Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class RPWin {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    // "pid<TAB>title" for every visible top-level window that has a title
    public static string[] Visible() {
        var list = new List<string>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            int len = GetWindowTextLength(h);
            if (len <= 0) return true;
            var sb = new StringBuilder(len + 1);
            GetWindowText(h, sb, sb.Capacity);
            int pid; GetWindowThreadProcessId(h, out pid);
            list.Add(pid + "\t" + sb.ToString());
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
}
"@
    }
    # Mark = how the site names itself in a tab title; App = its Windows app's id; Casual = YouTube/Twitch;
    # Id = a Discord app made for that service (its own card, title and logo). Without one, the app card is used.
    $Services = @(
        @{ Name = 'Netflix';     Domain = 'netflix.com';       Mark = 'Netflix';                 App = 'Netflix'; Id = '1543308009571225711' }
        @{ Name = 'Hulu';        Domain = 'hulu.com';          Mark = 'Hulu';                    App = 'Hulu';        Id = '1555409832289378314' }
        @{ Name = 'Disney+';     Domain = 'disneyplus.com';    Mark = 'Disney\+';                App = 'Disney';      Id = '1555410530762494003' }
        @{ Name = 'Prime Video'; Domain = 'primevideo.com';    Mark = 'Prime Video|Amazon\.com'; App = 'PrimeVideo|AmazonVideo'; Id = '1555411243207098409' }
        @{ Name = 'Max';         Domain = 'max.com';           Mark = 'HBO Max|Max';             App = 'HBOMax|WarnerBros'; Id = '1555411619285176410' }
        @{ Name = 'Crunchyroll'; Domain = 'crunchyroll.com';   Mark = 'Crunchyroll';             App = 'Crunchyroll'; Id = '1555411897317064837' }
        @{ Name = 'Paramount+';  Domain = 'paramountplus.com'; Mark = 'Paramount\+';             App = 'Paramount';   Id = '1555412495521546320' }
        @{ Name = 'Peacock';     Domain = 'peacocktv.com';     Mark = 'Peacock';                 App = 'Peacock';     Id = '1555413504956039188' }
        @{ Name = 'Apple TV+';   Domain = 'tv.apple.com';      Mark = 'Apple TV\+?';             App = 'AppleTV';     Id = '1555413730475507812' }
        @{ Name = 'Plex';        Domain = 'plex.tv';           Mark = 'Plex';                    App = 'Plex' }
        @{ Name = 'YouTube';     Domain = 'youtube.com';       Mark = 'YouTube';                 App = 'YouTube'; Casual = $true }
        @{ Name = 'Twitch';      Domain = 'twitch.tv';         Mark = 'Twitch';                  App = 'Twitch';  Casual = $true }
    )
    $BrowserAum   = 'chrome|msedge|firefox|308046B0AF4A39CB|brave|opera|vivaldi'
    $BrowserProcs = 'chrome', 'msedge', 'firefox', 'brave', 'opera', 'vivaldi'
    $Dashes = "$([char]0x2022)$([char]0x2013)$([char]0x2014)"     # bullet, en dash, em dash (kept out of the file so it stays ASCII)
    $Sep = "[|${Dashes}:-]"
    $BrowserSuffix = "(?i)\s[${Dashes}-]\s(Google Chrome|Mozilla Firefox|Brave|Opera|Vivaldi|Microsoft\W{0,3}Edge)$"

    # "Watch The Bear | Hulu - Google Chrome" -> Hulu, "The Bear". The site's name has to be its own piece of
    # the title (start or end, next to a separator), so "Mad Max - Wikipedia" isn't Max.
    function Find-Service($text) {
        $text = "$text".Trim()
        if (-not $text) { return $null }
        foreach ($sv in $Services) {
            if ($sv.Casual -and -not $ShowCasual) { continue }
            $m = [regex]::Match($text, "(?i)(?<=^|\s$Sep\s*)($($sv.Mark))(?=(\s+and \d+ more pages?)?(\s*$Sep\s|\s*$Sep?$))")
            if (-not $m.Success) { continue }
            $before = $text.Substring(0, $m.Index); $after = $text.Substring($m.Index + $m.Length)
            $clean = if ($before.Trim(" |:-$([char]0x2022)$([char]0x2013)$([char]0x2014)")) { $before } else { $after -replace $BrowserSuffix, '' }
            $clean = $clean -replace '\s+and \d+ more pages?.*$', ''
            $clean = $clean.Trim(" |:-$([char]0x2022)$([char]0x2013)$([char]0x2014)") -replace '(?i)^(watch|stream)\s+', '' -replace '(?i)\s+online$', ''
            return [pscustomobject]@{ Svc = $sv; Clean = $clean.Trim() }
        }
        $null
    }
    function Test-Host($v) { "$v" -match '^[\w-]+(\.[\w-]+)+$' }
    function Get-BrowserTitles {
        $pids = @{}
        foreach ($p in @(Get-Process -Name $BrowserProcs -ErrorAction SilentlyContinue)) { $pids[$p.Id] = $true }
        if (-not $pids.Count) { return @() }
        @([RPWin]::Visible() | ForEach-Object {
            $i = $_.IndexOf("`t")
            if ($i -gt 0 -and $pids.ContainsKey([int]$_.Substring(0, $i))) { $_.Substring($i + 1) }
        })
    }
    # what the browser extension last reported for a service (only if it's recent). Every tab reports
    # separately: a playing tab wins over a paused one, then the newest report.
    function Get-ExtReport($name) {
        $best = $null
        $tabs = $Sync.Ext[$name]
        if ($tabs) {
            foreach ($e in @($tabs.Values)) {
                if (([datetime]::UtcNow - $e.At).TotalSeconds -ge 15) { continue }
                if (-not $best -or ($e.Playing -and -not $best.Playing) -or ($e.Playing -eq $best.Playing -and $e.At -gt $best.At)) { $best = $e }
            }
        }
        $best
    }
    function Find-Watching {
        # the browser extension reads the player itself, so it knows best: show, episode, exact position
        # (a streaming service before YouTube/Twitch, like below)
        foreach ($sv in @($Services | Sort-Object { [bool]$_.Casual })) {
            if ($sv.Casual -and -not $ShowCasual) { continue }
            $e = Get-ExtReport $sv.Name
            if ($e -and $e.Playing) {
                $pos = $e.Pos; if ($e.Dur -gt 0) { $pos = [math]::Min($e.Dur, $pos + ([datetime]::UtcNow - $e.At).TotalSeconds) }
                return [pscustomobject]@{ Svc = $sv; Show = $e.Title; Sub = $e.Episode; Dur = $e.Dur; Pos = $pos; Image = $e.Image }
            }
        }
        $mgr = Await ($SmtcType::RequestAsync()) $SmtcType
        $titles = $null; $found = @()
        foreach ($s in @($mgr.GetSessions())) {
            $aum = "$($s.SourceAppUserModelId)"
            if ($aum -match 'AppleMusic|AppleInc|Spotify') { continue }
            if ("$($s.GetPlaybackInfo().PlaybackStatus)" -ne 'Playing') { continue }
            $sv = $null; $winClean = ''
            if ($aum -notmatch $BrowserAum) {
                $sv = $Services | Where-Object { $aum -match $_.App -and ($ShowCasual -or -not $_.Casual) } | Select-Object -First 1
                if (-not $sv) { continue }
            }
            $props = Await ($s.TryGetMediaPropertiesAsync()) $PropsType
            $mt = "$($props.Title)".Trim(); $ma = "$($props.Artist)".Trim()
            $inTitle = Find-Service $mt
            if (-not $sv) {
                # without its own info the browser reports the tab title and the site ("www.netflix.com")
                foreach ($x in $Services) {
                    if (($ShowCasual -or -not $x.Casual) -and (Test-Host $ma) -and $ma -match "(^|\.)$([regex]::Escape($x.Domain))$") { $sv = $x; break }
                }
            }
            if (-not $sv -and $inTitle) { $sv = $inTitle.Svc }
            if (-not $sv) {
                # otherwise look at the browser's windows: one showing the same title is the best match
                if ($null -eq $titles) { $titles = @(Get-BrowserTitles) }
                $hit = $null
                if ($mt.Length -ge 3) { foreach ($t in $titles) { if ($t.IndexOf($mt, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = Find-Service $t; if ($hit) { break } } } }
                if (-not $hit) { foreach ($t in $titles) { $hit = Find-Service $t; if ($hit) { break } } }
                if (-not $hit) { continue }
                $sv = $hit.Svc; $winClean = $hit.Clean
            }
            $show = ''
            if ($inTitle -and $inTitle.Svc.Name -eq $sv.Name) { $show = $inTitle.Clean }
            elseif ($mt -and -not (Test-Host $mt) -and $mt -ne $sv.Name) { $show = $mt }
            if (-not $show) { $show = $winClean }
            # player pages often only say "Hulu | Watch": that's not a show name
            if ($show -match '^(?i)(watch|watching|home|browse|player|play|video|videos|movie|movies|tv|series|shows?|search|details|stream)$') { $show = '' }
            # the extension says this service is paused: believe it over another tab's media session
            $e = Get-ExtReport $sv.Name
            if ($e -and -not $e.Playing) { continue }
            $sub = if ($ma -and -not (Test-Host $ma) -and $ma -ne $show -and $ma -ne $sv.Name) { $ma } else { '' }
            $tl = $s.GetTimelineProperties()
            $dur = ($tl.EndTime.TotalSeconds - $tl.StartTime.TotalSeconds); $pos = ($tl.Position.TotalSeconds - $tl.StartTime.TotalSeconds)
            if ($tl.LastUpdatedTime.Year -gt 1) { $pos += ([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalSeconds }
            $found += [pscustomobject]@{ Svc = $sv; Show = $show; Sub = $sub; Dur = $dur; Pos = $pos }
        }
        # a streaming service beats YouTube/Twitch when both are playing
        @($found | Sort-Object { [bool]$_.Svc.Casual }) | Select-Object -First 1
    }

    # the poster: TVMaze knows TV shows, Cinemeta (Stremio's public catalog) knows movies. Only accept a
    # result whose name is the start of what's playing ("The Bear Season 2" -> "The Bear"), never a longer
    # name that merely starts with it ("Watch" -> "Watch the Skies").
    $PosterCache = @{}
    function Test-SameTitle($playing, $found) {
        $np = Norm $playing; $nf = Norm $found
        $np.Length -ge 3 -and $nf.Length -ge 3 -and $np.StartsWith($nf)
    }
    function Get-Poster($show, $sub) {
        if (-not $ShowPoster) { return $null }
        $q = "$show".Trim()
        if ($q.Length -lt 2) { return $null }
        if ($PosterCache.ContainsKey($q)) { return $PosterCache[$q] }
        $url = $null
        $tries = @($q, ($q -split "\s$Sep\s|:\s")[0].Trim(), "$sub".Trim()) | Where-Object { $_.Length -ge 2 } | Select-Object -Unique
        foreach ($t in $tries) {
            try {
                $r = Invoke-RestMethod -Uri "https://api.tvmaze.com/singlesearch/shows?q=$([uri]::EscapeDataString($t))" -TimeoutSec 8
                if ($r.image -and (Test-SameTitle $t $r.name)) { $url = "$(if ($r.image.original) { $r.image.original } else { $r.image.medium })" }
            } catch {}
            if ($url) { break }
        }
        # only then movies, and never for something that's clearly an episode
        if (-not $url -and "$show $sub" -notmatch '(?i)\b(season|episode|ep\.?\s*\d|s\d+\s*:?\s*e\d+)') {
            foreach ($t in $tries) {
                try {
                    $r = Invoke-RestMethod -Uri "https://v3-cinemeta.strem.io/catalog/movie/top/search=$([uri]::EscapeDataString($t)).json" -Headers @{ 'User-Agent' = 'RichPresence (personal use)' } -TimeoutSec 8
                    foreach ($m in @($r.metas | Select-Object -First 3)) {
                        if ($m.poster -and (Test-SameTitle $t $m.name)) { $url = "$($m.poster)"; break }
                    }
                } catch {}
                if ($url) { break }
            }
        }
        if ($url -and $url.Length -gt 256) { $url = $null }
        $PosterCache[$q] = $url
        $url
    }
    function Norm($n) { ("$n".ToLower() -replace '[^a-z0-9]', '') }
    $script:WatchKey = $null; $script:WatchStart = 0

    # a service's logo: the icon uploaded to its Discord app (public info), else the website's icon
    $LogoCache = @{}
    function Get-ServiceLogo($sv) {
        if ($LogoCache.ContainsKey($sv.Name)) { return $LogoCache[$sv.Name] }
        $logo = "https://www.google.com/s2/favicons?sz=128&domain=$($sv.Domain)"
        if ($sv.Id) {
            try {
                $r = Invoke-RestMethod -Uri "https://discord.com/api/v9/applications/$($sv.Id)/rpc" -Headers @{ 'User-Agent' = 'RichPresence (personal use)' } -TimeoutSec 8
                if ("$($r.icon)" -match '^[0-9a-f]{32}$') { $logo = "https://cdn.discordapp.com/app-icons/$($sv.Id)/$($r.icon).png?size=256" }
            } catch {}
        }
        $LogoCache[$sv.Name] = $logo
        $logo
    }

    # ---------------------------------------------------------------- game activity
    function Get-GameStartMs($g, $proc) {
        $ms = $null
        try { $ms = ([DateTimeOffset]$proc.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds() } catch {}
        if (-not $ms) {
            if (-not $script:FirstSeen.ContainsKey($g.id)) { $script:FirstSeen[$g.id] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
            $ms = $script:FirstSeen[$g.id]
        }
        return $ms
    }
    $script:FirstSeen = @{}
    function New-GameActivity($g, $proc) {
        $a = @{ type = 0; name = $g.name; timestamps = @{ start = (Get-GameStartMs $g $proc) } }
        if ($g.exes -contains 'genshinimpact' -or $g.exes -contains 'yuanshen') {
            $gi = Get-GenshinInfo
            if ($gi) {
                $a.details = "$($gi.Nickname) - AR $($gi.Level)"
                $a.state   = "UID $GenshinUid - WL $($gi.WorldLevel)"
                $a.assets  = @{ large_image = 'https://www.google.com/s2/favicons?sz=128&domain=genshin.hoyoverse.com'; large_text = 'Genshin Impact' }
            }
        }
        return $a
    }

    # ---------------------------------------------------------------- Discord IPC (one connection per Discord app id)
    function New-Conn($clientId, $name) { @{ Pipe = $null; ClientId = $clientId; Name = $name; Id = $null; SentUtc = [datetime]::MinValue; LastErr = $null } }
    function Close-Discord($c) { try { if ($c.Pipe) { $c.Pipe.Dispose() } } catch {}; $c.Pipe = $null }
    function Send-Frame($c, [int]$op, [string]$json) {
        $data = [Text.Encoding]::UTF8.GetBytes($json)
        $header = New-Object byte[] 8
        [BitConverter]::GetBytes([int32]$op).CopyTo($header, 0)
        [BitConverter]::GetBytes([int32]$data.Length).CopyTo($header, 4)
        $c.Pipe.Write($header, 0, 8); $c.Pipe.Write($data, 0, $data.Length); $c.Pipe.Flush()
    }
    # one read from the pipe that never waits longer than 5 s. 0 = Discord closed the pipe, or went quiet
    # (then the pipe is dropped, because a late answer would be mistaken for the next one)
    function Read-Pipe($c, $buf, $off, $count) {
        $t = $c.Pipe.ReadAsync($buf, $off, $count)
        if (-not $t.Wait(5000)) { Close-Discord $c; return 0 }
        $t.Result
    }
    function Read-Frame($c) {
        try {
            $h = New-Object byte[] 8
            if ((Read-Pipe $c $h 0 8) -lt 8) { return $null }
            $len = [BitConverter]::ToInt32($h, 4)
            if ($len -le 0) { return '' }
            $b = New-Object byte[] $len; $g = 0
            while ($g -lt $len) { $n = Read-Pipe $c $b $g ($len - $g); if ($n -le 0) { return $null }; $g += $n }
            [Text.Encoding]::UTF8.GetString($b)
        } catch { $null }
    }
    # Discord answers the handshake with READY. Anything else means it refused this app ID: say so once
    # and leave that ID alone for a minute, instead of reconnecting every few seconds.
    $BadIds = @{}     # discord app id -> @{ Until; Logged }
    function Connect-Discord($c) {
        if ($c.Pipe -and $c.Pipe.IsConnected) { return $true }
        $bad = $BadIds[$c.ClientId]
        if ($bad -and [datetime]::UtcNow -lt $bad.Until) { return $false }
        $refused = $null
        foreach ($i in 0..9) {
            $p = $null
            try {
                $p = New-Object System.IO.Pipes.NamedPipeClientStream('.', "discord-ipc-$i", 'InOut', 'Asynchronous')
                $p.Connect(1000)
                $c.Pipe = $p
                Send-Frame $c 0 (@{ v = 1; client_id = $c.ClientId } | ConvertTo-Json -Compress)
                $r = Read-Frame $c
                if ($r -and $r -match '"evt"\s*:\s*"READY"') { $BadIds.Remove($c.ClientId); return $true }
                $p.Dispose(); $c.Pipe = $null
                if ($r) { $refused = $r; break }
            } catch { if ($p) { $p.Dispose() }; $c.Pipe = $null }
        }
        if ($refused) {
            if (-not $bad) {
                $why = ''; try { $why = "$(($refused | ConvertFrom-Json).message)" } catch {}
                Log ("Discord didn't accept the $($c.Name) card's app ID $($c.ClientId)" + $(if ($why) { " ($why)" } else { '' }) + ". Trying again once a minute.")
                $bad = @{ Until = [datetime]::UtcNow }
                $BadIds[$c.ClientId] = $bad
            }
            $bad.Until = [datetime]::UtcNow.AddSeconds(60)
        }
        return $false
    }
    function Set-Activity($c, $activity) {
        Send-Frame $c 1 (@{ cmd = 'SET_ACTIVITY'; nonce = [guid]::NewGuid().ToString(); args = @{ pid = $PID; activity = $activity } } | ConvertTo-Json -Depth 8 -Compress)
        # Discord answers every command; a rejected card (bad picture link, bad button...) comes back as an ERROR
        $r = Read-Frame $c
        $err = $null
        if ($r -and $r -match '"evt"\s*:\s*"ERROR"') { $err = $r; try { $err = "$(($r | ConvertFrom-Json).data.message)" } catch {} }
        if ($err -and $err -ne $c.LastErr) { Log "Discord didn't accept the $($c.Name) card: $err" }
        $c.LastErr = $err
    }
    function Clear-Activity($c) {
        Send-Frame $c 1 (@{ cmd = 'SET_ACTIVITY'; nonce = [guid]::NewGuid().ToString(); args = @{ pid = $PID } } | ConvertTo-Json -Depth 8 -Compress)
        Read-Frame $c | Out-Null
    }

    $ConnMusic = New-Conn $MusicId 'music'
    $ConnApp   = New-Conn $AppId   'app'
    $ConnWatch = $null                    # a streaming service's own Discord app, while it plays
    $GameConns = @{}     # discord app id -> connection (one card per game)

    function Update-GameCards($running) {
        $wanted = @{}
        foreach ($r in $running) {
            # Discord detects its official games itself: give it a head start so the session counts for
            # Recent Activity and streaks, then show our own card (with extras like the Genshin stats)
            if ($OfficialToDiscord -and $r.G.discordId) {
                $startMs = Get-GameStartMs $r.G $r.P
                if (([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $startMs) -lt ($OfficialDelayMin * 60000)) { continue }
            }
            # official Discord app if we know one, otherwise the shared generic game app
            $cid = if ($r.G.discordId) { "$($r.G.discordId)" } else { $GameId }
            if (-not $wanted.ContainsKey($cid)) { $wanted[$cid] = $r }
        }
        foreach ($id in @($wanted.Keys)) {
            try {
                if (-not $GameConns.ContainsKey($id)) { $GameConns[$id] = New-Conn $id 'game' }
                $c = $GameConns[$id]
                if (-not (Connect-Discord $c)) { continue }
                $r = $wanted[$id]
                $sig = "$($r.G.id)|$($script:GenshinInfo.Level)|$($script:GenshinInfo.WorldLevel)"
                if (($c.Id -ne $sig) -or (([datetime]::UtcNow - $c.SentUtc).TotalSeconds -ge 20)) {
                    Set-Activity $c (New-GameActivity $r.G $r.P)
                    if ($c.Id -ne $sig) { Log "Playing: $($r.G.name)" }
                    $c.Id = $sig; $c.SentUtc = [datetime]::UtcNow
                }
            } catch { Log "Game card error: $($_.Exception.Message)"; Close-Discord $GameConns[$id]; $GameConns.Remove($id) }
        }
        foreach ($id in @($GameConns.Keys)) {
            if (-not $wanted.ContainsKey($id)) { Close-Discord $GameConns[$id]; $GameConns.Remove($id); Log "Game closed - card removed" }
        }
    }

    # ---------------------------------------------------------------- main loop
    $FALLBACK_IMAGE   = 'https://upload.wikimedia.org/wikipedia/commons/thumb/5/5f/Apple_Music_icon.svg/240px-Apple_Music_icon.svg.png'
    $GENERIC_APP_ICON = 'https://upload.wikimedia.org/wikipedia/commons/thumb/8/87/Windows_logo_-_2021.svg/240px-Windows_logo_-_2021.svg.png'
    $lastLyricLine = $null; $appStartMs = $null; $appPendProc = $null; $appPendSince = [datetime]::MinValue
    $lastValidAppUtc = $null; $sawWatch = $false; $watchGoneSince = $null; $watchStarted = [datetime]::UtcNow; $lastWatch = $null

    # rate-capped SET_ACTIVITY for one card (each connection keeps its own state)
    function Push-Card($c, $activity, $id, $critical) {
        $since = ([datetime]::UtcNow - $c.SentUtc).TotalSeconds
        if (-not $critical -and $since -lt 5) { return $false }
        if ($critical -and $since -lt 2) { Start-Sleep -Milliseconds 800 }
        Set-Activity $c $activity
        $c.SentUtc = [datetime]::UtcNow; $c.Id = $id
        return $true
    }
    function Clear-Card($c) {
        if ($c.Pipe -and $c.Id) { try { Clear-Activity $c } catch {} }
        $c.Id = $null
    }
    function Test-DiscordRunning { [bool]([System.IO.Directory]::GetFiles('\\.\pipe\') -match 'discord-ipc-') }

    # ---------------------------------------------------------------- custom statuses (your own text, pictures and buttons)
    # Discord shows one card per Discord app, so every custom card needs its own app: the user's own App ID
    # if they made one, otherwise one of the built-in ones (only a few). 'merge' folds the ticked ones into one card.
    $CustomPool = @(@($S.custom_client_ids) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d{17,20}$' })
    $CustomConns = @{}
    $script:CustomStart = @{}; $script:CustomShown = 0; $script:CustomSkipped = @(); $script:CustomSkipLog = ''
    $Dot = " $([char]0x00B7) "

    function Limit-Text($t, $max) {
        $t = "$t".Trim()
        if ($t.Length -gt $max) { $t = $t.Substring(0, $max - 3) + '...' }
        $t
    }
    function Get-CustomLabel($st) {
        foreach ($v in $st.name, $st.details, $st.state) { if ("$v".Trim()) { return "$v".Trim() } }
        'Custom status'
    }
    # a picture is an https link, or the name of a picture uploaded to the user's own Discord app
    function Get-CustomImage($v) {
        $v = "$v".Trim()
        if ($v -match '^https://\S+$' -and $v.Length -le 256) { return $v }
        if ($v -match '^[\w.-]{1,128}$') { return $v }
        $null
    }
    function New-CustomActivity($st) {
        $t = 0; try { $t = [int]$st.type } catch {}
        $a = @{ type = $(if ($t -in 2, 3, 5) { $t } else { 0 }) }     # Playing / Listening to / Watching / Competing in
        $v = Limit-Text $st.name 128;    if ($v.Length -ge 2) { $a.name = $v }
        $v = Limit-Text $st.details 128; if ($v.Length -ge 2) { $a.details = $v }
        $v = Limit-Text $st.state 128;   if ($v.Length -ge 2) { $a.state = $v }
        $as = @{}
        $img = Get-CustomImage $st.large_image
        if ($img) { $as.large_image = $img; $v = Limit-Text $st.large_text 128; if ($v.Length -ge 2) { $as.large_text = $v } }
        $img = Get-CustomImage $st.small_image
        if ($img) { $as.small_image = $img; $v = Limit-Text $st.small_text 128; if ($v.Length -ge 2) { $as.small_text = $v } }
        if ($as.Count) { $a.assets = $as }
        $btn = @()
        foreach ($n in 1, 2) {
            $l = Limit-Text $st."button${n}_label" 32; $u = "$($st."button${n}_url")".Trim()
            if ($l -and $u -match '^https?://\S+$' -and $u.Length -le 512) { $btn += @{ label = $l; url = $u } }
        }
        if ($btn.Count) { $a.buttons = $btn }
        $a
    }
    # one card out of several: the first one's title, type and App ID; every line joined; the first picture
    # becomes the big one and the next picture the small round one; the first two buttons found
    function Merge-CustomStatuses($list) {
        $first = $list[0]
        $m = [ordered]@{
            id = 'merged'; type = $first.type; name = $first.name; app_id = $first.app_id
            elapsed = [bool]@($list | Where-Object { $_.elapsed }).Count
            details = (@($list | ForEach-Object { "$($_.details)".Trim() } | Where-Object { $_ }) -join $Dot)
            state   = (@($list | ForEach-Object { "$($_.state)".Trim() } | Where-Object { $_ }) -join $Dot)
            large_image = ''; large_text = ''; small_image = "$($first.small_image)"; small_text = "$($first.small_text)"
        }
        $pics = @(foreach ($st in $list) { if (Get-CustomImage $st.large_image) { , @("$($st.large_image)", "$($st.large_text)") } })
        if ($pics.Count) { $m.large_image = $pics[0][0]; $m.large_text = $pics[0][1] }
        if (-not (Get-CustomImage $m.small_image) -and $pics.Count -gt 1) { $m.small_image = $pics[1][0]; $m.small_text = $pics[1][1] }
        $n = 0
        foreach ($st in $list) {
            foreach ($k in 1, 2) {
                $l = "$($st."button${k}_label")".Trim(); $u = "$($st."button${k}_url")".Trim()
                if ($n -lt 2 -and $l -and $u -match '^https?://') { $n++; $m["button${n}_label"] = $l; $m["button${n}_url"] = $u }
            }
        }
        New-Object psobject -Property $m
    }
    function Get-CustomCards($items, $mode) {
        $on = @(@($items) | Where-Object { $_ -and $_.enabled })
        if ($mode -eq 'merge' -and $on.Count -gt 1) { $on = @(Merge-CustomStatuses $on) }
        # statuses with their own Discord app claim it first; the rest share the built-in ones
        $own  = @($on | Where-Object { "$($_.app_id)".Trim() -match '^\d{17,20}$' })
        $rest = @($on | Where-Object { "$($_.app_id)".Trim() -notmatch '^\d{17,20}$' })
        $cards = @(); $used = @{}; $skipped = @(); $pi = 0
        foreach ($st in ($own + $rest)) {
            $cid = "$($st.app_id)".Trim()
            if ($cid -notmatch '^\d{17,20}$') {
                $cid = $null
                while ($pi -lt $CustomPool.Count -and -not $cid) { if (-not $used.ContainsKey($CustomPool[$pi])) { $cid = $CustomPool[$pi] }; $pi++ }
            }
            if (-not $cid -or $used.ContainsKey($cid)) { $skipped += (Get-CustomLabel $st); continue }
            $used[$cid] = $true
            $cards += [pscustomobject]@{ AppId = $cid; Key = "$($st.id)"; Label = (Get-CustomLabel $st); Elapsed = [bool]$st.elapsed; Activity = (New-CustomActivity $st) }
        }
        $script:CustomSkipped = $skipped
        $cards
    }
    function Update-CustomCards {
        $cu = $Sync.Custom
        $cards = @(if ($cu) { Get-CustomCards $cu.Items "$($cu.Mode)" })
        $sk = $script:CustomSkipped -join ', '
        if ($sk -ne $script:CustomSkipLog) {
            $script:CustomSkipLog = $sk
            if ($sk) { Log "No free card for: $sk. Give it its own Discord App ID, or merge your statuses into one card." }
        }
        $wanted = @{}
        foreach ($cd in $cards) { $wanted[$cd.AppId] = $cd }
        foreach ($id in @($wanted.Keys)) {
            try {
                if (-not $CustomConns.ContainsKey($id)) { $CustomConns[$id] = New-Conn $id 'custom' }
                $c = $CustomConns[$id]
                if (-not (Connect-Discord $c)) { continue }
                $cd = $wanted[$id]
                $sig = "$($cd.Key)|$($cd.Elapsed)|" + ($cd.Activity | ConvertTo-Json -Depth 6 -Compress)
                $changed = ($c.Id -ne $sig)
                if ($changed -or (([datetime]::UtcNow - $c.SentUtc).TotalSeconds -ge 60)) {
                    if (-not $script:CustomStart.ContainsKey($cd.Key)) { $script:CustomStart[$cd.Key] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
                    $act = $cd.Activity
                    if ($cd.Elapsed) { $act.timestamps = @{ start = $script:CustomStart[$cd.Key] } }
                    if ((Push-Card $c $act $sig $changed) -and $changed) { Log "Custom status: $($cd.Label)" }
                }
            } catch { Log "Custom status error: $($_.Exception.Message)"; Close-Discord $CustomConns[$id]; $CustomConns.Remove($id) }
        }
        foreach ($id in @($CustomConns.Keys)) {
            if (-not $wanted.ContainsKey($id)) { Clear-Card $CustomConns[$id]; Close-Discord $CustomConns[$id]; $CustomConns.Remove($id) }
        }
        # a status that was switched off starts its timer from zero next time
        $keys = @($cards | ForEach-Object { $_.Key })
        foreach ($k in @($script:CustomStart.Keys)) { if ($keys -notcontains $k) { $script:CustomStart.Remove($k) } }
        $script:CustomShown = $cards.Count
    }
    function Close-CustomConns { foreach ($k in @($CustomConns.Keys)) { Close-Discord $CustomConns[$k]; $CustomConns.Remove($k) } }

    Log "Presence started."
    while (-not $Sync.Stop) {
        try {
            # ---- which library games are running? Every game counts here, with or without Discord
            # ("never update while a game runs", "quit when the game closes"); only the ones switched on get a card.
            $procs = @{}
            foreach ($p in Get-Process) { $procs[$p.ProcessName.ToLower()] = $p }
            $script:GameExeSet = @{}
            $running = @(); $runIds = @()
            foreach ($g in @($Sync.Games)) {
                foreach ($e in @($g.exes)) { $script:GameExeSet["$e"] = $true }
                foreach ($e in @($g.exes)) {
                    if ($procs.ContainsKey("$e")) {
                        $runIds += $g.id
                        if ($g.enabled) { $running += [pscustomobject]@{ G = $g; P = $procs["$e"] } }
                        break
                    }
                }
            }
            $Sync.RunningIds = $runIds

            # "quit when the game closes" - only for the game we launched
            if ($Sync.WatchId) {
                if ($lastWatch -ne $Sync.WatchId) { $lastWatch = $Sync.WatchId; $sawWatch = $false; $watchGoneSince = $null; $watchStarted = [datetime]::UtcNow }
                if ($Sync.RunningIds -contains $Sync.WatchId) { $sawWatch = $true; $watchGoneSince = $null }
                elseif ($sawWatch) {
                    if (-not $watchGoneSince) { $watchGoneSince = [datetime]::UtcNow }
                    elseif (([datetime]::UtcNow - $watchGoneSince).TotalSeconds -gt 8) { $Sync.GameExited = $true; $Sync.WatchId = $null }
                }
                elseif (([datetime]::UtcNow - $watchStarted).TotalMinutes -gt 10) { $Sync.WatchId = $null }
            }

            if (-not (Test-DiscordRunning)) {
                $Sync.Status = 'Waiting for Discord...'
                Close-Discord $ConnMusic; Close-Discord $ConnApp; Close-CustomConns; if ($ConnWatch) { Close-Discord $ConnWatch; $ConnWatch = $null }
                foreach ($k in @($GameConns.Keys)) { Close-Discord $GameConns[$k] }; $GameConns = @{}
                Nap 8; continue
            }

            # ================= CARD 1: the game =================
            Update-GameCards $running

            # ================= CARD 2: music (Apple Music or Spotify) =================
            $musicActive = $false
            if ($ShowMusic -or $ShowSpotify) {
                $music = Get-MusicSession
                $session = $null; $player = ''
                if ($music) { $session = $music.Session; $player = $music.Player }
                $status = $null; $title = $null; $artist = $null; $album = $null; $position = 0; $duration = 0
                if ($session) {
                    $status = "$($session.GetPlaybackInfo().PlaybackStatus)"
                    $props  = Await ($session.TryGetMediaPropertiesAsync()) $PropsType
                    $title  = "$($props.Title)".Trim(); $artist = "$($props.Artist)".Trim(); $album = "$($props.AlbumTitle)".Trim()
                    # Apple Music puts "artist - album" in the artist field
                    if ($player -eq 'Apple Music' -and [string]::IsNullOrWhiteSpace($album) -and $artist) {
                        $dashes = ([char]0x2012, [char]0x2013, [char]0x2014, [char]0x2015) -join '|'
                        $m = [regex]::Match(($artist -replace $dashes, '-'), '^(.+?)\s+-\s+(.+)$')
                        if ($m.Success) { $artist = $m.Groups[1].Value.Trim(); $album = $m.Groups[2].Value.Trim() }
                    }
                    $tl = $session.GetTimelineProperties()
                    $duration = ($tl.EndTime.TotalSeconds - $tl.StartTime.TotalSeconds)
                    $position = ($tl.Position.TotalSeconds - $tl.StartTime.TotalSeconds)
                    if ($status -eq 'Playing' -and $tl.LastUpdatedTime.Year -gt 1) { $position += ([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalSeconds }
                    if ($duration -gt 0) { $position = [math]::Max(0, [math]::Min($position, $duration)) }
                }
                $musicActive = [bool]($status -eq 'Playing' -and $title)
            }
            # the overlay shows this
            $Sync.Now = if ($title) { @{ Title = $title; Artist = $artist; Player = $player; Playing = $musicActive; Line = '' } } else { $null }
            if ($musicActive -and (Connect-Discord $ConnMusic)) {
                $lyrics  = Get-SyncedLyrics $artist $title $album $duration
                $curLine = Get-CurrentLyricLine $lyrics $position
                if ($ShowLyrics -and $curLine -and $Sync.Now) { $Sync.Now.Line = "$curLine" }
                $id = "music|$player|$artist|$title|$album"
                $trackChanged = ($ConnMusic.Id -ne $id)
                $lyricChanged = ($ShowLyrics -and $curLine -and $curLine -ne $lastLyricLine)
                if ($trackChanged -or $lyricChanged -or (([datetime]::UtcNow - $ConnMusic.SentUtc).TotalSeconds -ge 15)) {
                    $art = Get-AlbumArtUrl $artist $title $album
                    $startMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [int64]([math]::Round($position * 1000))
                    $activity = @{
                        type = 2; details = $title
                        assets = @{ large_image = $(if ($art) { $art } else { $FALLBACK_IMAGE }); large_text = $(if ($album) { "$title - $album" } else { $title }) }
                        timestamps = @{ start = $startMs }
                    }
                    # the lyric line, else the artist; a podcast or an ad has neither
                    if ($ShowLyrics -and $curLine) { $activity.state = $curLine } elseif ($artist) { $activity.state = "by $artist" }
                    if ($artist) { $activity.name = $artist }
                    if ($duration -gt 0) { $activity.timestamps.end = $startMs + [int64]([math]::Round($duration * 1000)) }
                    if (Push-Card $ConnMusic $activity $id $trackChanged) {
                        if ($trackChanged) { Log "Music ($player): $artist - $title"; $lastLyricLine = $null }
                        if ($lyricChanged) { $lastLyricLine = $curLine }
                    }
                }
            } elseif (-not $musicActive) {
                Clear-Card $ConnMusic
                Close-Discord $ConnMusic
            }

            # ================= CARD 3: what you're watching, otherwise the app you're using =================
            $appShown = $false; $watch = $null; $watchShown = $false
            if ($ShowWatching) { try { $watch = Find-Watching } catch { $watch = $null } }
            # a service with its own Discord app gets its own card; the others take over the app card
            $watchConn = $null
            if ($watch -and $watch.Svc.Id) {
                if ($ConnWatch -and $ConnWatch.ClientId -ne $watch.Svc.Id) { Clear-Card $ConnWatch; Close-Discord $ConnWatch; $ConnWatch = $null }
                if (-not $ConnWatch) { $ConnWatch = New-Conn $watch.Svc.Id 'watching' }
                $watchConn = $ConnWatch
            } elseif ($watch) { $watchConn = $ConnApp }
            if ($ConnWatch -and $watchConn -ne $ConnWatch) { Clear-Card $ConnWatch; Close-Discord $ConnWatch; $ConnWatch = $null }

            if ($watchConn -and (Connect-Discord $watchConn)) {
                $sv = $watch.Svc
                $show = if ($ShowWatchTitle) { $watch.Show } else { '' }
                $wkey = "watch|$($sv.Name)|$($watch.Show)"
                if ($wkey -ne $script:WatchKey) { $script:WatchKey = $wkey; $script:WatchStart = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
                $id = "$wkey|$($watch.Sub)"
                $changed = ($watchConn.Id -ne $id)
                if ($changed -or (([datetime]::UtcNow - $watchConn.SentUtc).TotalSeconds -ge 20)) {
                    $logo = Get-ServiceLogo $sv
                    # the video's own thumbnail (YouTube/Twitch, from the extension), else a poster lookup
                    $poster = if ($ShowPoster -and $watch.Image) { $watch.Image }
                              elseif ($show -and -not $sv.Casual) { Get-Poster $show $watch.Sub } else { $null }
                    $act = @{ type = 3; name = $sv.Name }
                    # the poster big with the service logo small; a service's own app shows its own icon when there's no poster
                    if ($poster) { $act.assets = @{ large_image = $poster; large_text = $(if ($show.Length -ge 2) { $show } else { $sv.Name }); small_image = $logo; small_text = $sv.Name } }
                    elseif (-not $sv.Id) { $act.assets = @{ large_image = $logo; large_text = $sv.Name } }
                    if ($show.Length -ge 2) { $act.details = Limit-Text $show 128 }
                    if ($ShowWatchTitle -and $watch.Sub.Length -ge 2) { $act.state = Limit-Text $watch.Sub 128 }
                    # a real progress bar when the site reports where you are, otherwise time since it started
                    if ($watch.Dur -gt 60 -and $watch.Pos -ge 0 -and $watch.Pos -le $watch.Dur) {
                        $st = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [int64]($watch.Pos * 1000)
                        $act.timestamps = @{ start = $st; end = $st + [int64]($watch.Dur * 1000) }
                    } else { $act.timestamps = @{ start = $script:WatchStart } }
                    if ((Push-Card $watchConn $act $id $changed) -and $changed) { Log ("Watching: $($sv.Name)" + $(if ($show) { " - $show" } else { '' })) }
                }
                $watchShown = $true
            }
            if (-not $watch) { $script:WatchKey = $null }

            # while something is being watched the app card stays away (it would just say "Microsoft Edge")
            if ($watchShown) { if ($watchConn -ne $ConnApp) { Clear-Card $ConnApp } }
            elseif ($ShowApps -and (Connect-Discord $ConnApp)) {
                $fg = Get-Foreground
                if ($fg) {
                    $lastValidAppUtc = [datetime]::UtcNow
                    if ($fg.Proc -ne $appPendProc) { $appPendProc = $fg.Proc; $appPendSince = [datetime]::UtcNow }
                    $settled = ([datetime]::UtcNow - $appPendSince).TotalSeconds
                    $id = "app|$($fg.Label)"
                    $isNew = ($ConnApp.Id -ne $id) -and ($settled -ge 3)
                    if ($isNew -or ($ConnApp.Id -eq $id) -or (([datetime]::UtcNow - $ConnApp.SentUtc).TotalSeconds -ge 20)) {
                        if ($isNew -or -not $appStartMs) { $appStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
                        # browsers: just the tab's title, without "and 3 more pages - Personal - Microsoft Edge"
                        $detail = ($fg.Title -replace $BrowserSuffix, '') -replace '\s+and \d+ more pages?.*$', ''
                        if ($detail.Length -gt 128) { $detail = $detail.Substring(0, 125) + '...' }
                        $activity = @{ type = 0; name = $fg.Label; timestamps = @{ start = $appStartMs } }
                        if ($detail -and $detail -ne $fg.Label) { $activity.details = $detail }
                        $activity.assets = @{ large_image = $(if ($fg.Icon) { $fg.Icon } else { $GENERIC_APP_ICON }); large_text = $fg.Label }
                        if (Push-Card $ConnApp $activity $id $isNew) { if ($isNew) { Log "App: $($fg.Label)" } }
                    }
                    $appShown = $true; $Sync.AppLabel = $fg.Label
                }
                # ignored window (Discord itself, or the game): keep the last app for a few minutes
                elseif ("$($ConnApp.Id)" -like 'app|*' -and $lastValidAppUtc -and (([datetime]::UtcNow - $lastValidAppUtc).TotalSeconds -lt 300)) { $appShown = $true }
                if (-not $appShown) { Clear-Card $ConnApp }
            } elseif (-not $ShowApps) {
                Clear-Card $ConnApp; Close-Discord $ConnApp
            }

            # ================= CARD 4+: your custom statuses =================
            Update-CustomCards

            $parts = @()
            if ($running.Count) { $parts += "Playing $($running[0].G.name)" }
            if ($musicActive)   { $parts += "Listening: $title" }
            if ($watchShown)    { $parts += "Watching $($watch.Svc.Name)" }
            if ($appShown -and -not $running.Count) { $parts += "App: $($Sync.AppLabel)" }
            if ($script:CustomShown) { $parts += $(if ($script:CustomShown -gt 1) { "$($script:CustomShown) custom statuses" } else { 'Custom status' }) }
            $Sync.Status = if ($parts.Count) { $parts -join '  |  ' } else { 'Watching for games' }
            Nap 3
        }
        catch {
            Log "Error: $($_.Exception.Message)"
            Close-Discord $ConnMusic; Close-Discord $ConnApp; Close-CustomConns; if ($ConnWatch) { Close-Discord $ConnWatch; $ConnWatch = $null }
            foreach ($k in @($GameConns.Keys)) { Close-Discord $GameConns[$k] }; $GameConns = @{}
            Nap 5
        }
    }

    # stopped: remove our cards
    Clear-Card $ConnMusic; Clear-Card $ConnApp
    foreach ($k in @($CustomConns.Keys)) { Clear-Card $CustomConns[$k] }
    if ($ConnWatch) { Clear-Card $ConnWatch }
    Close-Discord $ConnMusic; Close-Discord $ConnApp; Close-CustomConns; if ($ConnWatch) { Close-Discord $ConnWatch; $ConnWatch = $null }
    foreach ($k in @($GameConns.Keys)) { Close-Discord $GameConns[$k] }
    Log "Presence stopped."
}

# ===========================================================================
# UPDATER - runs on a background runspace. Looks at the latest GitHub release and, if it's newer,
# downloads RichPresence.exe and checks it against the SHA-256 GitHub publishes for it.
# ===========================================================================
$Updater = {
    param($Sync, $Current, $DataDir)
    $ErrorActionPreference = 'Stop'
    function Log($m) { $Sync.Queue.Enqueue(("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m)) }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/noice912/Discord-status/releases/latest' -Headers @{ 'User-Agent' = 'RichPresence updater' } -TimeoutSec 20
        $latest = "$($rel.tag_name)".TrimStart('v')
        $Sync.LatestVersion = $latest
        if ([version]$latest -le [version]$Current) { $Sync.UpdateState = 'current'; return }
        $asset = @($rel.assets) | Where-Object { $_.name -eq 'RichPresence.exe' } | Select-Object -First 1
        if (-not $asset) { $Sync.UpdateState = 'current'; return }
        $dir = Join-Path $DataDir 'update'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir "RichPresence-$latest.exe"
        Log "Downloading update $latest..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $file -UseBasicParsing -Headers @{ 'User-Agent' = 'RichPresence updater' } -TimeoutSec 120
        $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
        $want = "$($asset.digest)" -replace '^sha256:', ''
        if (-not $want) { Remove-Item $file -Force; Log "Update $latest has no published checksum, so it wasn't installed."; $Sync.UpdateState = 'failed'; return }
        if ($hash -ne $want.ToLower()) { Remove-Item $file -Force; Log "Update $latest didn't match its checksum and was deleted."; $Sync.UpdateState = 'failed'; return }
        $Sync.UpdateHash = $want.ToLower()      # checked again just before installing
        $Sync.UpdateFile = $file
        $Sync.UpdateState = 'ready'
        Log "Update $latest downloaded and verified."
    } catch {
        $Sync.UpdateState = 'failed'
        Log "Couldn't check for updates: $($_.Exception.Message)"
    }
}

# ===========================================================================
# BRIDGE - runs on a background runspace for as long as the app is open. The browser extension
# (extension\ folder) tells it what's playing on Netflix/Hulu. It only listens on this PC (127.0.0.1),
# and only accepts browser-extension requests: a website can't send the X-RichPresence header without
# a CORS preflight, which is never allowed, and its Origin is never chrome-extension://.
# ===========================================================================
$BridgePort = 47610
$Bridge = {
    param($Sync, $Port, $Version)
    # the services the extension may report (same names as the engine's streaming table)
    $ExtServices = 'Netflix', 'Hulu', 'Disney+', 'Prime Video', 'Max', 'Crunchyroll', 'Paramount+', 'Peacock', 'Apple TV+', 'Plex', 'YouTube', 'Twitch'
    $ErrorActionPreference = 'Stop'
    function Log($m) { $Sync.Queue.Enqueue(("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m)) }
    function Send-Response($stream, [int]$code, [string]$status, [string]$body, [string]$origin) {
        $hdr = "HTTP/1.1 $code $status`r`nConnection: close`r`nCache-Control: no-store`r`n"
        if ($origin) { $hdr += "Access-Control-Allow-Origin: $origin`r`nAccess-Control-Allow-Headers: content-type, x-richpresence`r`nAccess-Control-Allow-Methods: GET, POST`r`n" }
        $b = [Text.Encoding]::UTF8.GetBytes($body)
        if ($b.Length) { $hdr += "Content-Type: application/json; charset=utf-8`r`n" }
        $h = [Text.Encoding]::ASCII.GetBytes($hdr + "Content-Length: $($b.Length)`r`n`r`n")
        $stream.Write($h, 0, $h.Length); if ($b.Length) { $stream.Write($b, 0, $b.Length) }
    }
    function Clip($v, $n) { $t = ("$v" -replace '[\r\n\t]+', ' ').Trim(); if ($t.Length -gt $n) { $t = $t.Substring(0, $n) }; $t }
    # every tab of a service reports separately: a playing tab wins over a paused one, then the newest report
    # (the same choice as the engine's Get-ExtReport)
    function Select-Report($tabs, $maxAge) {
        $best = $null
        if ($tabs) {
            foreach ($e in @($tabs.Values)) {
                if (([datetime]::UtcNow - $e.At).TotalSeconds -ge $maxAge) { continue }
                if (-not $best -or ($e.Playing -and -not $best.Playing) -or ($e.Playing -eq $best.Playing -and $e.At -gt $best.At)) { $best = $e }
            }
        }
        $best
    }
    $Logged = @{}     # service -> the "title|episode" last written to the log

    $listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    try { $listener.Start() } catch { Log "Browser extension link unavailable (port $Port is busy)."; return }
    try {
        while (-not $Sync.BridgeStop) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 150; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $client.ReceiveTimeout = 2000; $client.SendTimeout = 2000
                $stream = $client.GetStream()
                # request line + headers (8 KB max), then the body
                $buf = New-Object byte[] 8192; $got = 0; $end = -1
                while ($end -lt 0 -and $got -lt $buf.Length) {
                    $n = $stream.Read($buf, $got, $buf.Length - $got); if ($n -le 0) { break }; $got += $n
                    $end = ([Text.Encoding]::ASCII.GetString($buf, 0, $got)).IndexOf("`r`n`r`n")
                }
                if ($end -lt 0) { continue }
                $head = [Text.Encoding]::ASCII.GetString($buf, 0, $end) -split "`r`n"
                $parts = $head[0] -split ' '
                $method = $parts[0]; $path = "$($parts[1])"
                $h = @{}
                foreach ($line in $head | Select-Object -Skip 1) { $i = $line.IndexOf(':'); if ($i -gt 0) { $h[$line.Substring(0, $i).Trim().ToLower()] = $line.Substring($i + 1).Trim() } }
                $origin = "$($h['origin'])"
                $fromExtension = $origin -match '^(chrome|moz)-extension://[\w-]+$' -and $h['x-richpresence'] -eq '1'
                $allow = if ($origin -match '^(chrome|moz)-extension://[\w-]+$') { $origin } else { $null }

                if ($method -eq 'OPTIONS') { Send-Response $stream 204 'No Content' '' $allow; continue }
                if (-not $fromExtension) { Send-Response $stream 403 'Forbidden' '' $null; continue }

                if ($method -eq 'GET' -and $path -eq '/status') {
                    $list = @(foreach ($k in @($Sync.Ext.Keys)) {
                        $e = Select-Report $Sync.Ext[$k] 30
                        if ($e) { @{ service = $k; title = $e.Title; episode = $e.Episode; playing = $e.Playing } }
                    })
                    Send-Response $stream 200 'OK' (@{ app = 'RichPresence'; version = $Version; watching = $list } | ConvertTo-Json -Depth 4 -Compress) $allow
                    continue
                }
                if ($method -eq 'POST' -and $path -eq '/watching') {
                    $len = 0; [void][int]::TryParse("$($h['content-length'])", [ref]$len)
                    if ($len -le 0 -or $len -gt 8192) { Send-Response $stream 400 'Bad Request' '' $allow; continue }
                    $body = New-Object byte[] $len
                    $have = [math]::Min($got - ($end + 4), $len)
                    if ($have -gt 0) { [Array]::Copy($buf, $end + 4, $body, 0, $have) }
                    while ($have -lt $len) { $n = $stream.Read($body, $have, $len - $have); if ($n -le 0) { break }; $have += $n }
                    $j = [Text.Encoding]::UTF8.GetString($body, 0, $have) | ConvertFrom-Json
                    $svc = "$($j.service)"
                    if ($svc -notin $ExtServices) { Send-Response $stream 400 'Bad Request' '' $allow; continue }
                    # an older extension sends no tab id: all its tabs share one slot, as before
                    $tab = "$($j.tab)"
                    if ($tab -notmatch '^[\w-]{1,64}$') { $tab = 'default' }
                    # numbers always arrive with a dot, whatever this PC's language is
                    $pos = 0.0; $dur = 0.0; $num = [Globalization.NumberStyles]::Float; $inv = [Globalization.CultureInfo]::InvariantCulture
                    [void][double]::TryParse("$($j.position)", $num, $inv, [ref]$pos); [void][double]::TryParse("$($j.duration)", $num, $inv, [ref]$dur)
                    # a thumbnail is only taken from the sites' own image servers
                    $img = "$($j.image)".Trim()
                    if ($img -notmatch '^https://(i\.ytimg\.com/vi/[\w-]{6,20}/\w+\.jpg|static-cdn\.jtvnw\.net/previews-ttv/live_user_\w{3,25}-\d+x\d+\.jpg)$') { $img = '' }
                    $new = @{ Title = (Clip $j.title 128); Episode = (Clip $j.episode 128); Image = $img; Playing = [bool]$j.playing; Pos = $pos; Dur = $dur; At = [datetime]::UtcNow }
                    # a fresh table every time (the engine may be reading the old one), without tabs gone quiet for a minute
                    $tabs = @{}
                    $old = $Sync.Ext[$svc]
                    if ($old) { foreach ($k in @($old.Keys)) { if (([datetime]::UtcNow - $old[$k].At).TotalSeconds -lt 60) { $tabs[$k] = $old[$k] } } }
                    $tabs[$tab] = $new
                    $Sync.Ext[$svc] = $tabs
                    # log the report that is shown, when it changes (not every tab's every report)
                    $pick = Select-Report $tabs 15
                    if ($pick -and $pick.Playing -and $pick.Title -and $Logged[$svc] -ne "$($pick.Title)|$($pick.Episode)") {
                        $Logged[$svc] = "$($pick.Title)|$($pick.Episode)"
                        Log ("Browser extension: {0} - {1}{2}" -f $svc, $pick.Title, $(if ($pick.Episode) { " - $($pick.Episode)" } else { '' }))
                    }
                    Send-Response $stream 204 'No Content' '' $allow
                    continue
                }
                Send-Response $stream 404 'Not Found' '' $allow
            } catch {
            } finally { try { $client.Close() } catch {} }
        }
    } finally { try { $listener.Stop() } catch {} }
}

# ===========================================================================
# Runner helpers
# ===========================================================================
function New-Sync {
    [hashtable]::Synchronized(@{
        Stop = $false; Queue = (New-Object System.Collections.Concurrent.ConcurrentQueue[string])
        Status = 'Stopped'; Games = @(); RunningIds = @(); WatchId = $null; GameExited = $false; ScanDone = $false; AppLabel = ''
        Now = $null; UpdateState = ''; UpdateFile = $null; UpdateHash = ''; LatestVersion = ''; Custom = @{ Mode = 'separate'; Items = @() }
        Ext = [hashtable]::Synchronized(@{}); BridgeStop = $false     # what the browser extension reports: service -> (tab -> report)
    })
}
function Start-Block($block, $arguments) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($block.ToString())
    foreach ($a in $arguments) { [void]$ps.AddArgument($a) }
    [pscustomobject]@{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}
function Stop-Block($job, $sync, $wait) {
    if (-not $job) { return }
    if ($sync) { $sync.Stop = $true }
    if ($wait) { [void]$job.Handle.AsyncWaitHandle.WaitOne($wait) }
    # Disposing a block that is still busy waits for it to stop, however long that takes:
    # hand that to a thread-pool thread so the window never freezes on it.
    if (-not $job.Handle.IsCompleted) {
        try {
            if (-not ('RPReap' -as [type])) {
                Add-Type 'using System; using System.Threading; public static class RPReap { public static void Later(IDisposable a, IDisposable b) { ThreadPool.QueueUserWorkItem(delegate { try { a.Dispose(); } catch {} try { b.Dispose(); } catch {} }); } }'
            }
            [RPReap]::Later($job.PS, $job.RS)
            return
        } catch {}
    }
    try { $job.PS.Dispose(); $job.RS.Dispose() } catch {}
}
# what a finished block died of, if anything (errors outside its own try/catch end up here and nowhere else)
function Get-BlockErrors($job) {
    $out = @()
    try {
        foreach ($er in @($job.PS.Streams.Error)) { $out += "$er" }
        $why = $job.PS.InvocationStateInfo.Reason
        if ($why -and $out -notcontains "$($why.Message)") { $out += "$($why.Message)" }
    } catch {}
    $out
}
function Read-Library {
    if (-not (Test-Path $LibraryPath)) { return @() }
    try {
        $j = Get-Content $LibraryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($j | ForEach-Object { $_ })     # Windows PowerShell 5.1 returns the JSON array as one object - unwrap it
    } catch { return @() }
}
function New-EngineGames($library, $settings) {
    @($library | ForEach-Object {
        @{ id = $_.id; name = $_.name; exes = @($_.exes); discordId = $(if ($_.discordId) { "$($_.discordId)" } else { $null })
           enabled = (@($settings.disabled_games) -notcontains $_.id) }
    })
}

if ($ScanOnly) {
    $s = Load-Settings
    $res = & $Scanner $s $null $DataDir
    $res | ForEach-Object { "{0,-34} {1,-7} discord={2,-20} exes={3}" -f $_.name, $_.store, $(if ($_.discordId) { $_.discordId } else { '-' }), (($_.exes | Select-Object -First 3) -join ',') }
    exit
}

if ($Headless) {
    $settings = Add-BuiltInIds (Load-Settings)
    $sync = New-Sync
    $sync.Games = New-EngineGames (Read-Library) $settings
    $sync.Custom = @{ Mode = "$($settings.custom_mode)"; Items = @($settings.custom_statuses) }
    $job = Start-Block $Engine @($settings, $sync)
    $bridgeJob = Start-Block $Bridge @($sync, $BridgePort, $AppVersion)
    Write-Host "RichPresence (headless) - Ctrl+C to stop"
    try {
        while ($true) {
            $line = $null
            while ($sync.Queue.TryDequeue([ref]$line)) { Write-Host $line }
            if ($job.Handle.IsCompleted) { foreach ($m in (Get-BlockErrors $job)) { Write-Host "Presence stopped with an error: $m" }; break }
            Start-Sleep -Milliseconds 300
        }
    } finally { Stop-Block $job $sync 8000; $sync.BridgeStop = $true; Stop-Block $bridgeJob $null 2000 }
    exit
}

# ===========================================================================
# Window
# ===========================================================================
$PlayRequestPath = Join-Path $DataDir 'play.request'     # a game id handed over by a second "-Play <id>" launch
$mutex = New-Object System.Threading.Mutex($false, 'Local\RichPresenceLauncher')
if (-not $mutex.WaitOne(0)) {
    if ($Play) {
        # a desktop shortcut while RichPresence is already open: pass the game to the running one and leave quietly
        try {
            [IO.File]::WriteAllText("$PlayRequestPath.tmp", $Play, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath "$PlayRequestPath.tmp" -Destination $PlayRequestPath -Force
        } catch {}
        exit
    }
    [System.Windows.Forms.MessageBox]::Show('RichPresence is already running - check your system tray.', 'RichPresence') | Out-Null
    exit
}
try { Remove-Item -LiteralPath $PlayRequestPath -Force } catch {}     # a request left over from last time is stale
[System.Windows.Forms.Application]::EnableVisualStyles()
# the custom status preview loads picture links itself
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Settings = Load-Settings
$Sync     = New-Sync
$script:Job = $null; $script:ScanJob = $null; $script:RescanPending = $false
$script:Library = @(Read-Library)
$script:Tiles = @{}
$script:reallyQuit = $false
$script:PendingPlay = $Play

$SelfPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$IsExe    = $SelfPath -like '*.exe' -and $SelfPath -notmatch 'powershell|pwsh'

# ---- look & feel
function C($hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
$cBg = C '#14161b'; $cSide = C '#0f1115'; $cCard = C '#1f232b'; $cCardHi = C '#272c36'; $cText = C '#e8eaf0'; $cDim = C '#8b91a1'
$cAccent = C '#5865f2'; $cGreen = C '#3ba55d'
$fUi = New-Object System.Drawing.Font('Segoe UI', 9)
$fBold = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$fTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 17)
$fSmall = New-Object System.Drawing.Font('Segoe UI', 8)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'RichPresence'
$form.Font = $fUi; $form.BackColor = $cBg; $form.ForeColor = $cText
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(1000, 660)
$form.MinimumSize = New-Object System.Drawing.Size(820, 520)
try { if ($IsExe) { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($SelfPath) } } catch {}

function New-Ctl($type, $parent, $props) {
    $c = New-Object $type
    foreach ($k in $props.Keys) { $c.$k = $props[$k] }
    if ($parent) { $parent.Controls.Add($c) }
    $c
}
function Pt($x, $y) { New-Object System.Drawing.Point($x, $y) }
function Sz($w, $h) { New-Object System.Drawing.Size($w, $h) }
function Style-Button($b, $primary) {
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.Cursor = 'Hand'; $b.Font = $fBold
    if ($primary) { $b.BackColor = $cAccent; $b.ForeColor = [System.Drawing.Color]::White } else { $b.BackColor = $cCardHi; $b.ForeColor = $cText }
}

# ---- sidebar
$side = New-Ctl System.Windows.Forms.Panel $form @{ Dock = 'Left'; Width = 190; BackColor = $cSide }
$brand = New-Ctl System.Windows.Forms.Label $side @{ Text = 'RichPresence'; Font = $fTitle; ForeColor = $cText; Location = (Pt 16 16); AutoSize = $true }
$brandSub = New-Ctl System.Windows.Forms.Label $side @{ Text = 'your games on Discord'; Font = $fSmall; ForeColor = $cDim; Location = (Pt 18 50); AutoSize = $true }
$navButtons = @{}
$navY = 92
foreach ($n in 'Games', 'Music & Apps', 'Custom status', 'Settings', 'Log') {
    $b = New-Ctl System.Windows.Forms.Button $side @{ Text = "   $n"; UseMnemonic = $false; TextAlign = 'MiddleLeft'; Location = (Pt 0 $navY); Size = (Sz 190 40) }
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.Font = $fBold; $b.ForeColor = $cDim; $b.BackColor = $cSide; $b.Cursor = 'Hand'
    $navButtons[$n] = $b; $navY += 42
}
$statusLbl = New-Ctl System.Windows.Forms.Label $side @{ Text = 'Presence off'; ForeColor = $cDim; Font = $fSmall; Location = (Pt 16 590); Size = (Sz 166 30); Anchor = 'Bottom, Left' }
$btnToggle = New-Ctl System.Windows.Forms.Button $side @{ Text = 'Start presence'; Location = (Pt 12 620); Size = (Sz 166 32); Anchor = 'Bottom, Left' }
Style-Button $btnToggle $true

$content = New-Ctl System.Windows.Forms.Panel $form @{ Dock = 'Fill'; BackColor = $cBg }
$content.BringToFront()

function New-Page { New-Ctl System.Windows.Forms.Panel $content @{ Dock = 'Fill'; BackColor = $cBg; Visible = $false; Padding = (New-Object System.Windows.Forms.Padding(20)) } }
$pGames = New-Page; $pMusic = New-Page; $pCustom = New-Page; $pSettings = New-Page; $pLog = New-Page
$pSettings.AutoScroll = $true      # the list is longer than the smallest window
$pages = @{ 'Games' = $pGames; 'Music & Apps' = $pMusic; 'Custom status' = $pCustom; 'Settings' = $pSettings; 'Log' = $pLog }
function Show-Page($name) {
    foreach ($k in $pages.Keys) {
        $pages[$k].Visible = ($k -eq $name)
        $navButtons[$k].BackColor = $(if ($k -eq $name) { $cCardHi } else { $cSide })
        $navButtons[$k].ForeColor = $(if ($k -eq $name) { $cText } else { $cDim })
    }
}
foreach ($k in $navButtons.Keys) { $navButtons[$k].Tag = $k; $navButtons[$k].add_Click({ Show-Page $this.Tag }) }

# ---- Games page
$gHead = New-Ctl System.Windows.Forms.Panel $pGames @{ Dock = 'Top'; Height = 60 }
$gTitle = New-Ctl System.Windows.Forms.Label $gHead @{ Text = 'My games'; Font = $fTitle; Location = (Pt 0 6); AutoSize = $true }
$gCount = New-Ctl System.Windows.Forms.Label $gHead @{ Text = ''; ForeColor = $cDim; Location = (Pt 3 40); AutoSize = $true }
$txtSearch = New-Ctl System.Windows.Forms.TextBox $gHead @{ Location = (Pt 300 12); Size = (Sz 170 24); BackColor = $cCard; ForeColor = $cText; BorderStyle = 'FixedSingle' }
$btnRescan = New-Ctl System.Windows.Forms.Button $gHead @{ Text = 'Rescan'; Location = (Pt 484 9); Size = (Sz 84 30) }
$btnAdd    = New-Ctl System.Windows.Forms.Button $gHead @{ Text = '+ Add game'; Location = (Pt 576 9); Size = (Sz 104 30) }
Style-Button $btnRescan $false; Style-Button $btnAdd $false
$flow = New-Ctl System.Windows.Forms.FlowLayoutPanel $pGames @{ Dock = 'Fill'; AutoScroll = $true; BackColor = $cBg; Padding = (New-Object System.Windows.Forms.Padding(0, 6, 0, 0)) }
$flow.BringToFront()
$emptyLbl = New-Ctl System.Windows.Forms.Label $pGames @{ Text = 'Looking for your games...'; ForeColor = $cDim; Font = $fBold; Dock = 'Top'; Height = 40; Visible = $false }

# ---- Music & Apps page
$mTitle = New-Ctl System.Windows.Forms.Label $pMusic @{ Text = 'Music, video & apps'; UseMnemonic = $false; Font = $fTitle; Location = (Pt 20 20); AutoSize = $true }
$mNote = New-Ctl System.Windows.Forms.Label $pMusic @{ Text = "These show as their own Discord cards next to your game. Apple Music: use the Microsoft Store app.`nWatching works in Chrome, Edge, Firefox, Brave, Opera and the services' Windows apps. Each service shows as its own card with its logo (Plex, YouTube and Twitch use the app card)."; ForeColor = $cDim; Location = (Pt 22 58); AutoSize = $true }
function New-Check($parent, $text, $y) { New-Ctl System.Windows.Forms.CheckBox $parent @{ Text = $text; Location = (Pt 24 $y); AutoSize = $true; ForeColor = $cText } }
$chkMusic  = New-Check $pMusic 'Show what I''m playing on Apple Music' 110
$chkSpotify = New-Check $pMusic 'Show Spotify (with lyrics)' 138
$spotifyHint = New-Ctl System.Windows.Forms.Label $pMusic @{ Text = 'If Discord also shows its own Spotify card, turn off "Display Spotify as your status" in Discord''s Connections.'; UseMnemonic = $false; ForeColor = $cDim; Font = $fSmall; Location = (Pt 42 160); Size = (Sz 560 30) }
$chkLyrics = New-Check $pMusic 'Show the current lyric line' 196
$chkArt    = New-Check $pMusic 'Show album art' 224
$chkApps   = New-Check $pMusic 'Show the app I''m using when nothing else is showing' 252
$chkWatch  = New-Check $pMusic 'Show what I''m watching (Netflix, Hulu, Disney+, Prime Video, Max and more)' 288
$chkWatchTitle  = New-Check $pMusic 'Show the show or movie name' 316
$chkWatchPoster = New-Check $pMusic 'Show its poster (looked up on TVMaze and Cinemeta)' 344
$chkWatchCasual = New-Check $pMusic 'Also YouTube and Twitch' 372
foreach ($c in $chkWatchTitle, $chkWatchPoster, $chkWatchCasual) { $c.Left = 44 }
$chkWatch.add_CheckedChanged({ foreach ($c in $chkWatchTitle, $chkWatchPoster, $chkWatchCasual) { $c.Enabled = $chkWatch.Checked } })
$btnMusicSave = New-Ctl System.Windows.Forms.Button $pMusic @{ Text = 'Apply'; Location = (Pt 24 418); Size = (Sz 100 32) }
Style-Button $btnMusicSave $true

# ---- Custom status page: a list of your own cards on the left, the selected one's editor on the right
$CustomTypes     = @(0, 2, 3, 5)
$CustomTypeNames = @('Playing', 'Listening to', 'Watching', 'Competing in')
$cTitle = New-Ctl System.Windows.Forms.Label $pCustom @{ Text = 'Custom status'; Font = $fTitle; Location = (Pt 20 20); AutoSize = $true }
$cNote = New-Ctl System.Windows.Forms.Label $pCustom @{ Text = 'Your own Discord cards: your text, your pictures, up to two buttons. Make as many as you like and tick the ones to show.'; ForeColor = $cDim; Location = (Pt 22 58); AutoSize = $true }
$lstC = New-Ctl System.Windows.Forms.CheckedListBox $pCustom @{ Location = (Pt 24 88); Size = (Sz 196 236); BackColor = $cCard; ForeColor = $cText; BorderStyle = 'None'; IntegralHeight = $false }
$btnCNew  = New-Ctl System.Windows.Forms.Button $pCustom @{ Text = '+ New'; Location = (Pt 24 332); Size = (Sz 96 28) }
$btnCCopy = New-Ctl System.Windows.Forms.Button $pCustom @{ Text = 'Duplicate'; Location = (Pt 124 332); Size = (Sz 96 28) }
$btnCUp   = New-Ctl System.Windows.Forms.Button $pCustom @{ Text = 'Up'; Location = (Pt 24 364); Size = (Sz 62 28) }
$btnCDown = New-Ctl System.Windows.Forms.Button $pCustom @{ Text = 'Down'; Location = (Pt 90 364); Size = (Sz 62 28) }
$btnCDel  = New-Ctl System.Windows.Forms.Button $pCustom @{ Text = 'Delete'; Location = (Pt 156 364); Size = (Sz 64 28) }
foreach ($b in $btnCNew, $btnCCopy, $btnCUp, $btnCDown, $btnCDel) { Style-Button $b $false; $b.Font = $fUi }
$rdoCSep   = New-Ctl System.Windows.Forms.RadioButton $pCustom @{ Text = 'Each one is its own card'; Location = (Pt 24 402); AutoSize = $true; ForeColor = $cText }
$rdoCMerge = New-Ctl System.Windows.Forms.RadioButton $pCustom @{ Text = 'Merge them into one card'; Location = (Pt 24 426); AutoSize = $true; ForeColor = $cText }
$btnCSave = New-Ctl System.Windows.Forms.Button $pCustom @{ Text = 'Save && show'; Location = (Pt 24 460); Size = (Sz 196 34) }
Style-Button $btnCSave $true
$lblCInfo = New-Ctl System.Windows.Forms.Label $pCustom @{ Text = ''; UseMnemonic = $false; ForeColor = $cDim; Font = $fSmall; Location = (Pt 24 502); Size = (Sz 196 150) }

$ed = New-Ctl System.Windows.Forms.Panel $pCustom @{ Location = (Pt 240 88); Size = (Sz 540 520); AutoScroll = $true; Enabled = $false }
$pCustom.add_Resize({ $ed.Size = Sz ([math]::Max(200, $pCustom.ClientSize.Width - 260)) ([math]::Max(200, $pCustom.ClientSize.Height - 108)) })
function New-EdLabel($text, $x, $y) { New-Ctl System.Windows.Forms.Label $ed @{ Text = $text; UseMnemonic = $false; ForeColor = $cDim; Location = (Pt $x $y); AutoSize = $true } }
function New-EdBox($x, $y, $w) { New-Ctl System.Windows.Forms.TextBox $ed @{ Location = (Pt $x $y); Size = (Sz $w 24); BackColor = $cCard; ForeColor = $cText; BorderStyle = 'FixedSingle' } }
$chkCOn = New-Ctl System.Windows.Forms.CheckBox $ed @{ Text = 'Show this one on Discord'; Location = (Pt 0 0); AutoSize = $true; ForeColor = $cText }
[void](New-EdLabel 'Shows as' 0 28)
$cmbCType = New-Ctl System.Windows.Forms.ComboBox $ed @{ Location = (Pt 0 46); Size = (Sz 118 24); DropDownStyle = 'DropDownList'; BackColor = $cCard; ForeColor = $cText; FlatStyle = 'Flat' }
[void]$cmbCType.Items.AddRange([object[]]$CustomTypeNames)
[void](New-EdLabel 'Title' 126 28)
$txtCName    = New-EdBox 126 46 214
[void](New-EdLabel 'Line 1' 0 78);  $txtCDetails = New-EdBox 0 96 340
[void](New-EdLabel 'Line 2' 0 128); $txtCState   = New-EdBox 0 146 340
[void](New-EdLabel 'Big picture - an https:// link to an image' 0 178); $txtCLarge  = New-EdBox 0 196 340
[void](New-EdLabel 'Text when you hover the big picture' 0 228);      $txtCLargeT = New-EdBox 0 246 340
[void](New-EdLabel 'Small round picture (optional link)' 0 278);      $txtCSmall  = New-EdBox 0 296 340
[void](New-EdLabel 'Text when you hover the small picture' 0 328);    $txtCSmallT = New-EdBox 0 346 340
[void](New-EdLabel 'Button 1 - text, then link (others see it; Discord hides it from you)' 0 378)
$txtCB1L = New-EdBox 0 396 110; $txtCB1U = New-EdBox 116 396 224
[void](New-EdLabel 'Button 2' 0 428)
$txtCB2L = New-EdBox 0 446 110; $txtCB2U = New-EdBox 116 446 224
$chkCElapsed = New-Ctl System.Windows.Forms.CheckBox $ed @{ Text = 'Show how long it has been on'; Location = (Pt 0 480); AutoSize = $true; ForeColor = $cText }
[void](New-EdLabel 'Your own Discord App ID (optional)' 0 512)
$txtCAppId = New-EdBox 0 530 200
$lnkCApp = New-Ctl System.Windows.Forms.LinkLabel $ed @{ Text = 'Make one (free)'; UseMnemonic = $false; Location = (Pt 210 534); AutoSize = $true; LinkColor = $cAccent }
$lblCAppHelp = New-Ctl System.Windows.Forms.Label $ed @{ UseMnemonic = $false; ForeColor = $cDim; Font = $fSmall; Location = (Pt 0 562); Size = (Sz 340 76)
    Text = "Empty = one of RichPresence's built-in cards ($($CustomPoolIds.Count) can show at once). With your own app the card's title is your app's name, and you can upload pictures under Rich Presence > Art Assets, then type a picture's name instead of a link." }
[void](New-EdLabel 'Preview' 360 178)
$picCLarge = New-Ctl System.Windows.Forms.PictureBox $ed @{ Location = (Pt 360 196); Size = (Sz 120 120); SizeMode = 'Zoom'; BackColor = $cCardHi }
$picCSmall = New-Ctl System.Windows.Forms.PictureBox $ed @{ Location = (Pt 450 286); Size = (Sz 40 40); SizeMode = 'Zoom'; BackColor = $cCard }
$picCSmall.BringToFront()
$lblCPrev = New-Ctl System.Windows.Forms.Label $ed @{ UseMnemonic = $false; Location = (Pt 360 334); Size = (Sz 170 70); ForeColor = $cText }

# ---- Settings page
$sTitle = New-Ctl System.Windows.Forms.Label $pSettings @{ Text = 'Settings'; Font = $fTitle; Location = (Pt 20 20); AutoSize = $true }
$uidLbl = New-Ctl System.Windows.Forms.Label $pSettings @{ Text = 'Genshin UID (optional - shows your name, AR and World Level on your Genshin card)'; ForeColor = $cDim; Location = (Pt 22 64); AutoSize = $true }
$txtUid = New-Ctl System.Windows.Forms.TextBox $pSettings @{ Location = (Pt 24 88); Size = (Sz 200 24); BackColor = $cCard; ForeColor = $cText; BorderStyle = 'FixedSingle' }
$fLbl = New-Ctl System.Windows.Forms.Label $pSettings @{ Text = 'Extra game folders - one per line. Every sub-folder in them counts as a game.'; ForeColor = $cDim; Location = (Pt 22 130); AutoSize = $true }
$txtFolders = New-Ctl System.Windows.Forms.TextBox $pSettings @{ Location = (Pt 24 154); Size = (Sz 460 70); Multiline = $true; BackColor = $cCard; ForeColor = $cText; BorderStyle = 'FixedSingle'; ScrollBars = 'Vertical' }
$btnFolder = New-Ctl System.Windows.Forms.Button $pSettings @{ Text = 'Add folder...'; Location = (Pt 494 154); Size = (Sz 110 30) }
Style-Button $btnFolder $false
$chkAutoStart = New-Check $pSettings 'Start the presence when RichPresence opens' 246
$chkExit      = New-Check $pSettings 'Quit RichPresence when the game I launched closes' 274
$chkTray      = New-Check $pSettings 'Closing the window keeps it running in the tray' 302
$chkWin       = New-Check $pSettings 'Start with Windows' 330
$chkOfficial  = New-Check $pSettings 'Let Discord detect official games first (keeps streaks), then show my card after 2 minutes' 358
$chkUpdate    = New-Check $pSettings 'Install updates automatically (never while a game is running)' 386
$btnSave = New-Ctl System.Windows.Forms.Button $pSettings @{ Text = 'Save && rescan'; Location = (Pt 24 426); Size = (Sz 140 34) }
$btnUpdate = New-Ctl System.Windows.Forms.Button $pSettings @{ Text = 'Check for updates'; Location = (Pt 174 426); Size = (Sz 150 34) }
Style-Button $btnUpdate $false
$updateLbl = New-Ctl System.Windows.Forms.Label $pSettings @{ Text = "Version $AppVersion"; ForeColor = $cDim; Location = (Pt 334 436); AutoSize = $true }
Style-Button $btnSave $true
$linkGuide = New-Ctl System.Windows.Forms.LinkLabel $pSettings @{ Text = 'Help & source on GitHub'; UseMnemonic = $false; Location = (Pt 24 476); AutoSize = $true; LinkColor = $cAccent }
$chkOverlay = New-Check $pSettings 'Open the overlay over my game with this shortcut:' 512
$txtHotkey = New-Ctl System.Windows.Forms.TextBox $pSettings @{ Location = (Pt 356 510); Size = (Sz 130 24); BackColor = $cCard; ForeColor = $cText; BorderStyle = 'FixedSingle' }
$hotkeyHint = New-Ctl System.Windows.Forms.Label $pSettings @{ Text = 'Music, volume, games, OBS, lights and Discord. Shows over borderless and windowed games.'; ForeColor = $cDim; Font = $fSmall; Location = (Pt 42 536); AutoSize = $true }
$chkPad = New-Check $pSettings 'Also open it with the Xbox or PS button on my controller' 558
$chkGameBar = New-Check $pSettings 'Stop that button opening Xbox Game Bar (changes the Windows setting; untick to put it back)' 584
$chkGameBar.Left = 44
$padHint = New-Ctl System.Windows.Forms.Label $pSettings @{ Text = 'Steam has its own switch: Steam > Settings > Controller > turn off "Guide button focuses Steam".'; UseMnemonic = $false; ForeColor = $cDim; Font = $fSmall; Location = (Pt 62 608); AutoSize = $true }
$chkPad.add_CheckedChanged({ $chkGameBar.Enabled = $chkPad.Checked })

# ---- Log page
$log = New-Ctl System.Windows.Forms.TextBox $pLog @{ Dock = 'Fill'; Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; BackColor = $cCard; ForeColor = $cText; BorderStyle = 'None'; Font = (New-Object System.Drawing.Font('Consolas', 9)) }

# ---- settings <-> UI
function Apply-ToUi {
    $txtUid.Text = "$($Settings.genshin_uid)"
    $txtFolders.Text = (@($Settings.extra_folders) -join [Environment]::NewLine)
    $chkMusic.Checked = [bool]$Settings.show_music; $chkLyrics.Checked = [bool]$Settings.show_lyrics
    $chkSpotify.Checked = [bool]$Settings.show_spotify
    $chkArt.Checked = [bool]$Settings.show_album_art; $chkApps.Checked = [bool]$Settings.show_current_app
    $chkWatch.Checked = [bool]$Settings.show_watching; $chkWatchTitle.Checked = [bool]$Settings.show_watch_title
    $chkWatchPoster.Checked = [bool]$Settings.show_watch_poster; $chkWatchCasual.Checked = [bool]$Settings.show_watch_casual
    foreach ($c in $chkWatchTitle, $chkWatchPoster, $chkWatchCasual) { $c.Enabled = $chkWatch.Checked }
    $chkAutoStart.Checked = [bool]$Settings.start_presence_on_open; $chkExit.Checked = [bool]$Settings.exit_when_game_closes
    $chkTray.Checked = [bool]$Settings.close_to_tray; $chkWin.Checked = [bool]$Settings.start_with_windows
    $chkOfficial.Checked = [bool]$Settings.official_to_discord
    $chkUpdate.Checked = [bool]$Settings.auto_update
    $chkOverlay.Checked = [bool]$Settings.overlay_enabled; $txtHotkey.Text = "$($Settings.overlay_hotkey)"
    $chkPad.Checked = [bool]$Settings.overlay_controller; $chkGameBar.Checked = [bool]$Settings.gamebar_button_off; $chkGameBar.Enabled = $chkPad.Checked
}
function Read-FromUi {
    $Settings.genshin_uid = $txtUid.Text.Trim()
    $Settings.extra_folders = @($txtFolders.Text -split "`r?`n" | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
    $Settings.show_music = $chkMusic.Checked; $Settings.show_lyrics = $chkLyrics.Checked
    $Settings.show_spotify = $chkSpotify.Checked
    $Settings.show_album_art = $chkArt.Checked; $Settings.show_current_app = $chkApps.Checked
    $Settings.show_watching = $chkWatch.Checked; $Settings.show_watch_title = $chkWatchTitle.Checked
    $Settings.show_watch_poster = $chkWatchPoster.Checked; $Settings.show_watch_casual = $chkWatchCasual.Checked
    $Settings.start_presence_on_open = $chkAutoStart.Checked; $Settings.exit_when_game_closes = $chkExit.Checked
    $Settings.close_to_tray = $chkTray.Checked; $Settings.start_with_windows = $chkWin.Checked
    $Settings.official_to_discord = $chkOfficial.Checked
    $Settings.auto_update = $chkUpdate.Checked
    $Settings.overlay_enabled = $chkOverlay.Checked
    $Settings.overlay_controller = $chkPad.Checked; $Settings.gamebar_button_off = $chkGameBar.Checked
    # a shortcut that can't be used is put back to the last good one
    if (ConvertTo-Hotkey $txtHotkey.Text) { $Settings.overlay_hotkey = $txtHotkey.Text.Trim() } else { $txtHotkey.Text = "$($Settings.overlay_hotkey)" }
    Save-Settings $Settings
    Set-OverlayHotkey
    Set-OverlayController
}
function Append-Log($line) {
    $log.AppendText($line + [Environment]::NewLine)
    if ($log.TextLength -gt 30000) { $log.Text = $log.Text.Substring(15000) }
}
function Set-StartupShortcut($enable) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'RichPresence.lnk'
    if (-not $enable) { if (Test-Path $lnk) { Remove-Item $lnk -Force }; return }
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($lnk)
    if ($IsExe) { $s.TargetPath = $SelfPath; $s.Arguments = '' }
    else { $s.TargetPath = 'powershell.exe'; $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SelfPath`"" }
    $s.WindowStyle = 7; $s.Save()
}

# ---- presence control
function Push-GamesToEngine { $Sync.Games = New-EngineGames $script:Library $Settings }
function Start-Presence {
    if ($script:Job) { return }
    Read-FromUi
    $Sync.Stop = $false; $Sync.GameExited = $false; $Sync.Status = 'Starting...'
    Push-GamesToEngine; Push-CustomToEngine
    $copy = @{}
    foreach ($k in @($Settings.Keys)) { $copy[$k] = $Settings[$k] }
    $copy = Add-BuiltInIds $copy
    $script:Job = Start-Block $Engine @($copy, $Sync)
    $btnToggle.Text = 'Stop presence'
}
function Stop-Presence {
    if (-not $script:Job) { return }
    $btnToggle.Enabled = $false; $form.Cursor = 'WaitCursor'
    Stop-Block $script:Job $Sync 8000
    $script:Job = $null
    $Sync.Status = 'Stopped'; $Sync.RunningIds = @(); $Sync.Now = $null
    $btnToggle.Text = 'Start presence'; $btnToggle.Enabled = $true; $form.Cursor = 'Default'
}
function Start-Scan {
    # asked during a scan (Add game, Save & rescan, Remove): scan again as soon as this one ends
    if ($script:ScanJob -and -not $script:ScanJob.Handle.IsCompleted) { $script:RescanPending = $true; return }
    $script:RescanPending = $false
    if ($script:ScanJob) { Stop-Block $script:ScanJob $null 0 }
    $Sync.ScanDone = $false
    $emptyLbl.Visible = ($script:Library.Count -eq 0)
    $btnRescan.Text = 'Scanning...'; $btnRescan.Enabled = $false
    $copy = @{ extra_folders = @($Settings.extra_folders); custom_games = @($Settings.custom_games) }
    $script:ScanJob = Start-Block $Scanner @($copy, $Sync, $DataDir)
}

# ---- custom statuses
function New-CustomStatus($from, $keepId) {
    $h = [ordered]@{
        id = [guid]::NewGuid().ToString('N'); enabled = $false; type = 0; name = ''; details = ''; state = ''
        large_image = ''; large_text = ''; small_image = ''; small_text = ''
        button1_label = ''; button1_url = ''; button2_label = ''; button2_url = ''; elapsed = $true; app_id = ''
    }
    if ($from) { foreach ($k in @($h.Keys)) { if (($keepId -or $k -ne 'id') -and $null -ne $from.$k) { $h[$k] = $from.$k } } }
    $h
}
function Get-CustomLabel($st) {
    foreach ($v in $st.name, $st.details, $st.state) { if ("$v".Trim()) { return "$v".Trim() } }
    'Untitled'
}
$script:Customs = New-Object System.Collections.ArrayList
foreach ($x in @($Settings.custom_statuses)) { if ($x) { [void]$script:Customs.Add((New-CustomStatus $x $true)) } }
$Settings.custom_statuses = $script:Customs     # saved with the rest of the settings
$script:CurC = -1; $script:LoadingC = $false

# the engine gets its own copy, so editing never races with it
function Push-CustomToEngine {
    $Sync.Custom = @{ Mode = "$($Settings.custom_mode)"; Items = @($script:Customs | ForEach-Object { New-Object psobject -Property $_ }) }
}
function Test-CustomStatus($st) {
    $own = "$($st.app_id)".Trim()
    $p = @()
    if ($own -and $own -notmatch '^\d{17,20}$') { $p += 'The App ID should be 17-20 digits (Discord Developer Portal > your app > Application ID).' }
    foreach ($f in @(@('large_image', 'Big picture'), @('small_image', 'Small picture'))) {
        $v = "$($st[$f[0]])".Trim()
        if (-not $v) { continue }
        if ($v -match '^http://') { $p += "$($f[1]): use an https:// link." }
        elseif ($v -match '^https://') {
            if ($v.Length -gt 256) { $p += "$($f[1]): the link is too long (256 characters max)." }
            if ($v -match '(cdn\.discordapp\.com|media\.discordapp\.net)/attachments') { $p += "$($f[1]): Discord upload links expire after about a day. Host it somewhere that keeps it." }
        }
        elseif ($v -notmatch '^[\w.-]{1,128}$') { $p += "$($f[1]): that isn't a link." }
        elseif (-not $own) { $p += "$($f[1]): '$v' isn't a link. Picture names only work with your own App ID." }
    }
    foreach ($n in 1, 2) {
        $l = "$($st["button${n}_label"])".Trim(); $u = "$($st["button${n}_url"])".Trim()
        if ($l -and $u -notmatch '^https?://\S+$') { $p += "Button ${n}: needs a link starting with https://" }
        if ($u -and -not $l) { $p += "Button ${n}: needs some text." }
        if ($l.Length -gt 32) { $p += "Button ${n}: text is cut to 32 characters." }
    }
    foreach ($f in @(@('name', 'Title'), @('details', 'Line 1'), @('state', 'Line 2'))) {
        if ("$($st[$f[0]])".Trim().Length -eq 1) { $p += "$($f[1]): Discord needs at least 2 characters." }
    }
    , $p
}
function Update-CustomInfo($problems) {
    $on = @($script:Customs | Where-Object { $_.enabled })
    $shared = @($on | Where-Object { "$($_.app_id)".Trim() -notmatch '^\d{17,20}$' })
    $warn = $false
    $t = if ($on.Count -eq 0) { 'Nothing ticked yet.' }
    elseif ($Settings.custom_mode -eq 'merge' -and $on.Count -gt 1) {
        "$($on.Count) ticked, shown as one card: the top one's title, type and big picture; every line joined; the next picture becomes the small one. Use Up/Down to change the order."
    }
    elseif ($Settings.custom_mode -ne 'merge' -and $shared.Count -gt $CustomPoolIds.Count) {
        $warn = $true
        "$($on.Count) ticked, but only $($CustomPoolIds.Count) can use the built-in cards. Give the others their own App ID, or merge them into one card."
    }
    else { "$($on.Count) ticked." }
    if ($problems -and @($problems).Count) { $warn = $true; $t += "`n`n" + (@($problems) -join "`n") }
    $lblCInfo.Text = $t
    $lblCInfo.ForeColor = $(if ($warn) { C '#f0b232' } else { $cDim })
}
function Set-PreviewImage($pic, $v) {
    try { $pic.CancelAsync() } catch {}
    $pic.Image = $null
    $v = "$v".Trim()
    if ($pic -eq $picCSmall) { $pic.Visible = [bool]$v }
    if ($v -match '^https://\S+$') { try { $pic.LoadAsync($v) } catch {} }
}
function Update-CustomPreview($images) {
    $i = [math]::Max(0, $cmbCType.SelectedIndex)
    $title = $txtCName.Text.Trim(); if (-not $title) { $title = '(app name)' }
    $lblCPrev.Text = (@("$($CustomTypeNames[$i]) $title", $txtCDetails.Text.Trim(), $txtCState.Text.Trim()) | Where-Object { $_ }) -join "`n"
    if ($images) { Set-PreviewImage $picCLarge $txtCLarge.Text; Set-PreviewImage $picCSmall $txtCSmall.Text }
}
function Load-CustomEditor {
    $i = $lstC.SelectedIndex
    $script:CurC = $i
    $ed.Enabled = ($i -ge 0)
    $btnCCopy.Enabled = ($i -ge 0); $btnCDel.Enabled = ($i -ge 0)
    $btnCUp.Enabled = ($i -gt 0); $btnCDown.Enabled = ($i -ge 0 -and $i -lt $script:Customs.Count - 1)
    $st = if ($i -ge 0) { $script:Customs[$i] } else { New-CustomStatus $null $false }
    $script:LoadingC = $true
    $chkCOn.Checked = [bool]$st.enabled
    $cmbCType.SelectedIndex = [math]::Max(0, [array]::IndexOf($CustomTypes, [int]$st.type))
    $txtCName.Text = "$($st.name)"; $txtCDetails.Text = "$($st.details)"; $txtCState.Text = "$($st.state)"
    $txtCLarge.Text = "$($st.large_image)"; $txtCLargeT.Text = "$($st.large_text)"
    $txtCSmall.Text = "$($st.small_image)"; $txtCSmallT.Text = "$($st.small_text)"
    $txtCB1L.Text = "$($st.button1_label)"; $txtCB1U.Text = "$($st.button1_url)"
    $txtCB2L.Text = "$($st.button2_label)"; $txtCB2U.Text = "$($st.button2_url)"
    $chkCElapsed.Checked = [bool]$st.elapsed; $txtCAppId.Text = "$($st.app_id)"
    $script:LoadingC = $false
    Update-CustomPreview $true
}
# every edit goes straight into the selected status; "Save & show" sends them to Discord
function Save-CustomEditor {
    if ($script:LoadingC -or $script:CurC -lt 0 -or $script:CurC -ge $script:Customs.Count) { return }
    $st = $script:Customs[$script:CurC]
    $st.type = $CustomTypes[[math]::Max(0, $cmbCType.SelectedIndex)]
    $st.name = $txtCName.Text; $st.details = $txtCDetails.Text; $st.state = $txtCState.Text
    $st.large_image = $txtCLarge.Text.Trim(); $st.large_text = $txtCLargeT.Text
    $st.small_image = $txtCSmall.Text.Trim(); $st.small_text = $txtCSmallT.Text
    $st.button1_label = $txtCB1L.Text; $st.button1_url = $txtCB1U.Text.Trim()
    $st.button2_label = $txtCB2L.Text; $st.button2_url = $txtCB2U.Text.Trim()
    $st.elapsed = $chkCElapsed.Checked; $st.app_id = $txtCAppId.Text.Trim()
    Update-CustomPreview $false
}
function Refresh-CustomList($select) {
    $script:LoadingC = $true
    $lstC.BeginUpdate(); $lstC.Items.Clear()
    foreach ($st in $script:Customs) { [void]$lstC.Items.Add((Get-CustomLabel $st), [bool]$st.enabled) }
    $lstC.EndUpdate()
    $script:LoadingC = $false
    if ($select -ge $script:Customs.Count) { $select = $script:Customs.Count - 1 }
    $lstC.SelectedIndex = $select
    Load-CustomEditor
}
function Commit-Custom($problems) { Save-Settings $Settings; Push-CustomToEngine; Update-CustomInfo $problems }

function Play-Game($g) {
    if (-not $g.launch) { return }
    try {
        if ("$($g.launch)" -match '^[a-z.]+://') { Start-Process $g.launch }
        else { Start-Process -FilePath $g.launch -WorkingDirectory (Split-Path $g.launch) }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Couldn't start $($g.name): $($_.Exception.Message)`n`nSome games need to be started as administrator - try running RichPresence as administrator.", 'RichPresence') | Out-Null
        return
    }
    Append-Log ("[{0}] Launching {1}" -f (Get-Date -Format 'HH:mm:ss'), $g.name)
    if ($Settings.exit_when_game_closes) { $Sync.WatchId = $g.id }
    if (-not $script:Job) { Start-Presence }
}

function New-Shortcut($g) {
    try {
        $ws = New-Object -ComObject WScript.Shell
        $safe = ($g.name -replace '[\\/:*?"<>|]', '')
        $s = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) "$safe (RichPresence).lnk"))
        if ($IsExe) { $s.TargetPath = $SelfPath; $s.Arguments = "-Play `"$($g.id)`""; $s.IconLocation = "$($g.icon),0" }
        else { $s.TargetPath = 'powershell.exe'; $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SelfPath`" -Play `"$($g.id)`"" }
        $s.Save()
        [System.Windows.Forms.MessageBox]::Show("Added `"$safe (RichPresence)`" to your desktop.", 'RichPresence') | Out-Null
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'RichPresence') | Out-Null }
}

# ---- tiles
function Get-TileImage($g) {
    try {
        if ($g.art -and (Test-Path $g.art)) {
            $bytes = [IO.File]::ReadAllBytes($g.art)
            $ms = New-Object IO.MemoryStream(, $bytes)
            $src = $null
            # the tile keeps its own copy, so the decoded picture and its stream can go right away
            try { $src = [System.Drawing.Image]::FromStream($ms); return (New-Object System.Drawing.Bitmap($src)) }
            finally { if ($src) { $src.Dispose() }; $ms.Dispose() }
        }
    } catch {}
    $ico = $null; $icoBmp = $null; $gr = $null
    try {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($g.icon)
        $icoBmp = $ico.ToBitmap()
        $bmp = New-Object System.Drawing.Bitmap(210, 100)
        $gr = [System.Drawing.Graphics]::FromImage($bmp)
        $gr.Clear($cCardHi); $gr.InterpolationMode = 'HighQualityBicubic'
        $gr.DrawImage($icoBmp, 73, 18, 64, 64)
        return $bmp
    } catch { return $null }
    finally { foreach ($d in $gr, $icoBmp, $ico) { if ($d) { $d.Dispose() } } }
}

function Add-Tile($g) {
    $tile = New-Ctl System.Windows.Forms.Panel $null @{ Size = (Sz 210 236); BackColor = $cCard; Margin = (New-Object System.Windows.Forms.Padding(0, 0, 14, 14)) }
    $pic = New-Ctl System.Windows.Forms.PictureBox $tile @{ Location = (Pt 0 0); Size = (Sz 210 100); SizeMode = 'Zoom'; BackColor = $cCardHi }
    $img = Get-TileImage $g; if ($img) { $pic.Image = $img }
    $name = New-Ctl System.Windows.Forms.Label $tile @{ Text = $g.name; Font = $fBold; Location = (Pt 10 108); Size = (Sz 190 22); AutoEllipsis = $true }
    $sub = New-Ctl System.Windows.Forms.Label $tile @{ Text = "$($g.store)"; ForeColor = $cDim; Font = $fSmall; Location = (Pt 10 130); Size = (Sz 190 18) }
    $disc = New-Ctl System.Windows.Forms.Label $tile @{ Font = $fSmall; Location = (Pt 10 150); Size = (Sz 190 18) }
    if ($g.discordId) { $disc.Text = 'Official Discord game'; $disc.ForeColor = $cGreen } else { $disc.Text = 'Shows as a generic game'; $disc.ForeColor = $cDim }
    $chk = New-Ctl System.Windows.Forms.CheckBox $tile @{ Text = 'Show on Discord'; Location = (Pt 8 172); AutoSize = $true; ForeColor = $cText }
    $chk.Checked = (@($Settings.disabled_games) -notcontains $g.id)
    $play = New-Ctl System.Windows.Forms.Button $tile @{ Text = 'Play'; Location = (Pt 10 198); Size = (Sz 190 30) }
    Style-Button $play $true
    $chk.Tag = $g; $play.Tag = $g
    $chk.add_CheckedChanged({
        $gg = $this.Tag
        $dis = @($Settings.disabled_games | Where-Object { $_ -ne $gg.id })
        if (-not $this.Checked) { $dis += $gg.id }
        $Settings.disabled_games = $dis; Save-Settings $Settings; Push-GamesToEngine
    })
    $play.add_Click({ Play-Game $this.Tag })

    $cm = New-Object System.Windows.Forms.ContextMenuStrip
    $mi1 = $cm.Items.Add('Create desktop shortcut'); $mi1.Tag = $g; $mi1.add_Click({ New-Shortcut $this.Tag })
    $mi2 = $cm.Items.Add('Open install folder');     $mi2.Tag = $g; $mi2.add_Click({ Start-Process explorer.exe $this.Tag.install })
    if ($g.store -eq 'Added') {
        $mi3 = $cm.Items.Add('Remove from list'); $mi3.Tag = $g
        $mi3.add_Click({
            $gg = $this.Tag
            $Settings.custom_games = @($Settings.custom_games | Where-Object { "custom:$("$($_.exe)".ToLower())" -ne $gg.id })
            Save-Settings $Settings; Start-Scan
        })
    }
    $tile.ContextMenuStrip = $cm; $pic.ContextMenuStrip = $cm
    $flow.Controls.Add($tile)
    $script:Tiles[$g.id] = [pscustomobject]@{ Tile = $tile; Sub = $sub; Game = $g; Pic = $pic; Menu = $cm }
}

# the search box only shows and hides the tiles that are already there
function Filter-Tiles {
    $q = $txtSearch.Text.Trim()
    $flow.SuspendLayout()
    foreach ($t in @($script:Tiles.Values)) { $t.Tile.Visible = (-not $q -or "$($t.Game.name)".IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) }
    $flow.ResumeLayout()
}
# builds every tile again: only needed when the library itself changed
function Rebuild-Tiles {
    $flow.SuspendLayout()
    # a tile's picture and its right-click menu aren't released with the tile itself
    foreach ($t in @($script:Tiles.Values)) {
        $img = $t.Pic.Image; $t.Pic.Image = $null
        if ($img) { $img.Dispose() }
        $t.Menu.Dispose()
    }
    foreach ($c in @($flow.Controls)) { $c.Dispose() }
    $flow.Controls.Clear(); $script:Tiles = @{}
    foreach ($g in $script:Library) { Add-Tile $g }
    Filter-Tiles
    $flow.ResumeLayout()
    $gCount.Text = "$($script:Library.Count) games found"
    $emptyLbl.Visible = ($script:Library.Count -eq 0)
    if ($script:Library.Count -eq 0 -and $script:ScanJob -and $script:ScanJob.Handle.IsCompleted) { $emptyLbl.Text = "No games found. Use '+ Add game', or add folders in Settings." }
}

# ---- tray
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'RichPresence'
try { $tray.Icon = if ($form.Icon) { $form.Icon } else { [System.Drawing.SystemIcons]::Application } } catch { $tray.Icon = [System.Drawing.SystemIcons]::Application }
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Open', $null, { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
[void]$menu.Items.Add('Start / Stop presence', $null, { if ($script:Job) { Stop-Presence } else { Start-Presence } })
[void]$menu.Items.Add('Quit', $null, { $script:reallyQuit = $true; $form.Close() })
$tray.ContextMenuStrip = $menu
$tray.add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })

# ===========================================================================
# OVERLAY - a panel over the game (Ctrl+Alt+G by default): music, volume, games, OBS, lights, Discord.
# It is an ordinary always-on-top window - nothing is put inside the game - so it shows over
# borderless and windowed games, not over true exclusive fullscreen.
# ===========================================================================
$OverlayCode = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

// A keyboard shortcut that works while a game has the keyboard.
public class RPHotkey : NativeWindow, IDisposable {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    public event EventHandler Pressed;
    bool on;
    public RPHotkey() { CreateHandle(new CreateParams()); }
    public bool Set(uint mods, uint vk) {
        if (on) { UnregisterHotKey(Handle, 1); on = false; }
        if (vk != 0) on = RegisterHotKey(Handle, 1, mods | 0x4000, vk);     // 0x4000 = no auto-repeat
        return on;
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Pressed != null) Pressed(this, EventArgs.Empty);
        base.WndProc(ref m);
    }
    public void Dispose() { if (on) UnregisterHotKey(Handle, 1); on = false; DestroyHandle(); }
}

// Media keys: play/pause, next, previous go to whichever player Windows treats as current.
public static class RPKeys {
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    public static void Tap(byte vk) { keybd_event(vk, 0, 1, UIntPtr.Zero); keybd_event(vk, 0, 3, UIntPtr.Zero); }
}

// The logo button on a controller: the Xbox button (read through XInput) and the PS button on a
// DualSense or DualShock 4 (read from the controller's own reports). Works while a game has the keyboard.
public class RPPad : NativeWindow, IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct XState { public uint Packet; public ushort Buttons; public byte LT, RT; public short LX, LY, RX, RY; }
    [DllImport("xinput1_4.dll", EntryPoint = "#100")] static extern int XInputGetStateEx(int index, out XState state);
    [StructLayout(LayoutKind.Sequential)] struct RawDevice { public ushort UsagePage, Usage; public uint Flags; public IntPtr Target; }
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RawDevice[] devs, uint count, uint size);
    [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr input, uint cmd, IntPtr data, ref uint size, uint headerSize);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint GetRawInputDeviceInfo(IntPtr dev, uint cmd, StringBuilder data, ref uint size);

    public event EventHandler Pressed;
    public int Presses;                                     // how many times a logo button went down
    public string Seen = "";                                // the PlayStation controllers that have sent anything
    readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
    readonly bool[] xDown = new bool[4];
    readonly int[] xSkip = new int[4];
    bool xinput = true, on;
    readonly Dictionary<IntPtr, int> kinds = new Dictionary<IntPtr, int>();     // 0 = not ours, 1 = DualSense, 2 = DualShock 4
    readonly Dictionary<IntPtr, bool> psDown = new Dictionary<IntPtr, bool>();

    public RPPad() {
        CreateHandle(new CreateParams());
        timer.Interval = 50;
        timer.Tick += delegate { Poll(); };
    }
    public void Enable(bool want) {
        if (want == on) return;
        on = want;
        // gamepads and joysticks; 0x100 = keep sending while another window is in front, 1 = stop
        RawDevice[] d = new RawDevice[2];
        for (int i = 0; i < 2; i++) { d[i].UsagePage = 1; d[i].Usage = (ushort)(i == 0 ? 5 : 4); d[i].Flags = want ? 0x100u : 1u; d[i].Target = want ? Handle : IntPtr.Zero; }
        RegisterRawInputDevices(d, 2, (uint)Marshal.SizeOf(typeof(RawDevice)));
        if (want) timer.Start(); else timer.Stop();
    }
    void Fire() { Presses++; if (Pressed != null) Pressed(this, EventArgs.Empty); }

    void Poll() {
        if (!xinput) return;
        for (int i = 0; i < 4; i++) {
            if (xSkip[i] > 0) { xSkip[i]--; continue; }     // an empty slot is slow to ask: look again in 2 seconds
            XState s; int r;
            try { r = XInputGetStateEx(i, out s); } catch { xinput = false; return; }
            if (r != 0) { xSkip[i] = 40; xDown[i] = false; continue; }
            bool down = (s.Buttons & 0x0400) != 0;
            if (down && !xDown[i]) Fire();
            xDown[i] = down;
        }
    }

    int Kind(IntPtr dev) {
        int k;
        if (kinds.TryGetValue(dev, out k)) return k;
        k = 0;
        try {
            uint n = 0; GetRawInputDeviceInfo(dev, 0x20000007, null, ref n);
            StringBuilder sb = new StringBuilder((int)n + 2);
            GetRawInputDeviceInfo(dev, 0x20000007, sb, ref n);
            Match m = Regex.Match(sb.ToString(), "054c.{0,4}pid[_&]([0-9a-f]{4})", RegexOptions.IgnoreCase);
            if (m.Success) {
                string pid = m.Groups[1].Value.ToLowerInvariant();
                if (pid == "0ce6" || pid == "0df2") k = 1;
                else if (pid == "05c4" || pid == "09cc" || pid == "0ba0") k = 2;
                if (k != 0) Seen = (Seen + " " + (k == 1 ? "DualSense" : "DualShock 4")).Trim();
            }
        } catch { }
        kinds[dev] = k;
        return k;
    }
    // where the PS button is in a report; -1 = this report doesn't carry it
    public static int PsByte(int kind, int reportId, int size) {
        if (kind == 1) {
            if (reportId == 0x31) return 11;                // Bluetooth, full report
            if (reportId == 0x01) return size >= 64 ? 10 : 7;   // USB : Bluetooth, short report
        } else if (kind == 2) {
            if (reportId == 0x11) return 9;                 // Bluetooth
            if (reportId == 0x01) return 7;                 // USB
        }
        return -1;
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x00FF && on) {
            try {
                uint header = (uint)(8 + 2 * IntPtr.Size), size = 0;
                GetRawInputData(m.LParam, 0x10000003, IntPtr.Zero, ref size, header);
                if (size > header + 8 && size < 4096) {
                    IntPtr buf = Marshal.AllocHGlobal((int)size);
                    try {
                        if (GetRawInputData(m.LParam, 0x10000003, buf, ref size, header) == size && Marshal.ReadInt32(buf) == 2) {
                            IntPtr dev = Marshal.ReadIntPtr(buf, 8);
                            int kind = Kind(dev);
                            int each = Marshal.ReadInt32(buf, (int)header), count = Marshal.ReadInt32(buf, (int)header + 4);
                            if (kind != 0 && each > 0 && count > 0 && header + 8 + each <= size) {
                                int at = (int)header + 8;
                                int idx = PsByte(kind, Marshal.ReadByte(buf, at), each);
                                if (idx >= 0 && idx < each) {
                                    bool down = (Marshal.ReadByte(buf, at + idx) & 1) != 0, was;
                                    psDown.TryGetValue(dev, out was);
                                    if (down && !was) Fire();
                                    psDown[dev] = down;
                                }
                            }
                        }
                    } finally { Marshal.FreeHGlobal(buf); }
                }
            } catch { }
        }
        base.WndProc(ref m);
    }
    public void Dispose() { try { Enable(false); } catch { } timer.Dispose(); DestroyHandle(); }
}

// ------------------------------------------------------------------ volume: the PC's and each app's
public class RPAudioSession { public int Pid; public string Name; public float Volume; public bool Mute; }

public static class RPAudio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int flow, int mask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    }
    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr p);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr p);
        [PreserveSig] int GetChannelCount(out int c);
        [PreserveSig] int SetMasterVolumeLevel(float db, ref Guid ctx);
        [PreserveSig] int SetMasterVolumeLevelScalar(float v, ref Guid ctx);
        [PreserveSig] int GetMasterVolumeLevel(out float db);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float v);
        [PreserveSig] int SetChannelVolumeLevel(uint ch, float db, ref Guid ctx);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint ch, float v, ref Guid ctx);
        [PreserveSig] int GetChannelVolumeLevel(uint ch, out float db);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint ch, out float v);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool m, ref Guid ctx);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool m);
    }
    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2 {
        [PreserveSig] int GetAudioSessionControl(IntPtr a, int b, out IntPtr c);
        [PreserveSig] int GetSimpleAudioVolume(IntPtr a, int b, out IntPtr c);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator e);
    }
    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator {
        [PreserveSig] int GetCount(out int n);
        [PreserveSig] int GetSession(int i, out IAudioSessionControl2 s);
    }
    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2 {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, ref Guid ctx);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, ref Guid ctx);
        [PreserveSig] int GetGroupingParam(out Guid g);
        [PreserveSig] int SetGroupingParam(ref Guid g, ref Guid ctx);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr p);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr p);
        [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetProcessId(out uint pid);
        [PreserveSig] int IsSystemSoundsSession();
        [PreserveSig] int SetDuckingPreference([MarshalAs(UnmanagedType.Bool)] bool optOut);
    }
    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISimpleAudioVolume {
        [PreserveSig] int SetMasterVolume(float v, ref Guid ctx);
        [PreserveSig] int GetMasterVolume(out float v);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool m, ref Guid ctx);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool m);
    }

    static IMMDevice Device() {
        IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
        IMMDevice dev;
        if (en.GetDefaultAudioEndpoint(0, 1, out dev) != 0 || dev == null) throw new InvalidOperationException("No speakers or headphones found.");
        return dev;
    }
    static IAudioEndpointVolume Endpoint() {
        Guid iid = typeof(IAudioEndpointVolume).GUID; object o;
        if (Device().Activate(ref iid, 23, IntPtr.Zero, out o) != 0) throw new InvalidOperationException("Volume isn't available.");
        return (IAudioEndpointVolume)o;
    }
    public static float GetMaster() { float v; Endpoint().GetMasterVolumeLevelScalar(out v); return v; }
    public static void SetMaster(float v) { Guid g = Guid.Empty; Endpoint().SetMasterVolumeLevelScalar(Math.Max(0f, Math.Min(1f, v)), ref g); }
    public static bool GetMasterMute() { bool m; Endpoint().GetMute(out m); return m; }
    public static void SetMasterMute(bool m) { Guid g = Guid.Empty; Endpoint().SetMute(m, ref g); }

    delegate void Each(IAudioSessionControl2 c, ISimpleAudioVolume v, int pid);
    static void Walk(Each fn) {
        Guid iid = typeof(IAudioSessionManager2).GUID; object o;
        if (Device().Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return;
        IAudioSessionEnumerator en;
        if (((IAudioSessionManager2)o).GetSessionEnumerator(out en) != 0 || en == null) return;
        int n; en.GetCount(out n);
        for (int i = 0; i < n; i++) {
            IAudioSessionControl2 c;
            if (en.GetSession(i, out c) != 0 || c == null) continue;
            int state; c.GetState(out state);
            if (state == 2) continue;                       // expired
            uint pid; c.GetProcessId(out pid);
            ISimpleAudioVolume v = c as ISimpleAudioVolume;
            if (v != null) fn(c, v, (int)pid);
        }
    }
    // one entry per app that has made sound; the system sounds come first
    public static RPAudioSession[] Sessions() {
        Dictionary<int, RPAudioSession> byPid = new Dictionary<int, RPAudioSession>();
        List<RPAudioSession> list = new List<RPAudioSession>();
        Walk(delegate(IAudioSessionControl2 c, ISimpleAudioVolume v, int pid) {
            if (byPid.ContainsKey(pid)) return;
            RPAudioSession s = new RPAudioSession();
            s.Pid = pid; v.GetMasterVolume(out s.Volume); v.GetMute(out s.Mute);
            if (pid == 0 || c.IsSystemSoundsSession() == 0) { s.Name = "System sounds"; }
            else {
                try {
                    using (Process p = Process.GetProcessById(pid)) {
                        s.Name = p.ProcessName;
                        try { string d = p.MainModule.FileVersionInfo.FileDescription; if (!string.IsNullOrWhiteSpace(d)) s.Name = d.Trim(); } catch { }
                    }
                } catch { return; }                         // the app has closed
            }
            byPid[pid] = s;
            if (s.Name == "System sounds") list.Insert(0, s); else list.Add(s);
        });
        return list.ToArray();
    }
    public static void SetSession(int pid, float vol) {
        Walk(delegate(IAudioSessionControl2 c, ISimpleAudioVolume v, int p) {
            if (p == pid) { Guid g = Guid.Empty; v.SetMasterVolume(Math.Max(0f, Math.Min(1f, vol)), ref g); }
        });
    }
    public static void SetSessionMute(int pid, bool mute) {
        Walk(delegate(IAudioSessionControl2 c, ISimpleAudioVolume v, int p) {
            if (p == pid) { Guid g = Guid.Empty; v.SetMute(mute, ref g); }
        });
    }
}

// ------------------------------------------------------------------ lights follow the screen (through OpenRGB)
// OpenRGB has to be open with its SDK server running (port 6742). Works on its own thread.
public class RPRgb {
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("gdi32.dll")] static extern bool StretchBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int sw, int sh, uint rop);
    [DllImport("gdi32.dll")] static extern int SetStretchBltMode(IntPtr dc, int mode);

    public volatile string Status = "Off";
    public volatile int Color = 0;              // 0xRRGGBB last sent
    public volatile int Brightness = 100;       // percent
    public volatile int Devices = 0;
    volatile bool stop = true;
    volatile int gen = 0;                       // each Start gets its own number, so an old thread can tell it was replaced
    string host = "127.0.0.1"; int port = 6742;

    public bool Running { get { return !stop; } }
    public void Start(string h, int p) {
        if (!stop) return;
        if (!string.IsNullOrWhiteSpace(h)) host = h.Trim();
        if (p > 0) port = p;
        int g = ++gen;
        stop = false; Status = "Connecting to OpenRGB...";
        Thread t = new Thread(delegate() { Run(g); }); t.IsBackground = true; t.Start();
    }
    public void Stop() { stop = true; Status = "Off"; }
    bool Live(int g) { return !stop && gen == g; }

    static void Send(NetworkStream s, uint dev, uint id, byte[] data) {
        int n = data == null ? 0 : data.Length;
        byte[] b = new byte[16 + n];
        b[0] = (byte)'O'; b[1] = (byte)'R'; b[2] = (byte)'G'; b[3] = (byte)'B';
        BitConverter.GetBytes(dev).CopyTo(b, 4); BitConverter.GetBytes(id).CopyTo(b, 8); BitConverter.GetBytes((uint)n).CopyTo(b, 12);
        if (n > 0) data.CopyTo(b, 16);
        s.Write(b, 0, b.Length);
    }
    static byte[] ReadN(NetworkStream s, int n) {
        byte[] b = new byte[n]; int got = 0;
        while (got < n) { int r = s.Read(b, got, n - got); if (r <= 0) throw new Exception("OpenRGB closed the connection."); got += r; }
        return b;
    }
    // the reply to a request; anything else the server sends on its own in between is skipped
    static byte[] Reply(NetworkStream s, uint want) {
        for (int i = 0; i < 50; i++) {
            byte[] h = ReadN(s, 16);
            uint id = BitConverter.ToUInt32(h, 8); int size = (int)BitConverter.ToUInt32(h, 12);
            if (size < 0 || size > 8000000) throw new Exception("OpenRGB sent something unexpected.");
            byte[] d = ReadN(s, size);
            if (id == want) return d;
        }
        throw new Exception("OpenRGB didn't answer.");
    }
    static void Skip(byte[] d, ref int o) { int n = BitConverter.ToUInt16(d, o); o += 2 + n; }
    // how many lights a device has (device description, protocol version 0)
    public static int CountLeds(byte[] d) {
        int o = 8;                                          // size + device type
        for (int i = 0; i < 5; i++) Skip(d, ref o);         // name, description, version, serial, location
        int modes = BitConverter.ToUInt16(d, o); o += 2 + 4;    // count + active mode
        for (int i = 0; i < modes; i++) {
            Skip(d, ref o); o += 36;
            int nc = BitConverter.ToUInt16(d, o); o += 2 + 4 * nc;
        }
        int zones = BitConverter.ToUInt16(d, o); o += 2;
        int sum = 0;
        for (int i = 0; i < zones; i++) {
            Skip(d, ref o); o += 12;
            sum += (int)BitConverter.ToUInt32(d, o); o += 4;
            int ml = BitConverter.ToUInt16(d, o); o += 2 + ml;
        }
        int leds = BitConverter.ToUInt16(d, o);
        return leds > 0 ? leds : sum;
    }
    // the devices' light counts, without changing anything on them
    public static int[] Probe(string host, int port) {
        using (TcpClient c = new TcpClient()) {
            c.Connect(host, port);
            c.ReceiveTimeout = 4000; c.SendTimeout = 4000;
            return Describe(c.GetStream());
        }
    }
    static int[] Describe(NetworkStream s) {
        Send(s, 0, 50, Encoding.ASCII.GetBytes("RichPresence\0"));
        Send(s, 0, 0, null);
        int count = (int)BitConverter.ToUInt32(Reply(s, 0), 0);
        int[] leds = new int[count];
        for (int i = 0; i < count; i++) {
            Send(s, (uint)i, 1, null);
            try { leds[i] = CountLeds(Reply(s, 1)); } catch (ArgumentException) { leds[i] = 0; } catch (IndexOutOfRangeException) { leds[i] = 0; }
        }
        return leds;
    }

    int ScreenColor(Bitmap bmp) {
        int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
        using (Graphics g = Graphics.FromImage(bmp)) {
            IntPtr dst = g.GetHdc(); IntPtr src = GetDC(IntPtr.Zero);
            try { SetStretchBltMode(dst, 3); StretchBlt(dst, 0, 0, bmp.Width, bmp.Height, src, 0, 0, sw, sh, 0x00CC0020); }
            finally { ReleaseDC(IntPtr.Zero, src); g.ReleaseHdc(dst); }
        }
        long r = 0, gg = 0, b = 0, w = 0;
        for (int y = 0; y < bmp.Height; y++) for (int x = 0; x < bmp.Width; x++) {
            Color c = bmp.GetPixel(x, y);
            int max = Math.Max(c.R, Math.Max(c.G, c.B)), min = Math.Min(c.R, Math.Min(c.G, c.B));
            int wt = 1 + (max - min);                       // colourful pixels count more than grey ones
            r += c.R * wt; gg += c.G * wt; b += c.B * wt; w += wt;
        }
        if (w == 0) return 0;
        return ((int)(r / w) << 16) | ((int)(gg / w) << 8) | (int)(b / w);
    }

    void Run(int g) {
        double cr = 0, cg = 0, cb = 0;
        using (Bitmap bmp = new Bitmap(48, 27)) {
            while (Live(g)) {
                try {
                    using (TcpClient c = new TcpClient()) {
                        c.Connect(host, port);
                        c.ReceiveTimeout = 4000; c.SendTimeout = 4000;
                        NetworkStream s = c.GetStream();
                        int[] leds = Describe(s);
                        for (int i = 0; i < leds.Length; i++) if (leds[i] > 0) Send(s, (uint)i, 1100, null);    // "direct" mode
                        Devices = leds.Length;
                        Status = leds.Length == 0 ? "OpenRGB found no lights" : "Syncing " + leds.Length + (leds.Length == 1 ? " device" : " devices");
                        int last = -1; DateTime sent = DateTime.MinValue;
                        while (Live(g)) {
                            int col = ScreenColor(bmp);
                            double k = Brightness / 100.0;
                            cr += (((col >> 16) & 255) * k - cr) * 0.35; cg += (((col >> 8) & 255) * k - cg) * 0.35; cb += ((col & 255) * k - cb) * 0.35;
                            int now = ((int)cr << 16) | ((int)cg << 8) | (int)cb;
                            if (now != last || (DateTime.UtcNow - sent).TotalSeconds > 2) {
                                for (int i = 0; i < leds.Length; i++) {
                                    int n = leds[i]; if (n <= 0) continue;
                                    byte[] d = new byte[6 + 4 * n];
                                    BitConverter.GetBytes((uint)d.Length).CopyTo(d, 0); BitConverter.GetBytes((ushort)n).CopyTo(d, 4);
                                    for (int j = 0; j < n; j++) { d[6 + 4 * j] = (byte)cr; d[7 + 4 * j] = (byte)cg; d[8 + 4 * j] = (byte)cb; }
                                    Send(s, (uint)i, 1050, d);
                                }
                                last = now; sent = DateTime.UtcNow; Color = now;
                            }
                            while (c.Available > 0) s.ReadByte();   // drop notices the server sends on its own
                            Thread.Sleep(66);
                        }
                    }
                } catch (Exception e) {
                    if (!Live(g)) break;
                    Status = e is SocketException ? "OpenRGB isn't running (or its SDK server is off)" : e.Message;
                    for (int i = 0; i < 30 && Live(g); i++) Thread.Sleep(100);
                }
            }
        }
        if (gen == g) Status = "Off";
    }
}

// ------------------------------------------------------------------ OBS (its built-in WebSocket server, v5)
public class RPObs {
    public volatile bool Connected, Recording, Streaming, Replay;
    public volatile string Status = "Off", Scene = "";
    public volatile string[] Scenes = new string[0];
    volatile bool stop = true;
    Thread thread; int port; string password;
    readonly Queue<string> cmds = new Queue<string>();
    readonly AutoResetEvent wake = new AutoResetEvent(false);
    int nextId;

    public bool Running { get { return !stop; } }
    public void Start(int p, string pass) {
        if (!stop) return;
        port = p > 0 ? p : 4455; password = pass ?? "";
        stop = false; Status = "Looking for OBS...";
        thread = new Thread(Run); thread.IsBackground = true; thread.Start();
    }
    public void Stop() { stop = true; wake.Set(); }
    static string Esc(string s) { return (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\""); }
    // "ToggleRecord", "ToggleStream", "ToggleReplayBuffer", "SaveReplayBuffer"
    public void Do(string request) { lock (cmds) cmds.Enqueue("\"requestType\":\"" + Esc(request) + "\""); wake.Set(); }
    public void SetScene(string name) {
        lock (cmds) cmds.Enqueue("\"requestType\":\"SetCurrentProgramScene\",\"requestData\":{\"sceneName\":\"" + Esc(name) + "\"}");
        wake.Set();
    }

    static void SendText(ClientWebSocket ws, string text) {
        byte[] b = Encoding.UTF8.GetBytes(text);
        if (!ws.SendAsync(new ArraySegment<byte>(b), WebSocketMessageType.Text, true, CancellationToken.None).Wait(4000)) throw new Exception("OBS didn't answer.");
    }
    static string Recv(ClientWebSocket ws) {
        byte[] buf = new byte[16384]; StringBuilder sb = new StringBuilder();
        while (true) {
            var t = ws.ReceiveAsync(new ArraySegment<byte>(buf), CancellationToken.None);
            if (!t.Wait(4000)) throw new Exception("OBS didn't answer.");
            if (t.Result.MessageType == WebSocketMessageType.Close) {
                throw new Exception((int)(ws.CloseStatus ?? 0) == 4009 ? "OBS didn't accept the WebSocket password" : "OBS closed the connection.");
            }
            sb.Append(Encoding.UTF8.GetString(buf, 0, t.Result.Count));
            if (t.Result.EndOfMessage) return sb.ToString();
        }
    }
    static string Str(string json, string key) {
        Match m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
        if (!m.Success) return "";
        try { return Regex.Unescape(m.Groups[1].Value); } catch { return m.Groups[1].Value; }
    }
    static bool Active(string json) { return Regex.IsMatch(json, "\"outputActive\"\\s*:\\s*true"); }
    static string Hash(string s) { using (SHA256 h = SHA256.Create()) return Convert.ToBase64String(h.ComputeHash(Encoding.UTF8.GetBytes(s))); }
    string Ask(ClientWebSocket ws, string body) {
        string id = "rp" + (++nextId);
        SendText(ws, "{\"op\":6,\"d\":{" + body + ",\"requestId\":\"" + id + "\"}}");
        for (int i = 0; i < 20; i++) { string r = Recv(ws); if (r.Contains("\"" + id + "\"")) return r; }
        throw new Exception("OBS didn't answer.");
    }

    void Run() {
        while (!stop) {
            try {
                using (ClientWebSocket ws = new ClientWebSocket()) {
                    if (!ws.ConnectAsync(new Uri("ws://127.0.0.1:" + port), CancellationToken.None).Wait(4000)) throw new Exception("OBS isn't open");
                    string hello = Recv(ws);
                    string auth = "";
                    string challenge = Str(hello, "challenge"), salt = Str(hello, "salt");
                    if (challenge != "") {
                        if (password == "") throw new Exception("OBS wants its WebSocket password");
                        auth = ",\"authentication\":\"" + Hash(Hash(password + salt) + challenge) + "\"";
                    }
                    SendText(ws, "{\"op\":1,\"d\":{\"rpcVersion\":1,\"eventSubscriptions\":0" + auth + "}}");
                    Recv(ws);
                    Connected = true;
                    while (!stop) {
                        while (true) {
                            string cmd = null;
                            lock (cmds) { if (cmds.Count > 0) cmd = cmds.Dequeue(); }
                            if (cmd == null) break;
                            Ask(ws, cmd);
                        }
                        Recording = Active(Ask(ws, "\"requestType\":\"GetRecordStatus\""));
                        Streaming = Active(Ask(ws, "\"requestType\":\"GetStreamStatus\""));
                        Replay = Active(Ask(ws, "\"requestType\":\"GetReplayBufferStatus\""));
                        string sc = Ask(ws, "\"requestType\":\"GetSceneList\"");
                        Scene = Str(sc, "currentProgramSceneName");
                        List<string> names = new List<string>();
                        foreach (Match m in Regex.Matches(sc, "\"sceneName\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"")) {
                            string n; try { n = Regex.Unescape(m.Groups[1].Value); } catch { n = m.Groups[1].Value; }
                            names.Insert(0, n);                     // OBS lists them bottom to top
                        }
                        Scenes = names.ToArray();
                        Status = Recording && Streaming ? "Recording and live" : Recording ? "Recording" : Streaming ? "Live" : "Connected";
                        wake.WaitOne(1000);
                    }
                }
            } catch (Exception e) {
                Exception inner = e; while (inner.InnerException != null) inner = inner.InnerException;
                string msg = inner.Message;
                if (inner is WebSocketException || inner is SocketException) msg = Connected ? "OBS closed" : "OBS isn't open (or its WebSocket server is off)";
                Connected = false; Recording = false; Streaming = false; Replay = false;
                if (stop) break;
                Status = msg;
                lock (cmds) cmds.Clear();
                for (int i = 0; i < 30 && !stop; i++) Thread.Sleep(100);
            }
        }
        Connected = false; Status = "Off";
    }
}
'@

$script:Hotkey = $null; $script:Pad = $null; $script:Rgb = $null; $script:Obs = $null; $script:OvOk = $false
try {
    if (-not ('RPHotkey' -as [type])) { Add-Type -TypeDefinition $OverlayCode -ReferencedAssemblies System.Windows.Forms, System.Drawing }
    $script:Hotkey = New-Object RPHotkey; $script:Pad = New-Object RPPad; $script:Rgb = New-Object RPRgb; $script:Obs = New-Object RPObs
    $script:OvOk = $true
} catch { Append-Log ("[{0}] The overlay couldn't be set up: {1}" -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) }

# "Ctrl+Alt+G" -> what Windows needs to register it; $null when it isn't a usable shortcut
function ConvertTo-Hotkey($text) {
    $mods = 0; $vk = 0
    foreach ($tok in @("$text" -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($tok -match '^(ctrl|control)$') { $mods = $mods -bor 2 }
        elseif ($tok -match '^alt$') { $mods = $mods -bor 1 }
        elseif ($tok -match '^shift$') { $mods = $mods -bor 4 }
        elseif ($tok -match '^win(dows)?$') { $mods = $mods -bor 8 }
        else {
            if ($vk) { return $null }
            $name = if ($tok -match '^\d$') { "D$tok" } else { $tok }
            try { $vk = [int][System.Enum]::Parse([System.Windows.Forms.Keys], $name, $true) } catch { return $null }
        }
    }
    if ($vk -lt 8 -or $vk -gt 254) { return $null }
    if (-not $mods -and ($vk -lt 0x70 -or $vk -gt 0x87)) { return $null }     # a bare key only if it's F1-F24
    @{ Mods = $mods; Vk = $vk }
}
function Set-OverlayHotkey {
    if (-not $script:OvOk) { return }
    $want = if ($Settings.overlay_enabled) { "$($Settings.overlay_hotkey)" } else { '' }
    if ($want -eq $script:HotkeySet) { return }
    $script:HotkeySet = $want
    if (-not $want) { [void]$script:Hotkey.Set(0, 0); return }
    $hk = ConvertTo-Hotkey $want
    if (-not $hk -or -not $script:Hotkey.Set([uint32]$hk.Mods, [uint32]$hk.Vk)) {
        Append-Log ("[{0}] The overlay shortcut {1} couldn't be used (another program has it?). Pick another under Settings." -f (Get-Date -Format 'HH:mm:ss'), $want)
    }
}

# The controller's logo button. Windows gives that button to Xbox Game Bar unless its own switch
# (Settings > Gaming > Game Bar > "open Game Bar using this button") is off; that switch is this registry value.
$GameBarKey = 'HKCU:\Software\Microsoft\GameBar'
function Set-GameBarButton {
    try {
        $now = (Get-ItemProperty -Path $GameBarKey -Name UseNexusForGameBarEnabled -ErrorAction SilentlyContinue).UseNexusForGameBarEnabled
        if ($Settings.overlay_enabled -and $Settings.overlay_controller -and $Settings.gamebar_button_off) {
            if ("$($Settings.gamebar_button_before)" -eq '') { $Settings.gamebar_button_before = $(if ($null -eq $now) { 'unset' } else { "$now" }); Save-Settings $Settings }
            if ($now -ne 0) {
                if (-not (Test-Path $GameBarKey)) { New-Item -Path $GameBarKey -Force | Out-Null }
                Set-ItemProperty -Path $GameBarKey -Name UseNexusForGameBarEnabled -Value 0 -Type DWord
            }
        } elseif ("$($Settings.gamebar_button_before)" -ne '') {
            # put Windows back the way it was
            if ($Settings.gamebar_button_before -eq 'unset') { Remove-ItemProperty -Path $GameBarKey -Name UseNexusForGameBarEnabled -ErrorAction SilentlyContinue }
            else { Set-ItemProperty -Path $GameBarKey -Name UseNexusForGameBarEnabled -Value ([int]$Settings.gamebar_button_before) -Type DWord }
            $Settings.gamebar_button_before = ''; Save-Settings $Settings
        }
    } catch { Append-Log ("[{0}] Couldn't change the Game Bar button setting: {1}" -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) }
}
function Set-OverlayController {
    if (-not $script:OvOk) { return }
    $script:Pad.Enable([bool]($Settings.overlay_enabled -and $Settings.overlay_controller))
    Set-GameBarButton
}

$cKey = C '#010201'
$fOvIcon = New-Object System.Drawing.Font('Segoe MDL2 Assets', 14)
$fOvBig  = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
$fOvLine = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Italic)

$ovDim = New-Object System.Windows.Forms.Form
$ovDim.FormBorderStyle = 'None'; $ovDim.ShowInTaskbar = $false; $ovDim.TopMost = $true; $ovDim.StartPosition = 'Manual'
$ovDim.BackColor = [System.Drawing.Color]::Black; $ovDim.Opacity = 0.6
$ov = New-Object System.Windows.Forms.Form
$ov.FormBorderStyle = 'None'; $ov.ShowInTaskbar = $false; $ov.TopMost = $true; $ov.StartPosition = 'Manual'
$ov.BackColor = $cKey; $ov.TransparencyKey = $cKey; $ov.KeyPreview = $true; $ov.Owner = $ovDim
$ov.Font = $fUi; $ov.ForeColor = $cText; $ov.Text = 'RichPresence overlay'
$ovRoot = New-Ctl System.Windows.Forms.Panel $ov @{ Size = (Sz 1172 700); BackColor = $cKey }

function New-OvWidget($title, $x, $y, $w, $h) {
    $p = New-Ctl System.Windows.Forms.Panel $ovRoot @{ Location = (Pt $x $y); Size = (Sz $w $h); BackColor = $cCard }
    [void](New-Ctl System.Windows.Forms.Label $p @{ Text = $title; UseMnemonic = $false; Font = $fBold; ForeColor = $cDim; Location = (Pt 12 8); AutoSize = $true })
    $p
}
function New-OvButton($parent, $text, $x, $y, $w, $h) {
    $b = New-Ctl System.Windows.Forms.Button $parent @{ Text = $text; UseMnemonic = $false; Location = (Pt $x $y); Size = (Sz $w $h) }
    Style-Button $b $false; $b.Font = $fUi
    $b
}

# ---- top bar
$ovTop = New-Ctl System.Windows.Forms.Panel $ovRoot @{ Location = (Pt 0 0); Size = (Sz 1172 44); BackColor = $cSide }
[void](New-Ctl System.Windows.Forms.Label $ovTop @{ Text = 'RichPresence'; Font = $fOvBig; Location = (Pt 12 9); AutoSize = $true })
$ovHint  = New-Ctl System.Windows.Forms.Label $ovTop @{ Text = ''; ForeColor = $cDim; Location = (Pt 150 14); Size = (Sz 600 20) }
$ovClock = New-Ctl System.Windows.Forms.Label $ovTop @{ Text = ''; Font = $fOvBig; TextAlign = 'MiddleRight'; Location = (Pt 960 8); Size = (Sz 150 28) }
$ovClose = New-OvButton $ovTop ([string][char]0xE711) 1122 6 40 32
$ovClose.Font = $fOvIcon

# ---- music
$ovMedia = New-OvWidget 'Music' 0 56 380 190
$ovSong   = New-Ctl System.Windows.Forms.Label $ovMedia @{ Text = ''; UseMnemonic = $false; Font = $fOvBig; Location = (Pt 12 34); Size = (Sz 356 26); AutoEllipsis = $true }
$ovArtist = New-Ctl System.Windows.Forms.Label $ovMedia @{ Text = ''; UseMnemonic = $false; ForeColor = $cDim; Location = (Pt 13 62); Size = (Sz 356 20); AutoEllipsis = $true }
$ovLine   = New-Ctl System.Windows.Forms.Label $ovMedia @{ Text = ''; UseMnemonic = $false; Font = $fOvLine; ForeColor = $cAccent; Location = (Pt 13 86); Size = (Sz 356 42) }
$ovPrev = New-OvButton $ovMedia ([string][char]0xE892) 12 138 112 40
$ovPlay = New-OvButton $ovMedia ([string][char]0xE768) 134 138 112 40
$ovNext = New-OvButton $ovMedia ([string][char]0xE893) 256 138 112 40
foreach ($b in $ovPrev, $ovPlay, $ovNext) { $b.Font = $fOvIcon }
$ovPrev.Tag = 0xB1; $ovPlay.Tag = 0xB3; $ovNext.Tag = 0xB0
foreach ($b in $ovPrev, $ovPlay, $ovNext) { $b.add_Click({ try { [RPKeys]::Tap([byte]$this.Tag) } catch {} }) }

# ---- Discord
$ovDiscord = New-OvWidget 'Discord' 0 258 380 250
$ovDStatus = New-Ctl System.Windows.Forms.Label $ovDiscord @{ Text = ''; UseMnemonic = $false; Location = (Pt 13 34); Size = (Sz 356 36) }
$ovDToggle = New-OvButton $ovDiscord 'Start presence' 12 74 172 34
$ovDOpen   = New-OvButton $ovDiscord 'Open Discord' 196 74 172 34
[void](New-Ctl System.Windows.Forms.Label $ovDiscord @{ Text = 'Custom statuses'; ForeColor = $cDim; Location = (Pt 13 118); AutoSize = $true })
$ovDList = New-Ctl System.Windows.Forms.CheckedListBox $ovDiscord @{ Location = (Pt 13 140); Size = (Sz 355 100); BackColor = $cCardHi; ForeColor = $cText; BorderStyle = 'None'; CheckOnClick = $true; IntegralHeight = $false }
$ovDToggle.add_Click({ if ($script:Job) { Stop-Presence } else { Start-Presence } })
$ovDOpen.add_Click({ Hide-Overlay; try { Start-Process 'discord://-/channels/@me' } catch {} })
$ovDList.add_ItemCheck({
    param($s, $e)
    if ($script:OvLoading) { return }
    # the Custom status page owns the list: ticking its box there saves and sends it
    if ($e.Index -lt $lstC.Items.Count) { $lstC.SetItemChecked($e.Index, ($e.NewValue -eq 'Checked')) }
})

# ---- Steam, Xbox, PlayStation
$ovStores = New-OvWidget 'Steam, Xbox & PlayStation' 0 520 380 180
$storeRows = @(
    @('Steam', @(@('Library', 'steam://open/games'), @('Big Picture', 'steam://open/bigpicture'), @('Friends', 'steam://open/friends'))),
    @('Xbox', @(@('Xbox app', 'shell:AppsFolder\Microsoft.GamingApp_8wekyb3d8bbwe!Microsoft.Xbox.App'), @('Cloud', 'https://www.xbox.com/play'), @('Profile', 'https://account.xbox.com/Profile'))),
    @('PlayStation', @(@('Remote Play', 'psremoteplay'), @('Library', 'https://library.playstation.com/'), @('Store', 'https://store.playstation.com/')))
)
$sy = 38
foreach ($row in $storeRows) {
    [void](New-Ctl System.Windows.Forms.Label $ovStores @{ Text = $row[0]; ForeColor = $cDim; Location = (Pt 13 ($sy + 8)); Size = (Sz 76 20) })
    $sx = 92
    foreach ($item in $row[1]) {
        $b = New-OvButton $ovStores $item[0] $sx $sy 90 34
        $b.Tag = $item[1]; $sx += 94
        $b.add_Click({
            Hide-Overlay
            try {
                $t = "$($this.Tag)"
                if ($t -eq 'psremoteplay') {
                    $exe = Join-Path ${env:ProgramFiles(x86)} 'Sony\PS Remote Play\RemotePlay.exe'
                    if (Test-Path $exe) { Start-Process $exe } else { Start-Process 'https://remoteplay.dl.playstation.net/remoteplay/' }
                }
                elseif ($t -like 'shell:*') { Start-Process 'explorer.exe' $t }
                else { Start-Process $t }
            } catch { Append-Log ("[{0}] Couldn't open that: {1}" -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) }
        })
    }
    $sy += 44
}

# ---- volume
$ovAudio = New-OvWidget 'Volume' 396 56 380 330
function New-OvVolRow($parent, $name, $y, $procId) {
    $lbl = New-Ctl System.Windows.Forms.Label $parent @{ Text = $name; UseMnemonic = $false; Location = (Pt 0 ($y + 6)); Size = (Sz 116 20); AutoEllipsis = $true }
    $bar = New-Ctl System.Windows.Forms.TrackBar $parent @{ AutoSize = $false; Location = (Pt 116 $y); Size = (Sz 176 30); Maximum = 100; TickStyle = 'None'; BackColor = $cCard; Tag = $procId }
    $mute = New-Ctl System.Windows.Forms.CheckBox $parent @{ Text = 'Mute'; Location = (Pt 296 ($y + 4)); AutoSize = $true; ForeColor = $cDim; Tag = $procId }
    $bar.add_Scroll({
        try { if ([int]$this.Tag -lt 0) { [RPAudio]::SetMaster($this.Value / 100) } else { [RPAudio]::SetSession([int]$this.Tag, $this.Value / 100) } } catch {}
    })
    $mute.add_Click({
        try { if ([int]$this.Tag -lt 0) { [RPAudio]::SetMasterMute($this.Checked) } else { [RPAudio]::SetSessionMute([int]$this.Tag, $this.Checked) } } catch {}
    })
    @{ Label = $lbl; Bar = $bar; Mute = $mute }
}
$ovMasterBox = New-Ctl System.Windows.Forms.Panel $ovAudio @{ Location = (Pt 13 36); Size = (Sz 356 34) }
$ovMaster = New-OvVolRow $ovMasterBox 'Everything' 0 -1
$ovMaster.Label.Font = $fBold
$ovMix = New-Ctl System.Windows.Forms.Panel $ovAudio @{ Location = (Pt 13 80); Size = (Sz 356 240) }
$script:OvMixKey = $null; $script:OvMixRows = @()
function Update-OvAudio {
    if (-not $script:OvOk) { return }
    try {
        if (-not $ovMaster.Bar.Capture) { $ovMaster.Bar.Value = [int][math]::Round([RPAudio]::GetMaster() * 100) }
        $ovMaster.Mute.Checked = [RPAudio]::GetMasterMute()
        $list = @([RPAudio]::Sessions() | Select-Object -First 7)
        $key = @($list | ForEach-Object { $_.Pid }) -join ','
        if ($key -ne $script:OvMixKey) {
            $script:OvMixKey = $key
            foreach ($c in @($ovMix.Controls)) { $c.Dispose() }
            $script:OvMixRows = @(); $y = 0
            foreach ($s in $list) { $script:OvMixRows += (New-OvVolRow $ovMix $s.Name $y $s.Pid); $y += 34 }
        }
        for ($i = 0; $i -lt $list.Count -and $i -lt $script:OvMixRows.Count; $i++) {
            $r = $script:OvMixRows[$i]
            if (-not $r.Bar.Capture) { $r.Bar.Value = [int][math]::Round($list[$i].Volume * 100) }
            $r.Mute.Checked = [bool]$list[$i].Mute
        }
    } catch {}
}

# ---- OBS
$ovObs = New-OvWidget 'OBS' 396 398 380 170
$ovObsStatus = New-Ctl System.Windows.Forms.Label $ovObs @{ Text = ''; UseMnemonic = $false; Location = (Pt 13 34); Size = (Sz 356 20) }
$ovObsRec    = New-OvButton $ovObs 'Start recording' 12 60 114 36
$ovObsLive   = New-OvButton $ovObs 'Go live' 132 60 114 36
$ovObsReplay = New-OvButton $ovObs 'Save replay' 252 60 116 36
[void](New-Ctl System.Windows.Forms.Label $ovObs @{ Text = 'Scene'; ForeColor = $cDim; Location = (Pt 13 114); AutoSize = $true })
$ovObsScene = New-Ctl System.Windows.Forms.ComboBox $ovObs @{ DropDownStyle = 'DropDownList'; FlatStyle = 'Flat'; Location = (Pt 64 110); Size = (Sz 304 24); BackColor = $cCardHi; ForeColor = $cText }
[void](New-Ctl System.Windows.Forms.Label $ovObs @{ Text = 'In OBS: Tools > WebSocket Server Settings > Enable.'; ForeColor = $cDim; Font = $fSmall; Location = (Pt 13 144); AutoSize = $true })
$ovObsRec.add_Click({ if ($script:OvOk) { $script:Obs.Do('ToggleRecord') } })
$ovObsLive.add_Click({ if ($script:OvOk) { $script:Obs.Do('ToggleStream') } })
$ovObsReplay.add_Click({ if ($script:OvOk) { $script:Obs.Do($(if ($script:Obs.Replay) { 'SaveReplayBuffer' } else { 'ToggleReplayBuffer' })) } })
$ovObsScene.add_SelectionChangeCommitted({ if ($script:OvOk -and $ovObsScene.SelectedItem) { $script:Obs.SetScene("$($ovObsScene.SelectedItem)") } })
# OBS keeps its own port and password in its settings folder on this PC; they are read from there, never stored here
function Start-OvObs {
    if (-not $script:OvOk -or $script:Obs.Running) { return }
    $port = 4455; $pass = ''
    try {
        $cfg = Get-Content (Join-Path $env:APPDATA 'obs-studio\plugin_config\obs-websocket\config.json') -Raw | ConvertFrom-Json
        if ($cfg.server_port) { $port = [int]$cfg.server_port }
        if ($cfg.auth_required) { $pass = "$($cfg.server_password)" }
    } catch {}
    $script:Obs.Start($port, $pass)
}

# ---- lights
$ovRgb = New-OvWidget 'Lights' 396 580 380 120
$ovRgbOn = New-Ctl System.Windows.Forms.CheckBox $ovRgb @{ Text = 'Match my lights to the screen'; Location = (Pt 13 34); AutoSize = $true }
$ovRgbSwatch = New-Ctl System.Windows.Forms.Panel $ovRgb @{ Location = (Pt 332 32); Size = (Sz 36 22); BackColor = $cCardHi }
[void](New-Ctl System.Windows.Forms.Label $ovRgb @{ Text = 'Brightness'; ForeColor = $cDim; Location = (Pt 13 66); AutoSize = $true })
$ovRgbBright = New-Ctl System.Windows.Forms.TrackBar $ovRgb @{ AutoSize = $false; Location = (Pt 90 60); Size = (Sz 278 30); Minimum = 10; Maximum = 100; TickStyle = 'None'; BackColor = $cCard }
$ovRgbStatus = New-Ctl System.Windows.Forms.Label $ovRgb @{ Text = ''; UseMnemonic = $false; ForeColor = $cDim; Font = $fSmall; Location = (Pt 13 94); Size = (Sz 356 18) }
function Set-RgbSync($on) {
    if (-not $script:OvOk) { return }
    $script:Rgb.Brightness = [int]$Settings.rgb_brightness
    if ($on) { $script:Rgb.Start('127.0.0.1', 6742) } else { $script:Rgb.Stop() }
}
$ovRgbOn.add_Click({ $Settings.rgb_sync = $ovRgbOn.Checked; Save-Settings $Settings; Set-RgbSync $ovRgbOn.Checked })
$ovRgbBright.add_Scroll({ $Settings.rgb_brightness = $ovRgbBright.Value; if ($script:OvOk) { $script:Rgb.Brightness = $ovRgbBright.Value } })
$ovRgbBright.add_MouseUp({ Save-Settings $Settings })

# ---- games
$ovGames = New-OvWidget 'Games' 792 56 380 644
$ovSearch = New-Ctl System.Windows.Forms.TextBox $ovGames @{ Location = (Pt 13 36); Size = (Sz 354 24); BackColor = $cCardHi; ForeColor = $cText; BorderStyle = 'FixedSingle' }
$ovGameList = New-Ctl System.Windows.Forms.FlowLayoutPanel $ovGames @{ Location = (Pt 13 68); Size = (Sz 360 566); AutoScroll = $true; FlowDirection = 'TopDown'; WrapContents = $false }
$script:OvGameKey = $null; $script:OvGameRows = @()
function Update-OvGames {
    $key = @($script:Library | ForEach-Object { $_.id }) -join '|'
    if ($key -ne $script:OvGameKey) {
        $script:OvGameKey = $key
        $ovGameList.SuspendLayout()
        foreach ($r in $script:OvGameRows) { if ($r.Pic.Image) { $r.Pic.Image.Dispose() }; $r.Row.Dispose() }
        $script:OvGameRows = @()
        foreach ($g in $script:Library) {
            $row = New-Ctl System.Windows.Forms.Panel $ovGameList @{ Size = (Sz 336 46); BackColor = $cCardHi; Cursor = 'Hand'; Tag = $g; Margin = (New-Object System.Windows.Forms.Padding(0, 0, 0, 6)) }
            $pic = New-Ctl System.Windows.Forms.PictureBox $row @{ Location = (Pt 7 7); Size = (Sz 32 32); SizeMode = 'Zoom'; Tag = $g }
            $ico = $null
            try { $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($g.icon); $pic.Image = $ico.ToBitmap() } catch {} finally { if ($ico) { $ico.Dispose() } }
            $nm  = New-Ctl System.Windows.Forms.Label $row @{ Text = $g.name; UseMnemonic = $false; Font = $fBold; Location = (Pt 48 4); Size = (Sz 280 20); AutoEllipsis = $true; Tag = $g }
            $sub = New-Ctl System.Windows.Forms.Label $row @{ Text = "$($g.store)"; ForeColor = $cDim; Font = $fSmall; Location = (Pt 49 25); Size = (Sz 280 16); Tag = $g }
            foreach ($c in $row, $pic, $nm, $sub) { $c.add_Click({ $game = $this.Tag; Hide-Overlay; Play-Game $game }) }
            $script:OvGameRows += @{ Row = $row; Pic = $pic; Sub = $sub; Game = $g }
        }
        $ovGameList.ResumeLayout()
    }
    $find = $ovSearch.Text.Trim()
    foreach ($r in $script:OvGameRows) {
        $isRun = @($Sync.RunningIds) -contains $r.Game.id
        $r.Row.BackColor = $(if ($isRun) { C '#243a2e' } else { $cCardHi })
        $r.Sub.Text = $(if ($isRun) { "$($r.Game.store)  -  Running" } else { "$($r.Game.store)" })
        $r.Row.Visible = (-not $find) -or ("$($r.Game.name)".IndexOf($find, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
}
$ovSearch.add_TextChanged({ Update-OvGames })

# ---- show, hide, refresh
$script:OvTick = 0; $script:OvLoading = $false
$ovTimer = New-Object System.Windows.Forms.Timer
$ovTimer.Interval = 500
function Update-Overlay {
    $ovClock.Text = (Get-Date).ToString('t')
    $now = $Sync.Now
    if ($script:Job -and $now -and $now.Title) {
        $ovSong.Text = "$($now.Title)"
        $ovArtist.Text = $(if ($now.Artist) { "$($now.Artist)  -  $($now.Player)" } else { "$($now.Player)" })
        $ovLine.Text = "$($now.Line)"
        $ovPlay.Text = [string][char]$(if ($now.Playing) { 0xE769 } else { 0xE768 })
    } else {
        $ovSong.Text = 'Nothing playing'
        $ovArtist.Text = $(if ($script:Job) { 'Apple Music and Spotify show here with their lyrics.' } else { 'Start the presence to see the song and lyrics.' })
        $ovLine.Text = ''; $ovPlay.Text = [string][char]0xE768
    }
    $ovDStatus.Text = $(if ($script:Job) { "Presence on: $($Sync.Status)" } else { 'Presence off' })
    $ovDStatus.ForeColor = $(if ($script:Job) { $cGreen } else { $cDim })
    $ovDToggle.Text = $(if ($script:Job) { 'Stop presence' } else { 'Start presence' })
    if ($script:OvOk) {
        $o = $script:Obs
        $ovObsStatus.Text = "$($o.Status)"
        $ovObsStatus.ForeColor = $(if ($o.Recording -or $o.Streaming) { C '#ed4245' } elseif ($o.Connected) { $cGreen } else { $cDim })
        foreach ($b in $ovObsRec, $ovObsLive, $ovObsReplay) { $b.Enabled = [bool]$o.Connected }
        $ovObsScene.Enabled = [bool]$o.Connected
        $ovObsRec.Text = $(if ($o.Recording) { 'Stop recording' } else { 'Start recording' })
        $ovObsLive.Text = $(if ($o.Streaming) { 'End stream' } else { 'Go live' })
        $ovObsReplay.Text = $(if ($o.Replay) { 'Save replay' } else { 'Start replay' })
        if (-not $ovObsScene.DroppedDown) {
            $names = @($o.Scenes)
            if (($names -join "`n") -ne (@($ovObsScene.Items) -join "`n")) { $ovObsScene.Items.Clear(); foreach ($n in $names) { [void]$ovObsScene.Items.Add($n) } }
            if ("$($ovObsScene.SelectedItem)" -ne "$($o.Scene)") { $ovObsScene.SelectedItem = "$($o.Scene)" }
        }
        $ovRgbStatus.Text = $(if ($script:Rgb.Running) { "$($script:Rgb.Status)" } else { 'Needs OpenRGB open with its SDK server running.' })
        $col = [int]$script:Rgb.Color
        $ovRgbSwatch.BackColor = $(if ($script:Rgb.Running) { [System.Drawing.Color]::FromArgb(255, ($col -shr 16) -band 255, ($col -shr 8) -band 255, $col -band 255) } else { $cCardHi })
    }
    if ($script:OvTick % 4 -eq 0) { Update-OvAudio; Update-OvGames }
    $script:OvTick++
}
$ovTimer.add_Tick({ try { Update-Overlay } catch {} })
function Show-Overlay {
    if ($ov.Visible) { return }
    $b = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).Bounds
    $ovDim.Bounds = $b; $ov.Bounds = $b
    $ovRoot.Location = Pt ([math]::Max(0, [int](($b.Width - $ovRoot.Width) / 2))) ([math]::Max(0, [int](($b.Height - $ovRoot.Height) / 2)))
    $ovHint.Text = "$($Settings.overlay_hotkey)$(if ($Settings.overlay_controller) { ', the controller''s logo button' }) or Esc to close"
    $ovSearch.Text = ''
    # the custom statuses, as the Custom status page has them
    $script:OvLoading = $true
    $ovDList.Items.Clear()
    for ($i = 0; $i -lt $lstC.Items.Count; $i++) { [void]$ovDList.Items.Add("$($lstC.Items[$i])", $lstC.GetItemChecked($i)) }
    $script:OvLoading = $false
    $ovRgbOn.Checked = [bool]$Settings.rgb_sync
    $ovRgbBright.Value = [math]::Max(10, [math]::Min(100, [int]$Settings.rgb_brightness))
    Start-OvObs
    $script:OvTick = 0
    try { Update-Overlay } catch {}
    $ovDim.Show(); $ov.Show(); $ov.Activate()
    $ovTimer.Start()
}
function Hide-Overlay {
    if (-not $ov.Visible) { return }
    $ovTimer.Stop()
    $ov.Hide(); $ovDim.Hide()
}
function Switch-Overlay { if ($ov.Visible) { Hide-Overlay } else { Show-Overlay } }
$ovClose.add_Click({ Hide-Overlay })
$ovDim.add_MouseDown({ Hide-Overlay })
$ov.add_MouseDown({ Hide-Overlay })
$ovRoot.add_MouseDown({ Hide-Overlay })
$ov.add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $e.Handled = $true; $e.SuppressKeyPress = $true; Hide-Overlay } })
# closing either window some other way (Alt+F4) only hides it
foreach ($f in $ov, $ovDim) { $f.add_FormClosing({ param($s, $e) if (-not $script:reallyQuit -and $e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; Hide-Overlay } }) }
if ($script:OvOk) {
    $script:Hotkey.add_Pressed({ try { Switch-Overlay } catch {} })
    $script:Pad.add_Pressed({ try { Switch-Overlay } catch {} })
    Set-OverlayHotkey
    Set-OverlayController
    if ($Settings.rgb_sync) { Set-RgbSync $true }
}
$miOverlay = New-Object System.Windows.Forms.ToolStripMenuItem('Overlay')
$miOverlay.add_Click({ Show-Overlay })
$menu.Items.Insert(1, $miOverlay)

# ---- events
$btnToggle.add_Click({ if ($script:Job) { Stop-Presence } else { Start-Presence } })
$btnRescan.add_Click({ Read-FromUi; Start-Scan })
$btnMusicSave.add_Click({ Read-FromUi; if ($script:Job) { Stop-Presence; Start-Presence } })
$btnSave.add_Click({ Read-FromUi; if ($script:Job) { Stop-Presence; Start-Presence }; Start-Scan; Show-Page 'Games' })
$btnFolder.add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Pick a folder that contains your games (each sub-folder is one game)'
    if ($d.ShowDialog() -eq 'OK') { $txtFolders.AppendText($(if ($txtFolders.TextLength) { [Environment]::NewLine } else { '' }) + $d.SelectedPath) }
})
$btnAdd.add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Game (*.exe)|*.exe'; $d.Title = 'Pick the game''s .exe'
    if ($d.ShowDialog() -eq 'OK') {
        $fi = Get-Item $d.FileName
        $nm = $fi.VersionInfo.ProductName; if (-not $nm) { $nm = $fi.BaseName }
        $Settings.custom_games = @($Settings.custom_games) + @(@{ name = $nm; exe = $fi.FullName })
        Save-Settings $Settings; Start-Scan
    }
})
$txtSearch.add_TextChanged({ Filter-Tiles })

# custom status page
$lstC.add_SelectedIndexChanged({ if (-not $script:LoadingC -and $lstC.SelectedIndex -ne $script:CurC) { Load-CustomEditor } })
$lstC.add_ItemCheck({
    param($s, $e)
    if ($script:LoadingC) { return }
    $on = ($e.NewValue -eq 'Checked')
    $script:Customs[$e.Index].enabled = $on
    if ($e.Index -eq $script:CurC) { $script:LoadingC = $true; $chkCOn.Checked = $on; $script:LoadingC = $false }
    Commit-Custom $null
})
$chkCOn.add_CheckedChanged({ if (-not $script:LoadingC -and $script:CurC -ge 0) { $lstC.SetItemChecked($script:CurC, $chkCOn.Checked) } })
foreach ($tb in $txtCName, $txtCDetails, $txtCState, $txtCLarge, $txtCLargeT, $txtCSmall, $txtCSmallT, $txtCB1L, $txtCB1U, $txtCB2L, $txtCB2U, $txtCAppId) {
    $tb.add_TextChanged({ Save-CustomEditor })
}
$cmbCType.add_SelectedIndexChanged({ Save-CustomEditor })
$chkCElapsed.add_CheckedChanged({ Save-CustomEditor })
$txtCLarge.add_Leave({ Set-PreviewImage $picCLarge $txtCLarge.Text })
$txtCSmall.add_Leave({ Set-PreviewImage $picCSmall $txtCSmall.Text })
$lnkCApp.add_Click({ Start-Process 'https://discord.com/developers/applications' })
$btnCNew.add_Click({
    [void]$script:Customs.Add((New-CustomStatus $null $false))
    Refresh-CustomList ($script:Customs.Count - 1); Commit-Custom $null
    $txtCName.Focus() | Out-Null
})
$btnCCopy.add_Click({
    if ($script:CurC -lt 0) { return }
    $copy = New-CustomStatus $script:Customs[$script:CurC] $false
    $copy.enabled = $false; $copy.name = (Get-CustomLabel $copy) + ' (copy)'
    $script:Customs.Insert($script:CurC + 1, $copy)
    Refresh-CustomList ($script:CurC + 1); Commit-Custom $null
})
$btnCDel.add_Click({
    $i = $script:CurC
    if ($i -lt 0) { return }
    if ([System.Windows.Forms.MessageBox]::Show("Delete `"$(Get-CustomLabel $script:Customs[$i])`"?", 'RichPresence', 'YesNo') -ne 'Yes') { return }
    $script:Customs.RemoveAt($i)
    Refresh-CustomList $i; Commit-Custom $null
})
foreach ($b in $btnCUp, $btnCDown) {
    $b.Tag = $(if ($b -eq $btnCUp) { -1 } else { 1 })
    $b.add_Click({
        $i = $script:CurC; $j = $i + [int]$this.Tag
        if ($i -lt 0 -or $j -lt 0 -or $j -ge $script:Customs.Count) { return }
        $st = $script:Customs[$i]; $script:Customs.RemoveAt($i); $script:Customs.Insert($j, $st)
        Refresh-CustomList $j; Commit-Custom $null
    })
}
foreach ($r in $rdoCSep, $rdoCMerge) {
    $r.add_CheckedChanged({
        if ($script:LoadingC -or -not $this.Checked) { return }
        $Settings.custom_mode = $(if ($rdoCMerge.Checked) { 'merge' } else { 'separate' })
        Commit-Custom $null
    })
}
$btnCSave.add_Click({
    Save-CustomEditor
    $problems = @()
    if ($script:CurC -ge 0) { $problems = Test-CustomStatus $script:Customs[$script:CurC] }
    Refresh-CustomList $script:CurC
    if (-not $script:Job -and @($script:Customs | Where-Object { $_.enabled }).Count) { Start-Presence }
    Commit-Custom $problems
})
$chkWin.add_CheckedChanged({ try { Set-StartupShortcut $chkWin.Checked } catch {} })
$linkGuide.add_Click({ Start-Process $RepoUrl })

# ---- updates
$script:UpdateJob = $null
$script:NextUpdateCheck = [datetime]::MaxValue
function Start-UpdateCheck {
    if ($script:UpdateJob -and -not $script:UpdateJob.Handle.IsCompleted) { return }
    if ($script:UpdateJob) { Stop-Block $script:UpdateJob $null 0 }
    $Sync.UpdateState = 'checking'
    $updateLbl.Text = "Version $AppVersion - checking for updates..."
    $script:UpdateJob = Start-Block $Updater @($Sync, $AppVersion, $DataDir)
    $script:NextUpdateCheck = (Get-Date).AddHours(6)
}
# "Never while a game is running": the engine reports the running games, but it may be off or only just
# started, so look at the processes here too (at most every 5 seconds).
$script:GameCheckAt = [datetime]::MinValue; $script:GameCheckHit = $false
function Test-GameRunning {
    if (@($Sync.RunningIds).Count) { return $true }
    if (((Get-Date) - $script:GameCheckAt).TotalSeconds -lt 5) { return $script:GameCheckHit }
    $hit = $false
    try {
        $names = @{}
        foreach ($p in Get-Process) { $names[$p.ProcessName.ToLower()] = $true }
        foreach ($g in $script:Library) { foreach ($e in @($g.exes)) { if ($names.ContainsKey("$e")) { $hit = $true } } }
    } catch {}
    $script:GameCheckAt = Get-Date; $script:GameCheckHit = $hit
    $hit
}
# a version the helper couldn't copy into place (it notes it in update\failed.txt) isn't installed by
# itself again; "Restart to update" still tries.
$script:UpdateSkip = @{}
function Test-UpdateFailed($ver) {
    if (-not $script:UpdateSkip.ContainsKey("$ver")) {
        $bad = $false
        try {
            $f = Join-Path $DataDir 'update\failed.txt'
            if (Test-Path -LiteralPath $f) { $bad = (@(Get-Content -LiteralPath $f | ForEach-Object { "$_".Trim() }) -contains "$ver") }
        } catch {}
        if ($bad) { Append-Log ("[{0}] Update {1} couldn't be installed last time, so it won't install by itself. Use 'Restart to update' to try again." -f (Get-Date -Format 'HH:mm:ss'), $ver) }
        $script:UpdateSkip["$ver"] = $bad
    }
    $script:UpdateSkip["$ver"]
}
# The running EXE can't overwrite itself: a tiny helper waits for this process to exit,
# swaps the file in, and starts the new version.
function Install-Update {
    $new = $Sync.UpdateFile
    if (-not $new -or -not (Test-Path $new)) { return }
    if (-not $IsExe) { $updateLbl.Text = "Version $($Sync.LatestVersion) is available on GitHub (running as a script, so update by hand)."; return }
    # the file was checked when it was downloaded; check it again now, in case it was changed since
    $ok = $false
    try { $ok = [bool]("$($Sync.UpdateHash)" -and (Get-FileHash -LiteralPath $new -Algorithm SHA256).Hash.ToLower() -eq "$($Sync.UpdateHash)") } catch {}
    if (-not $ok) {
        try { Remove-Item -LiteralPath $new -Force } catch {}
        $Sync.UpdateFile = $null; $Sync.UpdateState = 'failed'
        Append-Log ("[{0}] Update {1} no longer matched its checksum and was deleted." -f (Get-Date -Format 'HH:mm:ss'), $Sync.LatestVersion)
        return
    }
    $helper = Join-Path (Split-Path $new) 'apply-update.cmd'
    $failed = Join-Path (Split-Path $new) 'failed.txt'
    $ver = "$($Sync.LatestVersion)" -replace '[^\d.]', ''
    # if the copy fails the helper notes the version in failed.txt, so it isn't tried again by itself, and reopens the old one
    $cmd = @"
@echo off
:wait
tasklist /FI "PID eq $PID" 2>nul | find "$PID" >nul && (ping -n 2 127.0.0.1 >nul & goto wait)
copy /y "$new" "$SelfPath" >nul
if errorlevel 1 (
  >"$failed" echo $ver
  goto done
)
del "$new" >nul 2>&1
:done
start "" "$SelfPath"
"@
    # cmd.exe reads a .cmd in the PC's OEM code page, so a path with accented letters has to be written in it
    $oem = [Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
    try { $oem = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -ErrorAction Stop).OEMCP } catch {}
    $enc = if ($oem -eq 65001) { New-Object System.Text.UTF8Encoding($false) } else { [Text.Encoding]::GetEncoding($oem) }
    [IO.File]::WriteAllText($helper, ($cmd -replace "`r?`n", "`r`n"), $enc)
    Append-Log ("[{0}] Installing update {1} and restarting..." -f (Get-Date -Format 'HH:mm:ss'), $Sync.LatestVersion)
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$helper`"" -WindowStyle Hidden
    $script:reallyQuit = $true
    $form.Close()
}
$btnUpdate.add_Click({
    if ($Sync.UpdateState -eq 'ready') { Install-Update } else { Start-UpdateCheck }
})
$form.add_FormClosing({
    param($s, $e)
    if ($Settings.close_to_tray -and -not $script:reallyQuit -and $e.CloseReason -eq 'UserClosing') {
        $e.Cancel = $true; Read-FromUi; $form.Hide()
        $tray.ShowBalloonTip(2000, 'RichPresence', 'Still running in the tray.', 'Info')
        return
    }
    try { Read-FromUi } catch {}
    Stop-Presence
    if ($script:ScanJob) { Stop-Block $script:ScanJob $null 0 }
    $Sync.BridgeStop = $true; if ($script:BridgeJob) { Stop-Block $script:BridgeJob $null 2000 }
    try { Hide-Overlay; if ($script:OvOk) { $script:Rgb.Stop(); $script:Obs.Stop(); $script:Hotkey.Dispose(); $script:Pad.Dispose() } } catch {}
    $tray.Visible = $false; $tray.Dispose()
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.add_Tick({
    $line = $null
    while ($Sync.Queue.TryDequeue([ref]$line)) { Append-Log $line }

    # updates: check every 6 hours; install when ready unless a game is running (or it's set to ask)
    if ((Get-Date) -ge $script:NextUpdateCheck) { Start-UpdateCheck }
    switch ($Sync.UpdateState) {
        'current' { $updateLbl.Text = "Version $AppVersion - up to date"; $btnUpdate.Text = 'Check for updates'; $Sync.UpdateState = 'shown' }
        'failed'  { $updateLbl.Text = "Version $AppVersion - couldn't check (see Log)"; $Sync.UpdateState = 'shown' }
        'ready' {
            $updateLbl.Text = "Version $($Sync.LatestVersion) is ready"
            $btnUpdate.Text = 'Restart to update'
            if ($Settings.auto_update -and -not (Test-UpdateFailed $Sync.LatestVersion) -and -not (Test-GameRunning)) { $Sync.UpdateState = 'installing'; Install-Update }
        }
    }

    if ($Sync.ScanDone -and $script:ScanJob) {
        $Sync.ScanDone = $false
        $script:Library = @(Read-Library)
        $btnRescan.Text = 'Rescan'; $btnRescan.Enabled = $true
        Rebuild-Tiles; Push-GamesToEngine
        if ($script:PendingPlay) {
            $g = $script:Library | Where-Object { $_.id -eq $script:PendingPlay } | Select-Object -First 1
            $script:PendingPlay = ''
            if ($g) { Play-Game $g }
        }
    }
    if ($script:ScanJob -and $script:ScanJob.Handle.IsCompleted) {
        # a scan that ended without finishing would leave the button on "Scanning..." for good
        if (-not $Sync.ScanDone -and -not $btnRescan.Enabled) { $btnRescan.Text = 'Rescan'; $btnRescan.Enabled = $true }
        if ($script:RescanPending) { Start-Scan }
    }

    # a second "-Play <id>" launch (a desktop shortcut) left a game to start. An id that isn't in the
    # library, or a file that can't be read, is simply dropped.
    if ([IO.File]::Exists($PlayRequestPath)) {
        $want = ''
        try { $want = "$([IO.File]::ReadAllText($PlayRequestPath))".Trim() } catch {}
        try { Remove-Item -LiteralPath $PlayRequestPath -Force } catch {}
        if ($want) {
            $g = $script:Library | Where-Object { $_.id -eq $want } | Select-Object -First 1
            if ($g) { Play-Game $g }
            elseif ($script:ScanJob -and -not $script:ScanJob.Handle.IsCompleted) { $script:PendingPlay = $want }     # still looking for games
        }
    }

    if ($script:Job) {
        $statusLbl.Text = "Presence on`n$($Sync.Status)"; $statusLbl.ForeColor = $cGreen
        if ($script:Job.Handle.IsCompleted) {
            foreach ($m in (Get-BlockErrors $script:Job)) { $Sync.Queue.Enqueue(("[{0}] Presence stopped with an error: {1}" -f (Get-Date -Format 'HH:mm:ss'), $m)) }
            Stop-Presence
        }
        if ($Settings.exit_when_game_closes -and $Sync.GameExited) { $script:reallyQuit = $true; $form.Close() }
    } else {
        $statusLbl.Text = 'Presence off'; $statusLbl.ForeColor = $cDim
    }
    foreach ($id in @($script:Tiles.Keys)) {
        $t = $script:Tiles[$id]
        $isRun = @($Sync.RunningIds) -contains $id
        $t.Tile.BackColor = $(if ($isRun) { C '#243a2e' } else { $cCard })
        $t.Sub.Text = $(if ($isRun) { "$($t.Game.store)  -  Running" } else { "$($t.Game.store)" })
    }
})

Apply-ToUi
$script:LoadingC = $true
$rdoCMerge.Checked = ($Settings.custom_mode -eq 'merge'); $rdoCSep.Checked = -not $rdoCMerge.Checked
$script:LoadingC = $false
Refresh-CustomList $(if ($script:Customs.Count) { 0 } else { -1 })
Update-CustomInfo $null
Push-CustomToEngine
Show-Page 'Games'
Rebuild-Tiles
$timer.Start()

$form.add_Shown({
    $script:BridgeJob = Start-Block $Bridge @($Sync, $BridgePort, $AppVersion)     # the browser extension's link
    Start-Scan
    $script:NextUpdateCheck = (Get-Date).AddSeconds(20)   # first check shortly after opening
    if ($Settings.start_presence_on_open -or $script:PendingPlay) { Start-Presence }
    if ($script:PendingPlay -and $script:Library.Count) {
        $g = $script:Library | Where-Object { $_.id -eq $script:PendingPlay } | Select-Object -First 1
        if ($g) { $script:PendingPlay = ''; Play-Game $g }
    }
})

[System.Windows.Forms.Application]::Run($form)
$mutex.ReleaseMutex()
