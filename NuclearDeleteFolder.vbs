Option Explicit

Dim shell, folderPath, cmd
Set shell = CreateObject("WScript.Shell")

If WScript.Arguments.Count > 0 Then
    folderPath = WScript.Arguments(0)
    cmd = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ""D:\Users\joty79\scripts\MoveTo\NuclearDelete\NuclearDeleteFolder.ps1"" """ & folderPath & """"
    shell.Run cmd, 1, False
End If
