@echo off
rem Double-click to open the Claude CLI command palette.
rem Deliberately plain: no -ExecutionPolicy Bypass and no -WindowStyle Hidden,
rem because that pair is what antivirus heuristics flag as a PowerShell loader.
rem The host console shows briefly, then the script hides it once the palette
rem window is up, so a startup failure is still readable on screen.
rem Add -KeepConsole to the line below if you need to see that output.
rem Swap -Config in to drive a different CLI, e.g. -Config "gemini.json".
cd /d "%~dp0"
start "Agent CLI Palette" /min powershell.exe -NoLogo -NoProfile -STA -File "AgentCliPalette.ps1"
