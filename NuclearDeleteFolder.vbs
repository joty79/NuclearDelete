Option Explicit

Dim shell, scriptPath, targetPath, cmd
Set shell = CreateObject("WScript.Shell")
scriptPath = "D:\Users\joty79\scripts\NuclearDelete\NuclearDeleteFolder.ps1"

If WScript.Arguments.Count > 0 Then
    targetPath = Replace(WScript.Arguments(0), """", """"")
    cmd = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """ """ & targetPath & """"
    shell.Run cmd, 0, False
End If
