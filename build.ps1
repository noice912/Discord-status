<#
  Builds dist\RichPresence.exe from src\RichPresence.ps1 using the ps2exe module.
  Run:  powershell -ExecutionPolicy Bypass -File .\build.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host 'Installing the ps2exe module (one time, current user only)...'
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

# the version lives in the script ($AppVersion), so the EXE and the updater always agree
$ver = [regex]::Match((Get-Content (Join-Path $root 'src\RichPresence.ps1') -Raw), '\$AppVersion\s*=\s*''([0-9.]+)''').Groups[1].Value
if (-not $ver) { throw 'AppVersion not found in src\RichPresence.ps1' }

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null

# Discord in the overlay needs three Microsoft WebView2 files. build-chat.ps1 gets them (one fixed version
# from nuget.org, checked against a checksum) and zips them; the zip then goes inside the EXE as text, so
# the app is still a single file and never downloads them.
& (Join-Path $root 'build-chat.ps1')
$pack = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dist 'RichPresence-chat.zip')))
$text = Get-Content (Join-Path $root 'src\RichPresence.ps1') -Raw -Encoding UTF8
if (-not $text.Contains("`$ChatPack = ''")) { throw 'ChatPack placeholder not found in src\RichPresence.ps1' }
$script = Join-Path $dist 'RichPresence.build.ps1'
[IO.File]::WriteAllText($script, $text.Replace("`$ChatPack = ''", "`$ChatPack = '$pack'"), (New-Object System.Text.UTF8Encoding($true)))
Write-Host "WebView2 files packed into the EXE ($([math]::Round($pack.Length / 1KB)) KB of text)."

Invoke-ps2exe `
    -inputFile  $script `
    -outputFile (Join-Path $dist 'RichPresence.exe') `
    -iconFile   (Join-Path $root 'assets\icon.ico') `
    -noConsole -STA `
    -title 'RichPresence' -product 'RichPresence' `
    -description 'Game library with Discord Rich Presence' `
    -version "$ver.0"

Write-Host "Built: $(Join-Path $dist 'RichPresence.exe')"
