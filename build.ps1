# Build lzScope CLAP plugin, run the smoke tests and install the .clap.
# Uses lazbuild (validates the .lpi files) with a plain-fpc fallback.
#
# Toolchain lookup: $env:LAZBUILD / $env:FPC if set, then PATH, then
# common install locations. Non-standard install? Set the env vars once
# in your PowerShell profile:
#   $env:LAZBUILD = 'D:\dev\lazarus\lazbuild.exe'

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Find-Tool([string]$override, [string]$name, [string[]]$candidates) {
    if ($override) {
        if (Test-Path $override) { return $override }
        throw "$name not found at '$override' (from env var)"
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in $candidates) {
        $hit = Get-Item $p -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

$lazbuild = Find-Tool $env:LAZBUILD 'lazbuild' @(
    'C:\lazarus\lazbuild.exe',
    'C:\Program Files\Lazarus\lazbuild.exe',
    "$env:LOCALAPPDATA\lazarus\lazbuild.exe")
$fpc = Find-Tool $env:FPC 'fpc' @(
    'C:\lazarus\fpc\*\bin\x86_64-win64\fpc.exe',
    'C:\Program Files\Lazarus\fpc\*\bin\x86_64-win64\fpc.exe')

if (-not $lazbuild -and -not $fpc) {
    throw 'Neither lazbuild nor fpc found. Install Lazarus or set $env:LAZBUILD / $env:FPC.'
}

function Build-Project([string]$lpi, [string]$lpr, [string[]]$unitDirs) {
    if ($lazbuild) {
        & $lazbuild --build-mode= $lpi
        if ($LASTEXITCODE -ne 0) { throw "lazbuild failed: $lpi" }
    } else {
        $fu = $unitDirs | ForEach-Object { "-Fu$_" }
        $outDir = Join-Path (Split-Path $lpr) 'lib'
        New-Item -ItemType Directory -Force $outDir | Out-Null
        & $fpc -B -O2 "-FU$outDir" @fu $lpr
        if ($LASTEXITCODE -ne 0) { throw "fpc failed: $lpr" }
    }
}

Build-Project 'lzscope.lpi' 'lzscope.lpr' @('src\clap','src\dsp','src\gui','src\plugin')
Build-Project 'tests\testhost.lpi' 'tests\testhost.lpr' @('src\clap','src\dsp')

& '.\tests\testhost.exe'
if ($LASTEXITCODE -ne 0) { Write-Host 'tests failed, not installing'; exit 1 }

Copy-Item lzscope.dll lzscope.clap -Force
$dst = "$env:LOCALAPPDATA\Programs\Common\CLAP"
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item lzscope.clap "$dst\lzscope.clap" -Force
Write-Host "installed -> $dst\lzscope.clap"
