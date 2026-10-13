@echo off
rem Removes Clinqy (your settings and data stay). Double-click it.
title Uninstalling Clinqy
rem One line: cmd reads it whole before this folder is deleted.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" & echo. & pause
