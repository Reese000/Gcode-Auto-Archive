@echo off
echo Installing G-Code Archive Watcher...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Archive-Gcode-Tray.ps1" -Install
rem Start the watcher immediately after installation (non-blocking)
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Archive-Gcode-Tray.ps1" -StartNow
echo.
echo Installation complete!
echo The app will now start automatically when you log in.
echo.
pause
