@echo off
echo Uninstalling G-Code Archive Watcher...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Archive-Gcode-Tray.ps1" -Uninstall
echo.
echo Uninstallation complete!
echo The auto-start has been removed.
echo.
pause
