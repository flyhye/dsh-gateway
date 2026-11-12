# One-time setup for the dsh gateway package.
#
# What it does:
#   1. copies the gateway + start/stop scripts into ~/.dsh/bin
#   2. creates a desktop shortcut "DeepSeek Harness" (unless -NoShortcut)
#   3. prints the line to put into VS Code settings.json
#   4. optionally starts everything right away (-NoStart skips)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1 -NoShortcut -NoStart

param(
  [int]$Port = 3080,
  [int]$GatewayPort = 3090,
  [switch]$NoShortcut,
  [switch]$NoStart,
  # for testing only: redirect install/desktop targets
  [string]$InstallDir,
  [string]$DesktopDir
)

$ErrorActionPreference = 'Stop'

$Src       = $PSScriptRoot
$DshHome   = Join-Path $env:USERPROFILE '.dsh'
$BinDir    = if ($InstallDir) { $InstallDir } else { Join-Path $DshHome 'bin' }
$Desktop   = if ($DesktopDir) { $DesktopDir } else { [Environment]::GetFolderPath('Desktop') }
$DshCmd    = Join-Path $env:APPDATA 'npm\dsh.cmd'
$Pwsh      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Wscript   = Join-Path $env:SystemRoot 'System32\wscript.exe'

Write-Host ''
Write-Host '  dsh-gateway setup' -ForegroundColor Cyan
Write-Host '  -----------------' -ForegroundColor DarkGray

# ---- preflight ----
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Host '  ERROR: node not found in PATH. Install Node.js first.' -ForegroundColor Red
  exit 1
}
if (-not (Test-Path $DshCmd)) {
  Write-Host "  ERROR: dsh not found at $DshCmd" -ForegroundColor Red
  Write-Host '  Install it first:  npm install -g @deepseek-ai/dsh' -ForegroundColor Yellow
  exit 1
}

# ---- 1. copy files ----
if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }
foreach ($name in @('dsh-gateway.mjs', 'start-dsh.ps1', 'start-dsh.vbs', 'stop-dsh.ps1')) {
  $from = Join-Path $Src $name
  if (-not (Test-Path $from)) {
    Write-Host "  ERROR: missing package file $from" -ForegroundColor Red
    exit 1
  }
  Copy-Item $from (Join-Path $BinDir $name) -Force
}
Write-Host "  installed scripts to: $BinDir" -ForegroundColor Green

# ---- 2. desktop shortcut ----
if (-not $NoShortcut) {
  $vbs = Join-Path $BinDir 'start-dsh.vbs'
  $lnk = Join-Path $Desktop 'DeepSeek Harness.lnk'
  $shell = New-Object -ComObject WScript.Shell
  $s = $shell.CreateShortcut($lnk)
  $s.TargetPath       = $Wscript
  $s.Arguments        = '"' + $vbs + '"'
  $s.WorkingDirectory = $BinDir
  $s.Description       = 'Start DeepSeek Harness (dsh web + no-login gateway)'
  $s.WindowStyle      = 1
  $s.Save()
  Write-Host "  desktop shortcut created: $lnk" -ForegroundColor Green
}

# ---- 3. VS Code settings hint ----
$settingsCandidates = @(
  (Join-Path $env:APPDATA 'Code\User\settings.json'),
  (Join-Path $env:USERPROFILE '.vscode\data\user-data\User\settings.json')
)
Write-Host ''
Write-Host '  VS Code: put this single line into settings.json' -ForegroundColor Cyan
Write-Host "      ""dshPanel.url"": ""http://127.0.0.1:$GatewayPort"""
Write-Host '  (no token, no autoStart - the gateway answers with 200 so the'
Write-Host '   extension skips its auth flow entirely)'
Write-Host ''
Write-Host '  detected settings.json locations:'
foreach ($c in $settingsCandidates) {
  $mark = if (Test-Path $c) { '[exists]' } else { '       ' }
  Write-Host "    $mark $c"
}

# ---- 4. start now ----
if (-not $NoStart) {
  Write-Host ''
  Write-Host '  starting dsh web + gateway ...' -ForegroundColor Gray
  & $Pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $BinDir 'start-dsh.ps1') `
      -Port $Port -GatewayPort $GatewayPort
}

Write-Host ''
Write-Host '  done. Daily use = double-click the desktop shortcut.' -ForegroundColor Green
Write-Host ''
Start-Sleep -Seconds 2
