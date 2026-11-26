@echo off
rem Version: ALF Lab Builder 2.1.1   (should match VERSION.txt)
rem Starts 2. ALF Lab Builder - Host Console on the lab host (Azure VM). It asks for administrator rights.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0ALFHostConsole.ps1"
