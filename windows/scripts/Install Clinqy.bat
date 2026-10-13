@echo off
rem Installs Clinqy for Windows for this user (no admin needed). Double-click it.
rem It runs install.ps1 next to it, or downloads the latest release when it is on its own (e.g. opened from inside the zip).
title Installing Clinqy
setlocal
if exist "%~dp0install.ps1" if exist "%~dp0ClinqyApp.exe" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://github.com/Amrit-Nigam/clinqy/releases/latest/download/install.ps1 | iex"
)
if errorlevel 1 (
  echo.
  echo Something went wrong above. Copy it and open an issue at https://github.com/Amrit-Nigam/clinqy/issues
)
echo.
pause
