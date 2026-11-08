# Stops test copies of the app left over from an interrupted run (only ones started with --parity-scene), so a
# rebuild can replace the program file. The user's own Herb's Terminal is never touched.
Get-CimInstance Win32_Process -Filter "Name='HerbsTerminal.exe'" |
    Where-Object { $_.CommandLine -like '*--parity-scene*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; "stopped test copy $($_.ProcessId)" }
