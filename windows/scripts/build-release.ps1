# Builds Clinqy for Windows and packages it as dist\Clinqy-windows-x64.zip:
#   ClinqyApp.exe, clinqy.exe, extension\ (the browser extension, shared with the Mac app), Install Clinqy.bat
#   (double-click to install), install.ps1, Uninstall Clinqy.bat, uninstall.ps1, env.example and README.md.
# Usage (from anywhere):  powershell -ExecutionPolicy Bypass -File windows\scripts\build-release.ps1

$ErrorActionPreference = 'Stop'
$windows = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $windows

Push-Location $windows
try {
    cargo build --release
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
} finally { Pop-Location }

$dist = Join-Path $windows 'dist'
$stage = Join-Path $dist 'Clinqy'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null

$release = Join-Path $windows 'target\release'
Copy-Item (Join-Path $release 'ClinqyApp.exe') $stage
Copy-Item (Join-Path $release 'clinqy.exe') $stage
Copy-Item -Recurse (Join-Path $repo 'extension') (Join-Path $stage 'extension')
Copy-Item (Join-Path $PSScriptRoot 'install.ps1') $stage
Copy-Item (Join-Path $PSScriptRoot 'uninstall.ps1') $stage
Copy-Item (Join-Path $PSScriptRoot 'Install Clinqy.bat') $stage
Copy-Item (Join-Path $PSScriptRoot 'Uninstall Clinqy.bat') $stage
Copy-Item (Join-Path $windows 'env.windows.example') (Join-Path $stage 'env.example')
Copy-Item (Join-Path $windows 'README.md') $stage

$zip = Join-Path $dist 'Clinqy-windows-x64.zip'
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host "Built $zip ($size MB)"
