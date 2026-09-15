<#
    repair-native-host.ps1

    重建 ChatGPT/Codex 桌面版与 Chrome / Edge 之间的 native messaging host 桥接：
      - %LOCALAPPDATA%\OpenAI\extension\com.openai.codexextension.json   （native host 清单）
      - HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension
      - HKCU\Software\Microsoft\Edge\NativeMessagingHosts\com.openai.codexextension
      - <插件缓存>\chrome\<版本>\extension-host\windows\x64\extension-host-config.json

    适用场景：扩展在浏览器里已安装启用，但应用一直报「无法连接到 Chrome 的浏览器扩展桥接」，
    诊断脚本第 3 项报清单/注册表缺失或失效时使用。

    事实来源（都取自本机应用自身，不写死在脚本里）：
      - 扩展 ID   <- 插件缓存里的 scripts/extension-ids.json
      - 应用版本  <- ~/.codex/config.toml 的 BROWSER_USE_CODEX_APP_VERSION
      - codex/node/node_repl 路径 <- ~/.codex/config.toml 的 [mcp_servers.node_repl] 段

    脚本是幂等的：内容已正确时重复运行只会重写同样的内容。
    只写 HKCU 与 %LOCALAPPDATA%，不需要管理员权限，不改动应用安装包。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

$codexHome = Join-Path $env:USERPROFILE '.codex'
$cfgPath   = Join-Path $codexHome 'config.toml'
if (-not (Test-Path $cfgPath)) { throw "找不到 $cfgPath（ChatGPT 桌面版至少需要运行过一次）。" }
$cfg = Get-Content $cfgPath -Raw

# ------------------------------------------------------------ 定位插件缓存
$chromeRoot = Join-Path $codexHome 'plugins\cache\openai-bundled\chrome'
if (-not (Test-Path $chromeRoot)) { throw "找不到 chrome 插件缓存：$chromeRoot（请在应用里重新安装 Browser/Chrome 插件）。" }
# 应用自己物化成功时会把 native host 指向 chrome\latest（junction 到当前版本目录），
# 所以优先用它（跨插件版本仍有效）；没有 latest 时回退到最新的版本目录。
$latestDir = Join-Path $chromeRoot 'latest'
if (Test-Path (Join-Path $latestDir 'extension-host\windows\x64\extension-host.exe')) {
    $verDir = Get-Item $latestDir -Force
    Write-Host "使用应用维护的 latest 别名（junction）指向当前插件版本"
} else {
    $verDir = Get-ChildItem $chromeRoot -Directory -Force |
              Where-Object { $_.Name -ne 'latest' } |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $verDir) { throw "chrome 插件缓存里没有版本目录：$chromeRoot" }
    Write-Host "未发现 latest 别名，改用最新版本目录 $($verDir.Name)"
}
$hostExe = Join-Path $verDir.FullName 'extension-host\windows\x64\extension-host.exe'
$browserClient = Join-Path $verDir.FullName 'scripts\browser-client.mjs'
$idsFile = Join-Path $verDir.FullName 'scripts\extension-ids.json'
foreach ($f in @($hostExe, $browserClient, $idsFile)) {
    if (-not (Test-Path $f)) { throw "插件缓存不完整，缺少：$f" }
}

# ------------------------------------------------------------ 收集扩展 ID
$idsJson = Get-Content $idsFile -Raw | ConvertFrom-Json
$ids = New-Object System.Collections.Generic.List[string]
foreach ($i in @($idsJson.extensionIds)) { if ($i) { $ids.Add([string]$i) } }
foreach ($be in @($idsJson.browserExtensions)) {
    foreach ($i in @($be.extensionIds)) { if ($i) { $ids.Add([string]$i) } }
    if ($be.storeExtensionId) { $ids.Add([string]$be.storeExtensionId) }
}
$ids = @($ids | Sort-Object -Unique)
if ($ids.Count -eq 0) { throw "未能从 $idsFile 解析出任何扩展 ID。" }

