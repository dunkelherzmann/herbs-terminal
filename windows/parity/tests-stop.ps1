# Stops test copies of the app left over from an interrupted run (only ones started with --parity-scene), so a
# rebuild can replace the program file. The user's own Herb's Terminal is never touched.
Get-CimInstance Win32_Process -Filter "Name='HerbsTerminal.exe'" |
    Where-Object { $_.CommandLine -like '*--parity-scene*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; "stopped test copy $($_.ProcessId)" }
# tailcat started by a test copy (sharing, or a proxy) from the test build folder, never anyone else's.
Get-CimInstance Win32_Process -Filter "Name='tailcat.exe'" |
    Where-Object { $_.ExecutablePath -like "$env:USERPROFILE\src\herbs-parity\*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; "stopped test tailcat $($_.ProcessId)" }
