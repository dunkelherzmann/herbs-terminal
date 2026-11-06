# Builds Herb's Terminal for Windows.
#
#   windows\dev\build.ps1            debug build
#   windows\dev\build.ps1 -Release   release build
#   windows\dev\build.ps1 -Run       build, then start the app
#   windows\dev\build.ps1 -SelfTest  build, then run the headless self-test
#
# Needs the Swift toolchain for Windows (6.x) and Visual Studio 2022 or its Build Tools with the C++ workload
# (MSVC and a Windows SDK). The script finds both and sets up the MSVC environment itself, so it runs from any
# PowerShell window.
param([switch]$Release, [switch]$Run, [switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$windows = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $windows

# The MSVC environment (link.exe, the CRT and Windows SDK paths), from vcvars64.bat.
if (-not (Get-Command link.exe -ErrorAction SilentlyContinue)) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw "Visual Studio or its Build Tools aren't installed (no vswhere.exe)." }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw "No Visual Studio installation has the C++ build tools (MSVC x64)." }
    $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
    $env:PATH = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer;$env:PATH"
    cmd /c "`"$vcvars`" >nul && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
    }
}
if (-not $env:SDKROOT) { $env:SDKROOT = [Environment]::GetEnvironmentVariable('SDKROOT', 'User') }
if (-not $env:SDKROOT) { throw "SDKROOT isn't set; reinstall the Swift toolchain for Windows." }

# SwiftTerm's build plugin asks git for its version, which fails on Windows; these give it the answer.
$env:SWIFTTERM_BUILD_BRANCH = 'release'
$env:SWIFTTERM_BUILD_TAG = '1.20.0'
$env:SWIFTTERM_BUILD_COMMIT = '5d14406844143538cd8f8851d2d8a67c1fe443e5'
$env:SWIFTTERM_BUILD_DIRTY = 'false'

# The sources Windows shares with the Mac and Linux versions are copied in (Windows checkouts usually can't
# make symbolic links). The list is windows\shared.txt; the copies are gitignored and refreshed on every build.
$shared = Join-Path $windows 'Sources\HerbsTerminal\Shared'
if (Test-Path $shared) { Remove-Item -Recurse -Force $shared }
New-Item -ItemType Directory -Force $shared | Out-Null
Get-Content (Join-Path $windows 'shared.txt') | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
    $source = Join-Path $repo $_.Trim()
    if (-not (Test-Path $source)) { throw "Shared source missing: $_" }
    Copy-Item $source $shared
}

# The version, from git like the other builds: VERSION's major.minor plus commits since VERSION last changed.
$base = (Get-Content (Join-Path $repo 'VERSION') -Raw).Trim()
$since = git -C $repo log -1 --format=%H -- VERSION
$patch = if ($since) { git -C $repo rev-list --count "$since..HEAD" } else { 0 }
Set-Content -Encoding utf8 (Join-Path $windows 'Sources\HerbsTerminal\Version.swift') "let appVersion = `"$base.$patch`""

$configuration = if ($Release) { 'release' } else { 'debug' }
Push-Location $windows
try {
    $ErrorActionPreference = 'Continue'
    cmd /c "swift build -c $configuration 2>&1" | Where-Object { $_ -notmatch 'wchar_t|unable to create symbolic link' -and $_ -notmatch '^\s*(\||`-|note:)' }
    if ($LASTEXITCODE -ne 0) { throw "swift build failed." }
} finally { Pop-Location }

$folder = if ($Release) { 'Release' } else { 'Debug' }
$exe = Join-Path $windows ".build\out\Products\$folder-windows-x86_64\HerbsTerminal.exe"
if (-not (Test-Path $exe)) { $exe = Join-Path $windows ".build\$configuration\HerbsTerminal.exe" }
Write-Host "Built $exe"
if ($SelfTest) { & $exe --self-test; exit $LASTEXITCODE }
if ($Run) { Start-Process $exe }
