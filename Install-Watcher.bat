@echo off
echo Installing G-Code Archive Watcher...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Archive-Gcode-Tray.ps1" -Install
echo.
echo Installation complete!
echo The app will now start automatically when you log in.
echo.
pause
