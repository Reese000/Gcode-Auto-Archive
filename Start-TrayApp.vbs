Set WshShell = CreateObject("WScript.Shell")
' Support both manual launch (no args) and auto-start (with script path arg)
If WScript.Arguments.Count = 0 Then
    ' Manual launch: script is in same folder as this VBS
    scriptPath = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & "\Archive-Gcode-Tray.ps1"
Else
    ' Auto-start: first argument is the full script path
    scriptPath = WScript.Arguments(0)
End If
WshShell.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """ -StartNow", 0, False
Set WshShell = Nothing
