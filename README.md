# Claude Another Program Fix

A no-reboot workaround for Claude Desktop on Windows when AppX activation fails
with **“Another program is currently using this file”** or error `0x80070020`.

The script closes Claude and its native helper processes, finds the currently
installed MSIX package, and starts Claude with its original packaged profile so
the existing login and settings are used. If a system-level Claude service still
holds the package open, the script requests administrator permission, stops that
service, and retries once.

## Run

Double-click `Run-Fix-Claude-Desktop.cmd`, or open PowerShell in this directory
and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-Claude-Desktop.ps1
```

The command includes a process-only execution-policy bypass, so no permanent
PowerShell policy change is needed. Approve the Windows UAC prompt if the initial
user-level cleanup is not enough.

Claude and its `chrome-native-host` helper are force-closed during repair, so
save any unsent text first. The script does not close Chrome, modify
`WindowsApps` permissions, or delete the original Claude profile. Diagnostic
output is written to `%LOCALAPPDATA%\ClaudeDesktopRepair\repair.log`.

If the final message says a leaked AppX container remains, Windows has retained
kernel-level package state without a live process to stop; sign out of Windows
or restart in that specific case.
