@echo off
rem Version: ALF Lab Builder 2.1.0
powershell.exe -NoProfile -STA -File "%~dp0ALFGuestConsole.ps1" -Role Node
if errorlevel 1 pause
