# Opens one parity scene of the Windows build, saves its UI tree (UI Automation) and the window's own picture,
# then closes it. The installed app and the user's settings are not used: the scene keeps its files in %TEMP%.
# Run on the Windows PC (over SSH is fine):
#   windows/parity/scene.ps1 -Scene main -Out <output folder> -Exe <HerbsTerminal.exe> -Dump <uia-dump.ps1>
# UI Automation and PrintWindow need the logged-in desktop, which an SSH session doesn't have, so the script
# runs itself again there through a one-time scheduled task ("Herb's Terminal parity") and waits for it. The scene's
# window opens without taking focus, for a few seconds, then closes.
param(
    [Parameter(Mandatory)][string]$Scene,
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Dump,
    [int]$Settle = 4,
    [switch]$InDesktop
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out | Out-Null
$log = Join-Path $Out "$Scene-scene.log"

if (-not $InDesktop) {
    $done = Join-Path $Out "$Scene.done"
    Remove-Item -Force -ErrorAction SilentlyContinue $done, $log
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Scene $Scene " +
                 "-Out `"$Out`" -Exe `"$Exe`" -Dump `"$Dump`" -Settle $Settle -InDesktop"
    $task = 'Herb''s Terminal parity'
    Register-ScheduledTask -TaskName $task -Force -Action (New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arguments) `
        -Principal (New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited) `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)) | Out-Null
    try {
        Start-ScheduledTask -TaskName $task
        $deadline = (Get-Date).AddSeconds(90)
        while (-not (Test-Path $done) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    } finally {
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
    }
    if (Test-Path $log) { Get-Content $log }
    if (-not (Test-Path $done)) { throw "The scene didn't finish (is anyone logged in to the PC's desktop?)." }
    exit 0
}

# From here on: inside the desktop session.
Start-Transcript -Path $log -Force | Out-Null
$app = $null
try {
    foreach ($name in "$Scene-tree.json", "$Scene.png") { Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Out $name) }
    # Every scene starts from nothing: no settings, no logins, an empty home.
    foreach ($folder in 'herbs-parity', 'herbs-parity-app') {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $env:TEMP $folder)
    }
    $env:HERBS_PARITY = '1'
    $app = Start-Process -FilePath $Exe -ArgumentList '--parity-scene', $Scene -PassThru
    $hwnd = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(30)
    while ($hwnd -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $app.Refresh()
        if ($app.HasExited) { throw "The app quit before showing its window (exit code $($app.ExitCode))." }
        $hwnd = $app.MainWindowHandle
    }
    if ($hwnd -eq [IntPtr]::Zero) { throw "The app's window didn't appear." }
    Start-Sleep -Seconds $Settle
    & $Dump -Hwnd $hwnd.ToInt64() -Out (Join-Path $Out "$Scene-tree.json") -Picture (Join-Path $Out "$Scene.png")
    "parity: saved $Scene"
} catch {
    "parity: $($_.Exception.Message)"
} finally {
    # The scene's shell ends with it (taskkill /T takes its Command Prompt and console host too).
    if ($app -and -not $app.HasExited) { & taskkill.exe /PID $app.Id /T /F | Out-Null }
    Stop-Transcript | Out-Null
    Set-Content -Path (Join-Path $Out "$Scene.done") -Value (Get-Date -Format o)
}
