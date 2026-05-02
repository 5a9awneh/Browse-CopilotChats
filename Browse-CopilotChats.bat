@echo off
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0Browse-CopilotChats.ps1" %*
if %ERRORLEVEL% neq 0 pause
