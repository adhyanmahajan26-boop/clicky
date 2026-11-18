@echo off
rem Double-click this to run the Vello tester check. It runs Theo-Test.ps1 from beside this file, or, when this file is on
rem its own, first downloads the newest Theo-Test.ps1 beside it from the releases repo below (filled in on the copy a release
rem carries).
rem The check keeps itself up to date after that, so this one file is all a tester needs to keep.
setlocal
set "PUBLISHED_RELEASES_REPO="
cd /d "%~dp0"
if exist "%~dp0Theo-Test.ps1" goto run
if "%PUBLISHED_RELEASES_REPO%"=="" (
  echo This copy doesn't say where Vello's builds come from. Ask whoever sent it for the whole tester kit.
  pause
  exit /b 1
)
echo Downloading the newest tester check...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -UseBasicParsing -Uri ('https://github.com/' + $env:PUBLISHED_RELEASES_REPO + '/releases/latest/download/Theo-Test.ps1') -OutFile 'Theo-Test.ps1'"
if errorlevel 1 (
  echo Couldn't download it. Check the internet connection and try again.
  pause
  exit /b 1
)
:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Theo-Test.ps1"
