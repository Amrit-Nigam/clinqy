# Installs Clinqy for Windows for the current user (no admin needed):
#   - copies the app to %LOCALAPPDATA%\Programs\Clinqy (replacing an older version, keeping your settings and data)
#   - adds a Start menu shortcut and puts `clinqy` on your PATH (for terminals and coding agents)
#   - opens Clinqy at login, and starts it
#
# From an unzipped release:   double-click "Install Clinqy.bat" (it runs this with the right PowerShell settings)
# Or in one line:             irm <release-url>/install.ps1 | iex      (downloads the latest zip itself)
param(
    [string]$Zip = '',
    [string]$Url = 'https://github.com/Amrit-Nigam/clinqy/releases/latest/download/Clinqy-windows-x64.zip',
    [switch]$NoStart,
    [switch]$NoLogin
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dest = Join-Path $env:LOCALAPPDATA 'Programs\Clinqy'

function Say($text) { Write-Host "  $text" }
Write-Host ''
Write-Host 'Installing Clinqy' -ForegroundColor Cyan

# Where the files come from: next to this script (an unzipped release), a given zip, or the latest release.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { '' }
$source = $null
$temp = $null
if (-not $Zip -and $here -and (Test-Path (Join-Path $here 'ClinqyApp.exe'))) {
    $source = $here
} else {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("clinqy-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force $temp | Out-Null
    if (-not $Zip) {
        Say "Downloading $Url"
        $Zip = Join-Path $temp 'Clinqy.zip'
        Invoke-WebRequest -Uri $Url -OutFile $Zip -UseBasicParsing
    }
    Expand-Archive -Path $Zip -DestinationPath (Join-Path $temp 'x') -Force
    $source = Join-Path $temp 'x'
}

# A running copy has to stop before its files can be replaced.
Get-Process ClinqyApp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400

New-Item -ItemType Directory -Force $dest | Out-Null
Get-ChildItem $dest -Filter '*.old-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
foreach ($item in 'ClinqyApp.exe', 'clinqy.exe', 'extension', 'env.example', 'README.md', 'uninstall.ps1', 'Uninstall Clinqy.bat') {
    $from = Join-Path $source $item
    if (Test-Path $from) {
        $to = Join-Path $dest $item
        if (Test-Path $to) {
            try { Remove-Item -Recurse -Force $to -ErrorAction Stop }
            catch {
                # A coding agent connected over MCP keeps clinqy.exe running, which locks the file. Windows lets a
                # running program be renamed, so it moves aside; the next install cleans it up.
                Move-Item -Force $to ($to + '.old-' + [guid]::NewGuid())
            }
        }
        Copy-Item -Recurse $from $to
    }
}
# Older builds kept WebView2's profile next to the exe; it now lives in %LOCALAPPDATA%\Clinqy.
Remove-Item -Recurse -Force (Join-Path $dest 'ClinqyApp.exe.WebView2') -ErrorAction SilentlyContinue
Say "App: $dest"

# Start menu shortcut.
$programs = [Environment]::GetFolderPath('Programs')
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path $programs 'Clinqy.lnk'))
$link.TargetPath = Join-Path $dest 'ClinqyApp.exe'
$link.WorkingDirectory = $dest
$link.Description = 'Clinqy: tell your computer what to do'
$link.Save()
Say 'Start menu: Clinqy'

# `clinqy` on the PATH (user scope).
$path = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $path) { $path = '' }
if (-not (($path -split ';') -contains $dest)) {
    [Environment]::SetEnvironmentVariable('Path', ($path.TrimEnd(';') + ';' + $dest).TrimStart(';'), 'User')
    Say 'Command: clinqy (open a new terminal to use it)'
}

# Open at login (the tray menu can turn it off).
if (-not $NoLogin) {
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Clinqy' -Value ('"' + (Join-Path $dest 'ClinqyApp.exe') + '" --login')
}

# The command bar and result card are WebView2 pages: built into Windows 11, and into Windows 10 with Edge.
$wv = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$wvUser = 'HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
if (-not ((Test-Path $wv) -or (Test-Path $wvUser))) {
    Write-Host '  WebView2 Runtime not found: install it from https://go.microsoft.com/fwlink/p/?LinkId=2124703' -ForegroundColor Yellow
}

if ($temp) { Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue }

if (-not $NoStart) {
    Start-Process (Join-Path $dest 'ClinqyApp.exe')
}
Write-Host ''
Write-Host 'Done. Press Ctrl+Alt to open Clinqy, or hold Ctrl+H to talk.' -ForegroundColor Green
Write-Host 'Next: paste the setup prompt from clinqy.vercel.app into your coding agent, or run these in a new terminal:'
Write-Host '  clinqy model           (which AI it uses: Claude Code, then Codex, then agy, then Ollama)'
Write-Host '  clinqy extension install'
Write-Host '  clinqy doctor'
Write-Host ''
