# 启动 DeepSeek Harness：dsh web（3080）+ 免登录网关（3090）。
#
# 用法：
#   start-dsh.ps1             启动并打开浏览器
#   start-dsh.ps1 -NoBrowser  启动但不打开浏览器
#   start-dsh.ps1 -Port 3080 -GatewayPort 3090   自定义端口
#
# 架构：
#   浏览器 / VS Code 面板 → 网关(GatewayPort) → dsh web(Port)
#
# 为什么需要网关：
#   dsh web 每次启动都会更换登录令牌（token），且只打印一次。任何客户端
#   （VS Code 面板、新开的浏览器）都得拿当前 token 才能换取会话 Cookie。
#   网关用 dsh 持久化的签名密钥（~/.dsh/.credentials.yaml，永不变）为每个
#   请求现签 Cookie，所以 dsh 重启后所有客户端依然免登录，无需再粘任何链接。
#
# 已在运行的部分会被复用，绝不重启——避免打断正在进行的任务。

param(
  [switch]$NoBrowser,
  [int]$Port = 3080,
  [int]$GatewayPort = 3090
)

$ErrorActionPreference = 'Stop'

$DshHome   = Join-Path $env:USERPROFILE '.dsh'
# 日志/PID 文件按端口区分，避免多实例互相覆盖
$LogPath   = Join-Path $DshHome ("web-{0}.log" -f $Port)
$PidPath   = Join-Path $DshHome ("web-{0}.pid" -f $Port)
$GwLogPath = Join-Path $DshHome ("gateway-{0}.log" -f $GatewayPort)
$GwPidPath = Join-Path $DshHome ("gateway-{0}.pid" -f $GatewayPort)
$BinDir    = Join-Path $DshHome 'bin'
$GwScript  = Join-Path $BinDir 'dsh-gateway.mjs'
$DshCmd    = Join-Path $env:APPDATA 'npm\dsh.cmd'
$GwUrl     = "http://127.0.0.1:$GatewayPort/"

function Test-Port {
  param([int]$P)
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', $P)
    $c.Close()
    return $true
  } catch { return $false }
}

# HTTP 探测：返回状态码字符串，'000' 表示连不上。
# 任何 HTTP 应答（含 401/303）都说明 HTTP 服务已在监听 = 就绪。
function Probe-Http {
  param([string]$Url)
  $code = & curl.exe -s -o NUL -w "%{http_code}" --max-time 3 $Url 2>$null
  if ($LASTEXITCODE -ne 0 -or $null -eq $code) { return '000' }
  return "$code".Trim()
}

Write-Host ''
Write-Host '  DeepSeek Harness' -ForegroundColor Cyan
Write-Host '  -----------------' -ForegroundColor DarkGray

if (-not (Test-Path $DshCmd)) {
  Write-Host "  找不到 dsh: $DshCmd" -ForegroundColor Red
  Write-Host '  请先安装: npm install -g @deepseek-ai/dsh' -ForegroundColor Yellow
  Write-Host ''
  Read-Host '  按回车关闭'
  exit 1
}
if (-not (Test-Path $GwScript)) {
  Write-Host "  找不到网关脚本: $GwScript" -ForegroundColor Red
  Write-Host ''
  Read-Host '  按回车关闭'
  exit 1
}

# ---------- 第一步：dsh web ----------
$dshStarted = $false
if (Test-Port -P $Port) {
  Write-Host "  dsh web 已在端口 $Port 运行，直接复用。" -ForegroundColor Yellow
} else {
  Write-Host "  正在启动 dsh web（端口 $Port）…" -ForegroundColor Gray
  if (Test-Path $LogPath) { Remove-Item $LogPath -Force -ErrorAction SilentlyContinue }

  $wrapper = Start-Process -FilePath $env:ComSpec `
    -ArgumentList "/c `"`"$DshCmd`" web --host 127.0.0.1 --port $Port --no-open > `"$LogPath`" 2>&1`"" `
    -WindowStyle Hidden -PassThru
  Set-Content -Path $PidPath -Value $wrapper.Id -Encoding ascii
  $dshStarted = $true

  Write-Host '  等待 HTTP 就绪（插件较多，通常 20~40 秒）' -NoNewline
  $deadline = (Get-Date).AddSeconds(180)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 900
    Write-Host '.' -NoNewline
    if ((Probe-Http "http://127.0.0.1:$Port/") -ne '000') { break }
    if ($wrapper.HasExited -and -not (Test-Port -P $Port)) {
      Write-Host ''
      Write-Host '  dsh 启动失败，日志末尾：' -ForegroundColor Red
      if (Test-Path $LogPath) { Get-Content $LogPath -Tail 15 | ForEach-Object { Write-Host "    $_" } }
      Write-Host ''
      Read-Host '  按回车关闭'
      exit 1
    }
  }
  Write-Host ''

  $code = Probe-Http "http://127.0.0.1:$Port/"
  if ($code -eq '000') {
    Write-Host '  超时：dsh 没能就绪。日志末尾：' -ForegroundColor Red
    if (Test-Path $LogPath) { Get-Content $LogPath -Tail 20 | ForEach-Object { Write-Host "    $_" } }
    Write-Host ''
    Read-Host '  按回车关闭'
    exit 1
  }

  # 端口通了再等 3 秒，让插件/连接完成加载，避免浏览器首屏白屏
  Start-Sleep -Seconds 3
  Write-Host "  dsh web 已就绪（HTTP $code）。" -ForegroundColor Green
}

