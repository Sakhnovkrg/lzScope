# Windows release: builds and tests with build.ps1, then zips lzscope.clap
# for the GitHub release into dist\lzScope-CLAP-<version>-windows.zip.
#
#   tools\release-windows.ps1

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot)

& .\build.ps1
if ($LASTEXITCODE -ne 0) { exit 1 }

$m = Select-String -Path src\dsp\scope_state.pas -Pattern "PLUGIN_VERSION\s*=\s*'(.+)';"
if (-not $m) { throw 'PLUGIN_VERSION not found in src\dsp\scope_state.pas' }
$version = $m.Matches[0].Groups[1].Value

New-Item -ItemType Directory -Force dist | Out-Null
$zip = "dist\lzScope-CLAP-$version-windows.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path lzscope.clap -DestinationPath $zip

Write-Host "release -> $zip"
