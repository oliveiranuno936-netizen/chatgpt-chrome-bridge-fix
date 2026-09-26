<#
.SYNOPSIS
  端到端自检：应用能否列出 Chrome 标签页并读到网址（这是唯一能证明桥接真正可用的检查）。

.DESCRIPTION
  它驱动应用自己的 node_repl 服务（与 agent 走同一条路径）：
    node_repl js 工具 → 浏览器服务 → 应用 browser-use 管道 → 扩展宿主 → Chrome
  静态检查（diagnose 脚本）全过也可能桥接已死，本脚本才能给出结论。

  退出码：0 = 桥接可用（能列出浏览器与标签页）；1 = 桥接不可用；2 = 环境/配置问题

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\check-browser-bridge.ps1
#>
[CmdletBinding()]
param(
  [string] $NodeExe,
  [int]    $Seconds = 90
)

$ErrorActionPreference = 'Stop'

$script = Join-Path $PSScriptRoot 'check-browser-bridge.mjs'
if (-not (Test-Path -LiteralPath $script)) {
  Write-Host "[FAIL] 找不到同目录的 check-browser-bridge.mjs：$script" -ForegroundColor Red
  exit 2
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
  $root = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes'
  if (Test-Path -LiteralPath $root) {
    $found = Get-ChildItem -LiteralPath $root -Filter node.exe -Recurse -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($found) { return $found.FullName }
  }
  return $null
}

try { $node = Resolve-Node -Explicit $NodeExe } catch { Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
if (-not $node) {
  Write-Host "[FAIL] 找不到 node.exe（装 Node.js 或先启动一次 ChatGPT 桌面版）。" -ForegroundColor Red
  exit 2
}

Write-Host "[INFO] node: $node"
& $node $script --seconds $Seconds
$code = $LASTEXITCODE

if ($code -eq 1) {
  Write-Host ""
  Write-Host "处置顺序（由便宜到彻底）：" -ForegroundColor Yellow
  Write-Host "  1) Start-Service seclogon   —— node_repl 的 Windows 沙箱登录依赖它（报 CreateProcessWithLogonW 失败时必做）"
  Write-Host "  2) Start-Service CodexSandboxService.OpenAI.Codex"
  Write-Host "  3) 在 Chrome 的 chrome://extensions 里重新加载 ChatGPT 扩展，然后新开对话重试"
  Write-Host "  4) 完全退出 ChatGPT（只留一个实例）后重开；仍不行则重启电脑清掉僵尸实例与旧管道"
}

exit $code
