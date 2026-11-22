<#
  Builds dist\RichPresence-chat.zip: the three Microsoft WebView2 files that let the overlay show Discord.

  They come from Microsoft's own package on nuget.org, at one fixed version whose checksum is written
  below, so a release can only ever contain exactly these files. build.ps1 runs this and puts the zip
  inside the EXE; the app unpacks it on first use and never downloads anything.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

$Version = '1.0.4370.26'
$PackageHash = '1c0dacac84b70109b3fd42f90c53a0ba942abc3a87590d7a4e0ccd86e4a06cf4'     # SHA-256 of the .nupkg
$Files = [ordered]@{
    'lib/net462/Microsoft.Web.WebView2.Core.dll'     = 'Microsoft.Web.WebView2.Core.dll'
    'lib/net462/Microsoft.Web.WebView2.WinForms.dll' = 'Microsoft.Web.WebView2.WinForms.dll'
    'runtimes/win-x64/native/WebView2Loader.dll'     = 'WebView2Loader.dll'
    'LICENSE.txt'                                    = 'WebView2-LICENSE.txt'     # Microsoft's licence travels with them
}

$dist = Join-Path $root 'dist'
$out = Join-Path $dist 'webview2'      # not "chat": the app would load a folder of that name next to the EXE
New-Item -ItemType Directory -Path $out -Force | Out-Null
$pkg = Join-Path $dist "microsoft.web.webview2.$Version.nupkg"

if (-not (Test-Path $pkg) -or (Get-FileHash $pkg -Algorithm SHA256).Hash.ToLower() -ne $PackageHash) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Host "Downloading Microsoft.Web.WebView2 $Version from nuget.org..."
    (New-Object System.Net.WebClient).DownloadFile("https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$Version/microsoft.web.webview2.$Version.nupkg", $pkg)
}
$got = (Get-FileHash $pkg -Algorithm SHA256).Hash.ToLower()
if ($got -ne $PackageHash) { Remove-Item $pkg -Force; throw "The WebView2 package doesn't match its checksum (got $got)." }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [IO.Compression.ZipFile]::OpenRead($pkg)
try {
    foreach ($from in $Files.Keys) {
        $e = $z.Entries | Where-Object { $_.FullName -eq $from } | Select-Object -First 1
        if (-not $e) { throw "$from is not in the package" }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $out $Files[$from]), $true)
    }
} finally { $z.Dispose() }

$zip = Join-Path $dist 'RichPresence-chat.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path ($Files.Values | ForEach-Object { Join-Path $out $_ }) -DestinationPath $zip
Write-Host "Built: $zip"
