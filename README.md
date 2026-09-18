# Claude Another Program Fix

A no-reboot workaround for Claude Desktop on Windows when AppX activation fails
with **“Another program is currently using this file”** or error `0x80070020`.

The script closes Claude, finds the currently installed MSIX package, and starts
Claude with its original packaged profile so the existing login and settings are
used. It does not modify `WindowsApps` permissions or delete the original profile.

## Run

Open PowerShell in this directory and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-Claude-Desktop.ps1
```

Claude is force-closed during repair, so save any unsent text first. Diagnostic
output is written to `%LOCALAPPDATA%\ClaudeDesktopRepair\repair.log`.
