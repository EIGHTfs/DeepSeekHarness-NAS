<#
connect-local.ps1 —— 在 Windows 上建立到 NAS 的 SSH 本地转发，用于「浏览器登录（OAuth）」。

为什么要它：DeepSeekRuntime 的浏览器登录只接受回环来源
  （http://localhost:<端口> / http://127.0.0.1:<端口> / http://[::1]:<端口>），
  直接访问 http://<NAS-IP>:<反代端口> 点登录会被平台拒绝；把端口转发到本机回环后，
  地址栏是 127.0.0.1，登录就能正常完成授权。日常不登录时用 API Key 即可，不需要本脚本。

用法（PowerShell）:
  .\connect-local.ps1 -NasHost <NAS-IP>
  .\connect-local.ps1 -NasHost <NAS-IP> -NasUser root -SshPort 22 -LocalPort 31800

参数:
  -NasHost    NAS 局域网地址（必填）
  -NasUser    SSH 用户，默认 root
  -SshPort    SSH 端口，默认 22
  -LocalPort  本机端口，缺省 = 从目标机读到的反代端口（被占用时换一个，例如 31800）
  -RemoteProxy      远端反代端口，缺省从目标机读取
  -RemoteContainer  远端容器页端口，缺省从目标机读取
  -NoBrowser  只建隧道、不自动打开浏览器

结束：按 Enter 断开隧道。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$NasHost,
  [string]$NasUser = 'root',
  [int]$SshPort = 22,
  [int]$LocalPort = 0,        # 0 = 用从目标机读到的反代端口（本机被占用时显式指定别的）
  [int]$RemoteProxy = 0,      # 0 = 从目标机读取
  [int]$RemoteContainer = 0,  # 0 = 从目标机读取
  [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
  Write-Host '✗ 本机没有 ssh 客户端：Windows 10/11 可在「设置 → 应用 → 可选功能」安装 OpenSSH 客户端' -ForegroundColor Red
  exit 1
}

function Test-LocalPortBusy([int]$Port) {
  # TcpListener.Start 是判断端口占用的稳妥方式（Test-NetConnection 在部分版本上慢且依赖网络栈状态）
  try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    $listener.Stop()
    return $false
  } catch {
    return $true
  }
}

# 端口发现：从目标机已装套件的 ports 文件读取，不写死在脚本里。
# 端口文件随版本目录变化 → 扫描 /var/packages/*/var/*/ports 与 target/var/ports，取第一个含 PROXY_PORT 的。
if ($RemoteProxy -eq 0 -or $RemoteContainer -eq 0) {
  Write-Host "→ 从 $NasUser@$NasHost 读取端口…"
  $remoteCmd = 'for f in /var/packages/*/var/*/ports /var/packages/*/target/var/ports; do [ -f "$f" ] || continue; if grep -q "^PROXY_PORT=" "$f" 2>/dev/null; then grep -E "^(PROXY_PORT|CONTAINER_PORT)=" "$f"; exit 0; fi; done; exit 1'
  $discovered = & ssh -p $SshPort -o BatchMode=yes -o ConnectTimeout=8 "$NasUser@$NasHost" $remoteCmd 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $discovered) {
    Write-Host '✗ 读不到目标机端口：请确认套件已安装，或用 -RemoteProxy/-RemoteContainer 显式指定' -ForegroundColor Red
    exit 1
  }
  $proxyLine = ($discovered | Select-String '^PROXY_PORT=').Line
  $containerLine = ($discovered | Select-String '^CONTAINER_PORT=').Line
  if ($RemoteProxy -eq 0)     { $RemoteProxy = [int]($proxyLine -replace '^PROXY_PORT=', '') }
  if ($RemoteContainer -eq 0) { $RemoteContainer = if ($containerLine) { [int]($containerLine -replace '^CONTAINER_PORT=', '') } else { $RemoteProxy } }
  Write-Host "  反代端口=$RemoteProxy 容器页端口=$RemoteContainer"
}
if ($LocalPort -eq 0) { $LocalPort = $RemoteProxy }

if (Test-LocalPortBusy $LocalPort) {
  Write-Host "✗ 本机 $LocalPort 已被占用" -ForegroundColor Red
  Write-Host "  → 换端口重试：.\connect-local.ps1 -NasHost $NasHost -LocalPort 31800" -ForegroundColor Yellow
  exit 1
}

$containerLocal = $LocalPort + 2
$sshArgs = @(
  '-N', '-T',
  '-o', 'ExitOnForwardFailure=yes',
  '-o', 'ServerAliveInterval=30',
  '-p', "$SshPort",
  '-L', "${LocalPort}:127.0.0.1:${RemoteProxy}",
  '-L', "${containerLocal}:127.0.0.1:${RemoteContainer}",
  "${NasUser}@${NasHost}"
)

Write-Host "→ 建立隧道：127.0.0.1:$LocalPort → $NasHost`:$RemoteProxy（经 $NasUser@$NasHost`:$SshPort）"
$sshProcess = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs -PassThru -WindowStyle Hidden

try {
  $ready = $false
  for ($i = 0; $i -lt 40; $i++) {
    if ($sshProcess.HasExited) {
      Write-Host '✗ SSH 隧道没能建立（连接被拒、或需要密码/密钥）。' -ForegroundColor Red
      Write-Host "  排错：先手动执行 ssh -p $SshPort $NasUser@$NasHost 确认能登录成功。" -ForegroundColor Yellow
      exit 1
    }
    if (Test-LocalPortBusy $LocalPort) { $ready = $true; break }
    Start-Sleep -Milliseconds 500
  }
  if (-not $ready) {
    Write-Host "✗ 等待超时：$LocalPort 没有就绪" -ForegroundColor Red
    exit 1
  }

  $url = "http://127.0.0.1:$LocalPort/"
  Write-Host "✓ 隧道就绪：$url（容器页：http://127.0.0.1:$containerLocal/）" -ForegroundColor Green
  Write-Host '  登录完成后不要关掉本窗口；按 Enter 结束隧道。'

  if (-not $NoBrowser) { Start-Process $url | Out-Null }

  Read-Host '按 Enter 断开隧道' | Out-Null
} finally {
  if ($sshProcess -and -not $sshProcess.HasExited) {
    Stop-Process -Id $sshProcess.Id -Force -ErrorAction SilentlyContinue
    Write-Host '已断开隧道'
  }
}
