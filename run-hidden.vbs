' run-hidden.vbs — launch claude-resume.ps1 fully hidden, forwarding all arguments.
' Used by the ClaudeResume-Fire and ClaudeResume-Logon scheduled tasks so no
' console window flashes. Runs pwsh with the same directory as this script.
Dim args, i, sh, ps1, cmd
args = ""
For i = 0 To WScript.Arguments.Count - 1
  args = args & " " & Chr(34) & WScript.Arguments(i) & Chr(34)
Next
ps1 = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\")) & "claude-resume.ps1"
Set sh = CreateObject("WScript.Shell")
cmd = "pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & Chr(34) & ps1 & Chr(34) & args
sh.Run cmd, 0, False
