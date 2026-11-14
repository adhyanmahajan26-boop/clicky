@echo off
rem Double-click this to run the Theo tester check. It opens PowerShell with the script next to this file.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Theo-Test.ps1"
