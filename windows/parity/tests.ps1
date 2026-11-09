# Runs the feature tests on Windows in the logged-in desktop session (where the app's windows can open).
#   parity\tests\windows.ps1 [-Only W1,T3]      (over SSH is fine: it runs itself again through a one-time task)
param([string]$Only = '', [string]$Exe = '', [switch]$InDesktop)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Exe) { $Exe = Join-Path $repo 'windows\.build\out\Products\Debug-windows-x86_64\HerbsTerminal.exe' }
$log = Join-Path $repo 'parity\results\windows.log'
$done = Join-Path $repo 'parity\results\windows.done'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
if (-not $InDesktop) {
    Remove-Item -Force -ErrorAction SilentlyContinue $done, $log
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Exe `"$Exe`" -InDesktop" + $(if ($Only) { " -Only $Only" } else { '' })
    $task = 'Herb''s Terminal feature tests'
    Register-ScheduledTask -TaskName $task -Force -Action (New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arguments) `
        -Principal (New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited) `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)) | Out-Null
    try {
        Start-ScheduledTask -TaskName $task
        while (-not (Test-Path $done)) { Start-Sleep -Seconds 2 }
    } finally { Unregister-ScheduledTask -TaskName $task -Confirm:$false }
    Get-Content $log
    exit 0
}
try {
    $python = (Get-Command python -ErrorAction Stop).Source
    $runArgs = @((Join-Path $repo 'parity\tests\run.py'), '--platform', 'windows', '--exe', $Exe)
    if ($Only) { $runArgs += @('--only', $Only) }
    $env:PYTHONIOENCODING = 'utf-8'
    & $python @runArgs 2>&1 | Out-File -Encoding utf8 $log
} catch { "tests: $($_.Exception.Message)" | Out-File -Append $log }
finally { Set-Content -Path $done -Value (Get-Date -Format o) }