# ---------- 第二步：免登录网关 ----------
if (Test-Port -P $GatewayPort) {
  Write-Host "  网关已在端口 $GatewayPort 运行，直接复用。" -ForegroundColor Yellow
} else {
  Write-Host "  正在启动免登录网关（$Port → $GatewayPort）…" -ForegroundColor Gray
  if (Test-Path $GwLogPath) { Remove-Item $GwLogPath -Force -ErrorAction SilentlyContinue }

  # 网关经环境变量读取端口/上游，子进程会继承当前设置
  $env:DSH_GATEWAY_PORT = "$GatewayPort"
  $env:DSH_UPSTREAM     = "http://127.0.0.1:$Port"
  $gw = Start-Process -FilePath $env:ComSpec `
    -ArgumentList "/c `"node `"$GwScript`" > `"$GwLogPath`" 2>&1`"" `
    -WindowStyle Hidden -PassThru
  Remove-Item Env:DSH_GATEWAY_PORT -ErrorAction SilentlyContinue
  Remove-Item Env:DSH_UPSTREAM -ErrorAction SilentlyContinue

  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline -and -not (Test-Port -P $GatewayPort)) {
    Start-Sleep -Milliseconds 400
  }
  if (-not (Test-Port -P $GatewayPort)) {
    Write-Host '  网关启动失败，日志：' -ForegroundColor Red
    if (Test-Path $GwLogPath) { Get-Content $GwLogPath -Tail 10 | ForEach-Object { Write-Host "    $_" } }
    Write-Host "  （dsh 本身已在运行：http://127.0.0.1:$Port ，但 VS Code 面板需要网关才能免登录）" -ForegroundColor Yellow
    Write-Host ''
    Read-Host '  按回车关闭'
    exit 1
  }
  Write-Host '  网关已就绪。' -ForegroundColor Green
}

# 端口就绪后，把 PID 文件改记真正的 node 监听进程（便于以后排查）。
try {
  if ($dshStarted) {
    $c1 = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c1) { Set-Content -Path $PidPath -Value $c1.OwningProcess -Encoding ascii }
  }
  $c2 = Get-NetTCPConnection -LocalPort $GatewayPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c2) { Set-Content -Path $GwPidPath -Value $c2.OwningProcess -Encoding ascii }
} catch { }

# ---------- 第三步：端到端自检（带重试） ----------
# 网关通了才算数：它会现签 Cookie 转发给 dsh，200 = 全链路免登录可用。
Write-Host '  端到端自检' -NoNewline
$ok = $false
$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
  $code = Probe-Http $GwUrl
  if ($code -eq '200') { $ok = $true; break }
  Start-Sleep -Seconds 2
  Write-Host '.' -NoNewline
}
Write-Host ''
if ($ok) {
  Write-Host '  自检通过：网关 → dsh 链路正常（免登录）。' -ForegroundColor Green
} else {
  Write-Host '  警告：网关自检未通过，面板可能无法加载。' -ForegroundColor Yellow
  Write-Host "  dsh 可能仍在加载插件，可稍后手动确认: $GwUrl" -ForegroundColor DarkGray
}

if (-not $NoBrowser) {
  Write-Host '  正在打开浏览器（免登录入口）…'
  Start-Process $GwUrl
}

Write-Host ''
Write-Host "  浏览器/VS Code 面板地址: $GwUrl" -ForegroundColor Cyan
Write-Host "  日志: $LogPath / $GwLogPath" -ForegroundColor DarkGray
Write-Host ''
Start-Sleep -Seconds 2
exit 0
