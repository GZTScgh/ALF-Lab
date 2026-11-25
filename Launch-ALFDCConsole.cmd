@echo off
rem Version: ALF Lab Builder 2.1.1
powershell.exe -NoProfile -STA -File "%~dp0ALFGuestConsole.ps1" -Role DC
if errorlevel 1 pause
