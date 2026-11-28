' Silent launcher for the DeepAI TPS counter.
' Used by the logon scheduled task and by the Start menu shortcut, so no
' console window flashes at logon.
Set sh = CreateObject("WScript.Shell")
base = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "start.ps1"" -Quiet", 0, False
