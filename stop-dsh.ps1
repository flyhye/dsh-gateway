# 停止由 setup/start 脚本启动的 dsh web 与网关。
#
# 只结束 PID 文件里记录的进程；不会碰你手动启动的实例。

param(
  [int]$Port = 3080,
  [int]$GatewayPort = 3090
)

$ErrorActionPreference = 'Stop'
$DshHome = Join-Path $env:USERPROFILE '.dsh'
$PidPath   = Join-Path $DshHome ("web-{0}.pid" -f $Port)
$GwPidPath = Join-Path $DshHome ("gateway-{0}.pid" -f $GatewayPort)

Write-Host ''
Write-Host '  DeepSeek Harness - stop' -ForegroundColor Cyan
Write-Host '  -----------------------' -ForegroundColor DarkGray

function Stop-Recorded {
  param([string]$File, [string]$Label)
  if (-not (Test-Path $File)) { return $false }
  $pidText = (Get-Content $File -Raw).Trim()
  Remove-Item $File -Force -ErrorAction SilentlyContinue
  if ($pidText -match '^\d+$') {
    $p = Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue
    if ($p) {
      Write-Host "  stopping $Label (PID $pidText) ..."
      & taskkill /PID $pidText /T /F 2>&1 | Out-Null
      return $true
    }
  }
  return $false
}

$stopped = $false
$stopped = (Stop-Recorded $GwPidPath 'gateway') -or $stopped
$stopped = (Stop-Recorded $PidPath 'dsh web') -or $stopped

# 兜底：PID 文件丢失时按端口找 node 监听进程
Start-Sleep -Milliseconds 700
foreach ($pair in @(@{P = $GatewayPort; Name = 'gateway'}, @{P = $Port; Name = 'dsh web'})) {
  $conn = Get-NetTCPConnection -LocalPort $pair.P -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($conn) {
    $owner = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    if ($owner -and $owner.ProcessName -eq 'node') {
      Write-Host "  port $($pair.P) still held by node (PID $($conn.OwningProcess)), stopping ..."
      & taskkill /PID $conn.OwningProcess /T /F 2>&1 | Out-Null
      $stopped = $true
    }
  }
}

if ($stopped) {
  Write-Host '  stopped.' -ForegroundColor Green
} else {
  Write-Host '  nothing running.' -ForegroundColor DarkGray
}
Write-Host ''
Start-Sleep -Seconds 2
