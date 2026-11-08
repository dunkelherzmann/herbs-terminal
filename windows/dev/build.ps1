# Builds Herb's Terminal for Windows.
#
#   windows\dev\build.ps1            debug build
#   windows\dev\build.ps1 -Release   release build
#   windows\dev\build.ps1 -Run       build, then start the app
#   windows\dev\build.ps1 -SelfTest  build, then run the headless self-test
#   windows\dev\build.ps1 -Package   self-contained release build in dist\HerbsTerminal-windows, plus a zip
#
# A packaged build is self-contained: beside HerbsTerminal.exe are exactly the Swift runtime, Foundation and
# Microsoft C++ runtime DLLs it uses (found by following each file's imports), deployed app-locally. Nothing needs
# installing: copy the folder anywhere, or unzip it, and open HerbsTerminal.exe on Windows 10 (1809 or later) or
# 11. (Linking the Swift runtime in statically was tried: Swift 6.4's static runtime crashes on Windows when a
# property wrapper writes through its enclosing instance, which the settings and login code rely on.)
#
# Needs the Swift toolchain for Windows (6.x) and Visual Studio 2022 or its Build Tools with the C++ workload
# (MSVC and a Windows SDK). The script finds both and sets up the MSVC environment itself, so it runs from any
# PowerShell window.
param([switch]$Release, [switch]$Run, [switch]$SelfTest, [switch]$Package)
if ($Package) { $Release = $true }

$ErrorActionPreference = 'Stop'
$windows = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $windows

# Visual Studio (or its Build Tools) with the x64 C++ tools.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw "Visual Studio or its Build Tools aren't installed (no vswhere.exe)." }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "No Visual Studio installation has the C++ build tools (MSVC x64)." }

# The MSVC environment (link.exe, dumpbin, the CRT and Windows SDK paths), from vcvars64.bat.
if (-not (Get-Command dumpbin.exe -ErrorAction SilentlyContinue)) {
    $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
    $env:PATH = (Split-Path -Parent $vswhere) + ";$env:PATH"
    cmd /c "`"$vcvars`" >nul && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
    }
}
if (-not $env:SDKROOT) { $env:SDKROOT = [Environment]::GetEnvironmentVariable('SDKROOT', 'User') }
if (-not $env:SDKROOT) { $env:SDKROOT = [Environment]::GetEnvironmentVariable('SDKROOT', 'Machine') }
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
# A copy without git history (sent to a test machine) takes the version from HERBS_VERSION instead.
if ($env:HERBS_VERSION) {
    $version = $env:HERBS_VERSION
} else {
    $base = (Get-Content (Join-Path $repo 'VERSION') -Raw).Trim()
    $since = git -C $repo log -1 --format=%H -- VERSION
    $patch = if ($since) { git -C $repo rev-list --count "$since..HEAD" } else { 0 }
    $version = "$base.$patch"
}
Set-Content -Encoding utf8 (Join-Path $windows 'Sources\HerbsTerminal\Version.swift') "let appVersion = `"$version`""

$configuration = if ($Release) { 'release' } else { 'debug' }
$scratch = '.build'
Push-Location $windows
try {
    $ErrorActionPreference = 'Continue'
    cmd /c "swift build -c $configuration --scratch-path $scratch 2>&1" |
        Where-Object { $_ -notmatch 'wchar_t|unable to create symbolic link' -and $_ -notmatch '^\s*(\||`-|note:)' }
    if ($LASTEXITCODE -ne 0) { throw "swift build failed." }
    $ErrorActionPreference = 'Stop'
} finally { Pop-Location }

$folder = if ($Release) { 'Release' } else { 'Debug' }
$exe = Join-Path $windows "$scratch\out\Products\$folder-windows-x86_64\HerbsTerminal.exe"
if (-not (Test-Path $exe)) { $exe = Join-Path $windows "$scratch\$configuration\HerbsTerminal.exe" }
if (-not (Test-Path $exe)) { throw "The build didn't produce HerbsTerminal.exe." }
Write-Host "Built $exe"

if ($Package) {
    $out = Join-Path $repo 'dist\HerbsTerminal-windows'
    if (Test-Path $out) { Remove-Item -Recurse -Force $out }
    New-Item -ItemType Directory -Force $out | Out-Null
    Copy-Item $exe $out

    # Where the DLLs come from: the Swift runtime folder (on PATH, where the toolchain installer puts it) and
    # Visual Studio's redistributable folder for the Microsoft C++ runtime (newest version first).
    $runtime = $env:PATH -split ';' | Where-Object { $_ -and (Test-Path (Join-Path $_ 'swiftCore.dll')) } | Select-Object -First 1
    if (-not $runtime) { throw "Couldn't find the Swift runtime (swiftCore.dll) on PATH." }
    $redist = Get-ChildItem (Join-Path $vs 'VC\Redist\MSVC') -Directory | Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
        Sort-Object { [version]$_.Name } -Descending | ForEach-Object {
            Get-ChildItem (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue
        } | Select-Object -First 1
    if (-not $redist) { throw "Couldn't find the Visual C++ redistributable files in $vs\VC\Redist\MSVC." }

    # Follow the imports from HerbsTerminal.exe outwards. Every DLL is either part of Windows or bundled; anything
    # else means a dependency the package wouldn't carry, so the build stops.
    $bundled = [ordered]@{}
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($exe)
    while ($queue.Count -gt 0) {
        $file = $queue.Dequeue()
        $imports = cmd /c "dumpbin /nologo /dependents `"$file`"" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[\w.-]+\.dll$' }
        foreach ($dll in $imports) {
            $key = $dll.ToLower()
            if ($bundled.Contains($key)) { continue }
            $source = @((Join-Path $redist.FullName $dll), (Join-Path $runtime $dll)) | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($source) {
                Copy-Item $source $out
                $bundled[$key] = $dll
                $queue.Enqueue($source)
            } elseif ($dll -notmatch '^api-ms-win-' -and -not (Test-Path (Join-Path $env:SystemRoot "System32\$dll"))) {
                throw "$(Split-Path -Leaf $file) needs $dll, which is neither part of Windows nor bundled."
            }
        }
    }
    # msvcp140 relies on vcruntime140_1 for x64 exception handling; bring it along with it.
    $helper = Join-Path $redist.FullName 'vcruntime140_1.dll'
    if ($bundled.Contains('msvcp140.dll') -and -not $bundled.Contains('vcruntime140_1.dll') -and (Test-Path $helper)) {
        Copy-Item $helper $out
        $bundled['vcruntime140_1.dll'] = 'vcruntime140_1.dll'
    }
    Copy-Item (Join-Path $repo 'LICENSE') (Join-Path $out 'LICENSE.txt')
    Copy-Item (Join-Path $windows 'NOTICES-windows.txt') $out

    $zip = Join-Path $repo "dist\Herbs-Terminal-$base.$patch-windows-x86_64.zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }
    Compress-Archive -Path $out -DestinationPath $zip
    $size = '{0:N1} MB' -f ((Get-ChildItem $out -Recurse | Measure-Object Length -Sum).Sum / 1MB)
    Write-Host "Packaged $out ($size; $($bundled.Count) DLLs: $($bundled.Values -join ', '))"
    Write-Host "Zipped   $zip"
    $exe = Join-Path $out 'HerbsTerminal.exe'
}

if ($SelfTest) { & $exe --self-test; exit $LASTEXITCODE }
if ($Run) { Start-Process $exe }
