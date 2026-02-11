Option Explicit

Dim shell, fso, scriptPath, stateRoot, lockFile
Dim cmd, targetPath, lockAcquired, rc
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptPath = "D:\Users\joty79\scripts\MoveTo\NuclearDelete\NuclearDeleteFolder.ps1"
stateRoot = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\MoveTo\NuclearDelete"
lockFile = stateRoot & "\worker.lock"

Call EnsureStateFolder(stateRoot)
Call CleanupStaleLock(lockFile, 5)

If WScript.Arguments.Count > 0 Then
    targetPath = Replace(WScript.Arguments(0), """", """""")
    lockAcquired = TryAcquireLock(lockFile)
    If lockAcquired Then
        cmd = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """ """ & targetPath & """"
        rc = shell.Run(cmd, 0, True)
        On Error Resume Next
        If fso.FileExists(lockFile) Then fso.DeleteFile lockFile, True
        On Error GoTo 0
    End If
End If

Function EnsureStateFolder(path)
    On Error Resume Next
    If Not fso.FolderExists(path) Then
        fso.CreateFolder path
    End If
    On Error GoTo 0
End Function

Sub CleanupStaleLock(path, staleMinutes)
    Dim dt
    On Error Resume Next
    If fso.FileExists(path) Then
        dt = fso.GetFile(path).DateLastModified
        If DateDiff("n", dt, Now) >= staleMinutes Then
            fso.DeleteFile path, True
        End If
    End If
    On Error GoTo 0
End Sub

Function TryAcquireLock(path)
    Dim ts
    TryAcquireLock = False
    On Error Resume Next
    Set ts = fso.CreateTextFile(path, False, False)
    If Err.Number = 0 Then
        ts.WriteLine CStr(Now)
        ts.Close
        TryAcquireLock = True
    End If
    Err.Clear
    On Error GoTo 0
End Function
