' DeepSeek Harness launcher wrapper.
' Invoked by the desktop shortcut through wscript.exe.
'
' This file is deliberately pure ASCII. Windows Script Host reads .vbs as
' ANSI, so any non-ASCII text here would be mis-decoded and break parsing.

Option Explicit

Dim shell, fso, home, ps1, cmd

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

home = shell.ExpandEnvironmentStrings("%USERPROFILE%")
ps1 = home & "\.dsh\bin\start-dsh.ps1"

If Not fso.FileExists(ps1) Then
  MsgBox "Launcher not found:" & vbCrLf & ps1, 16, "DeepSeek Harness"
  WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps1 & """"

On Error Resume Next
shell.Run cmd, 1, False
If Err.Number <> 0 Then
  MsgBox "Launch failed:" & vbCrLf & Err.Description, 16, "DeepSeek Harness"
  WScript.Quit 1
End If