# ------------------------------------------------------------ config.toml 取值
function Get-CfgValue([string]$pattern, [string]$what) {
    $m = [regex]::Match($cfg, $pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $m.Success) { throw "无法从 config.toml 读取 $what（模式：$pattern）。" }
    $m.Groups[1].Value
}
$appVersion = Get-CfgValue '(?m)^BROWSER_USE_CODEX_APP_VERSION\s*=\s*"([^"]+)"' 'BROWSER_USE_CODEX_APP_VERSION'
$codexCli   = Get-CfgValue "CODEX_CLI_PATH\s*=\s*'([^']+)'"              'CODEX_CLI_PATH'
$nodePath   = Get-CfgValue "NODE_REPL_NODE_PATH\s*=\s*'([^']+)'"         'NODE_REPL_NODE_PATH'
$nodeRepl   = Get-CfgValue "(?s)\[mcp_servers\.node_repl\].*?command\s*=\s*'([^']+)'" 'mcp_servers.node_repl command'

Write-Host "插件缓存      : $($verDir.Name)"
Write-Host "扩展 ID       : $($ids -join ', ')"
Write-Host "应用版本      : $appVersion"

# ------------------------------------------------------------ 1) native host 清单
$manifestPath = Join-Path $env:LOCALAPPDATA 'OpenAI\extension\com.openai.codexextension.json'
New-Item -ItemType Directory -Force -Path (Split-Path $manifestPath) | Out-Null
$manifest = [ordered]@{
    allowed_origins = @($ids | ForEach-Object { "chrome-extension://$_/" })
    description     = 'ChatGPT browser native messaging host'
    name            = 'com.openai.codexextension'
    path            = $hostExe
    type            = 'stdio'
}
Write-Utf8NoBom $manifestPath ($manifest | ConvertTo-Json -Depth 5)
Write-Host "[1/4] 已写入 native host 清单：$manifestPath"

# ------------------------------------------------------------ 2) 注册表项
foreach ($b in @(
    @{ Name = 'Chrome'; Key = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension' },
    @{ Name = 'Edge';   Key = 'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.openai.codexextension' }
)) {
    New-Item -Path $b.Key -Force | Out-Null
    Set-ItemProperty -Path $b.Key -Name '(default)' -Value $manifestPath
    Write-Host "[2/4] 已登记 $($b.Name) native messaging host 注册表项"
}

# ------------------------------------------------------------ 3) 桥接程序配置
$configPath = Join-Path (Split-Path $hostExe) 'extension-host-config.json'
$hostCfg = [ordered]@{
    schemaVersion   = 1
    channel         = 'prod'
    browserClientPath = $browserClient
    codexCliPath    = $codexCli
    nodePath        = $nodePath
    nodeReplPath    = $nodeRepl
    proxyHost       = '127.0.0.1'
    proxyPort       = 0
}
Write-Utf8NoBom $configPath ($hostCfg | ConvertTo-Json -Depth 5)
Write-Host "[3/4] 已写入桥接程序配置：$configPath"

# ------------------------------------------------------------ 4) 用官方脚本自检
$checker = Join-Path $verDir.FullName 'scripts\check-native-host-manifest.js'
$node = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node') -Recurse -Filter node.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
if ((Test-Path $checker) -and $node) {
    $raw = & $node $checker --json 2>$null | Out-String
    try {
        $res = $raw | ConvertFrom-Json
        if ($res.correct) {
            Write-Host "[4/4] ✔ 官方自检通过：native host 清单与注册表项均正确（correct=true）" -ForegroundColor Green
        } else {
            Write-Host "[4/4] ✘ 官方自检未通过，请运行 diagnose-chatgpt-chrome-bridge.ps1 查看细节" -ForegroundColor Yellow
            exit 1
        }
    } catch {
        Write-Host "[4/4] 自检输出无法解析，跳过（不影响已写入的配置）" -ForegroundColor Yellow
    }
} else {
    Write-Host "[4/4] 未找到官方自检脚本或 node.exe，跳过自检"
}

Write-Host ""
Write-Host "完成。若浏览器已开着，完全退出 Chrome / Edge 后重开，再让 ChatGPT 操作浏览器。" -ForegroundColor Green
Write-Host "回滚：删除 `"$manifestPath`" 与上述两个注册表项即可。" -ForegroundColor Gray
