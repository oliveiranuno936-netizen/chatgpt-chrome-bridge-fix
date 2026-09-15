<#
.SYNOPSIS
  ChatGPT 连通性自检：判断「ChatGPT 打不开」是隧道 / 出口节点坏了，还是 Cloudflare 挑战。

.DESCRIPTION
  找到本机可用的 node（系统 PATH，或 ChatGPT 桌面版自带的 Node 运行时），把参数转给同目录的
  chatgpt-check.mjs，并把它的退出码原样带出来。只读：只发起网络探测，不写任何文件。

  退出码：0 = 网络链路正常（偶发 Cloudflare 挑战视为正常）
          1 = 隧道 / 出口节点异常，或页面始终打不开
          2 = 参数错误

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\check-chatgpt-connectivity.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\check-chatgpt-connectivity.ps1 -ProxyPort 7890
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\check-chatgpt-connectivity.ps1 -Direct
#>
[CmdletBinding()]
param(
  # 手动指定 node.exe；不指定则自动查找
  [string] $NodeExe,

  # 本地代理地址，形如 127.0.0.1:7890；默认 127.0.0.1:7892
  [string] $Proxy,

  # 只给端口号，等价于 -Proxy 127.0.0.1:<端口>
  [string] $ProxyPort,

  # 不走代理，直连 443（用来确认是「网络封了」还是「代理坏了」）
  [switch] $Direct,

  # 打印 chatgpt-check.mjs 自己的帮助
  [switch] $ShowHelp
)

$ErrorActionPreference = 'Stop'

$script = Join-Path $PSScriptRoot 'chatgpt-check.mjs'
if (-not (Test-Path -LiteralPath $script)) {
  Write-Host "[FAIL] 找不到同目录的 chatgpt-check.mjs：$script" -ForegroundColor Red
  Write-Host "       请把两个文件放在同一个目录下运行。"
  exit 1
}

function Resolve-Node {
  param([string] $Explicit)

  if ($Explicit) {
    if (Test-Path -LiteralPath $Explicit) { return (Get-Item -LiteralPath $Explicit).FullName }
    throw "指定的 node 不存在：$Explicit"
  }

  $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $cmd) { $cmd = Get-Command node -ErrorAction SilentlyContinue }
  if ($cmd) { return $cmd.Source }

  # ChatGPT 桌面版自带 Node 运行时：%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\<hash>\bin\node.exe
  $root = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes'
  if (Test-Path -LiteralPath $root) {
    $found = Get-ChildItem -LiteralPath $root -Filter node.exe -Recurse -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($found) { return $found.FullName }
  }

  return $null
}

try {
  $node = Resolve-Node -Explicit $NodeExe
} catch {
  Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

if (-not $node) {
  Write-Host "[FAIL] 找不到 node.exe。" -ForegroundColor Red
  Write-Host "      两种办法：安装 Node.js（https://nodejs.org），或先启动一次 ChatGPT 桌面版"
  Write-Host "      让它自解压自带运行时，然后用 -NodeExe 指定路径。"
  exit 1
}

$nodeArgs = @($script)
if ($Proxy)     { $nodeArgs += @('--proxy', $Proxy) }
if ($ProxyPort) { $nodeArgs += @('--proxy', $ProxyPort) }
if ($Direct)    { $nodeArgs += '--direct' }
if ($ShowHelp)  { $nodeArgs += '--help' }

Write-Host "[INFO] node: $node"
& $node @nodeArgs
$code = $LASTEXITCODE

exit $code
