# Removes Clinqy for Windows: the app, its Start menu shortcut, PATH entry, login item and clinqy:// links.
# Your settings (~\.config\clinqy) and data (%APPDATA%\Clinqy: history, memory, skills) stay unless -Purge.
param([switch]$Purge)

$ErrorActionPreference = 'SilentlyContinue'
$dest = Join-Path $env:LOCALAPPDATA 'Programs\Clinqy'

Get-Process ClinqyApp | Stop-Process -Force
Start-Sleep -Milliseconds 400

Remove-Item -Force (Join-Path ([Environment]::GetFolderPath('Programs')) 'Clinqy.lnk')
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Clinqy'
Remove-Item -Recurse -Force 'HKCU:\Software\Classes\clinqy'
$path = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($path) {
    [Environment]::SetEnvironmentVariable('Path', (($path -split ';') | Where-Object { $_ -and $_ -ne $dest }) -join ';', 'User')
}

# This script may be running from inside the folder it deletes: delete it from a moment later.
Start-Process -WindowStyle Hidden powershell -ArgumentList '-NoProfile', '-Command', "Start-Sleep 1; Remove-Item -Recurse -Force '$dest'"

if ($Purge) {
    Remove-Item -Recurse -Force (Join-Path $env:USERPROFILE '.config\clinqy')
    Remove-Item -Recurse -Force (Join-Path $env:APPDATA 'Clinqy')
    Remove-Item -Recurse -Force (Join-Path $env:LOCALAPPDATA 'Clinqy')
}
Write-Host 'Clinqy is uninstalled.' -ForegroundColor Green
