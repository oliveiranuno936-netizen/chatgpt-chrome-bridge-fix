<#
    fix-chatgpt-chrome-bridge.ps1

    修复「ChatGPT/Codex 桌面版无法连接到 Chrome / Edge 浏览器扩展桥接」。

    适用场景（本机已确认）：
      Windows 家庭版不支持 EFS，但 ChatGPT 的 MSIX 包文件在
      C:\Program Files\WindowsApps\... 下带 EFS(Encrypted) 属性。
      应用在启动 / 窗口获得焦点时会把内置插件市场从该目录复制到
      ~/.codex/.tmp/bundled-marketplaces/openai-bundled，
      复制必然失败 (Win32 0x80071770 "The specified file could not be encrypted" /
      Node "UNKNOWN: unknown error, copyfile", errno -4094)，
      于是插件解析失败、Chrome 插件被判定不可用。

    修复原理（不改动应用、不改动安装包、完全可逆）：
      应用在刷新前会先算一个 ".materialization-key"，然后检查运行目录是否
      「key 完全一致 + 清单一致 + visualize 技能文件内容与包内一致」；
      三者都满足就直接复用现有副本，跳过那次注定失败的复制。
      本脚本用「读出字节再写入」的方式自己完成那次复制（fs.cp 会因为要求目标也能被加密而失败，
      读+写不会），并按应用代码的字段顺序复刻 key，从而让复用条件成立。

    脚本做四件事：
      1. 截获应用自己写出的「过滤后」市场清单（staging 目录，存在仅几十毫秒）
      2. 用读+写把包内插件市场同步到 staging 目录，写入清单与 key，并在换入前自检复用条件
      3. 关闭 ChatGPT → 换入新目录 → 启动 ChatGPT（startup reconcile 会立刻校验）
      4. 从日志确认是否命中 runtime_marketplace_reused；未命中则换下一组候选参数重来

    应用更新后 key 与包内插件内容都会变化、故障复发，重新运行本脚本即可。

    配套文件（同目录）：
      capture-manifest.mjs                截获应用过滤后的市场清单
      build-marketplace.mjs               用读+写重建运行市场目录并复刻 key
      diagnose-chatgpt-chrome-bridge.ps1  只读诊断，定位卡在哪一环
      README.md                           使用说明
      docs/root-cause.md                  根因证据链
#>
[CmdletBinding()]
param(
    [switch]$Force   # 即使当前状态看起来正常，也重新生成
)

$ErrorActionPreference = 'Stop'

$codexHome   = Join-Path $env:USERPROFILE '.codex'
$dstRoot     = Join-Path $codexHome '.tmp\bundled-marketplaces\openai-bundled'
$workDir     = Join-Path $codexHome '.tmp\codex-browser-bridge-fix'
$captureFile = Join-Path $workDir 'captured-manifest.json'
$buildReport = Join-Path $workDir 'last-build.json'

New-Item -ItemType Directory -Force -Path $workDir | Out-Null

# ---------------------------------------------------------------- environment
$pkg = Get-AppxPackage OpenAI.Codex
if (-not $pkg) { throw 'OpenAI.Codex 未安装，找不到 ChatGPT 桌面版。' }
$srcRoot = Join-Path $pkg.InstallLocation 'app\resources\plugins\openai-bundled'
if (-not (Test-Path $srcRoot)) { throw "找不到内置插件市场源目录：$srcRoot" }
# 日志目录按包族名推导，避免写死包版本目录
$logRoot = Join-Path $env:LOCALAPPDATA "Packages\$($pkg.PackageFamilyName)\LocalCache\Local\Codex\Logs"

$node = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node') -Recurse -Filter node.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
if (-not $node) { throw '找不到应用自带的 node.exe。' }

$captureScript = Join-Path $PSScriptRoot 'capture-manifest.mjs'
$buildScript   = Join-Path $PSScriptRoot 'build-marketplace.mjs'
foreach ($f in @($captureScript, $buildScript)) {
    if (-not (Test-Path $f)) { throw "缺少配套文件：$f（请从项目目录整体运行本脚本）" }
}

# packagedAppVersion = Electron app.getVersion()（内部构建号，形如 26.924.20706）
# 正常情况插件会把 BROWSER_USE_CODEX_APP_VERSION 写进 config.toml；
# 但插件被卸载后该键会一起消失，此时回退读应用自己的全局状态文件（含 appVersion 字段）。
$appVersion = $null
$cfgPath = Join-Path $codexHome 'config.toml'
if (Test-Path $cfgPath) {
    $m = [regex]::Match((Get-Content $cfgPath -Raw -Encoding utf8), 'BROWSER_USE_CODEX_APP_VERSION\s*=\s*[''"]([^''"]+)[''"]')
    if ($m.Success) { $appVersion = $m.Groups[1].Value }
}
if (-not $appVersion) {
    $stateFile = Join-Path $codexHome '.codex-global-state.json'
    if (Test-Path $stateFile) {
        # 该文件里嵌套的 JSON 是转义过的（\"appVersion\":\"...\"），正则要容忍反斜杠
        $m = [regex]::Match((Get-Content $stateFile -Raw -Encoding utf8), '\\?"appVersion\\?"\s*:\s*\\?"([^"\\]+)\\?"')
        if ($m.Success) {
            $appVersion = $m.Groups[1].Value
            Write-Host "注意：config.toml 里没有 BROWSER_USE_CODEX_APP_VERSION（插件可能被卸载），" -ForegroundColor Yellow
            Write-Host "      已从 .codex-global-state.json 回退读到版本号：$appVersion" -ForegroundColor Yellow
        }
    }
}
if (-not $appVersion) { throw '无法确定应用版本号：config.toml 无 BROWSER_USE_CODEX_APP_VERSION，全局状态文件里也没有 appVersion。' }

Write-Host "包目录        : $($pkg.InstallLocation)"
Write-Host "应用版本      : $appVersion"
Write-Host "市场源目录    : $srcRoot"
Write-Host "市场运行目录  : $dstRoot"

# 前提条件提示（不阻断执行）：本修复针对「包文件带 EFS 属性、但本机无法加密目标文件」
$pkgAppDir = Join-Path $pkg.InstallLocation 'app'
if ((Test-Path $pkgAppDir) -and -not (((Get-Item $pkgAppDir -Force).Attributes) -match 'Encrypted')) {
    Write-Host "提示：包内 app 目录未带 EFS 属性，本机可能不存在本脚本针对的那个根因；" -ForegroundColor Yellow
    Write-Host "      建议先运行 diagnose-chatgpt-chrome-bridge.ps1 确认卡点。" -ForegroundColor Yellow
}

# 电脑控制依赖 Codex 沙箱服务：应用更新会让旧版本目录失效，该服务可能已意外终止（退出码 1067），
# 症状是「窗口清单为空 / computer-use helper request failed / nodeRepl.fetch request failed」。
$sandboxSvc = Get-Service -Name 'CodexSandboxService*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($sandboxSvc -and $sandboxSvc.Status -ne 'Running') {
    Write-Host "检测到 $($sandboxSvc.Name) 未运行（$($sandboxSvc.Status)），正在启动（桌面电脑控制需要它）..." -ForegroundColor Yellow
    try {
        Start-Service -Name $sandboxSvc.Name -ErrorAction Stop
        Write-Host "  ✔ 已启动：$((Get-Service -Name $sandboxSvc.Name).Status)" -ForegroundColor Green
    } catch {
        Write-Host "  ✘ 启动失败：$($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "     可手动启动：services.msc 里找到 $($sandboxSvc.Name)，或重启电脑后再试。"
    }
} elseif ($sandboxSvc) {
    Write-Host "沙箱服务      : 正在运行（$($sandboxSvc.Name)）"
}

# node_repl 的 Windows 沙箱用 CreateProcessWithLogonW 创建受限进程，依赖 Secondary Logon 服务。
# 它没在跑时，js / 浏览器 / 电脑控制调用全部失败（nodeRepl.fetch request failed、
# "trusted Node process exited unexpectedly"），而静态检查却都是正常的。
$secSvc = Get-Service -Name 'seclogon' -ErrorAction SilentlyContinue
if ($secSvc -and $secSvc.Status -ne 'Running') {
    Write-Host "检测到 Secondary Logon（seclogon）未运行（$($secSvc.Status)），正在启动（node_repl 沙箱需要它）..." -ForegroundColor Yellow
    try {
        Start-Service -Name 'seclogon' -ErrorAction Stop
        Write-Host "  ✔ 已启动：$((Get-Service -Name 'seclogon').Status)" -ForegroundColor Green
    } catch {
        Write-Host "  ✘ 启动失败：$($_.Exception.Message)（可在 services.msc 里启动 seclogon）" -ForegroundColor Yellow
    }
}

Add-Type -Namespace BridgeFix -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
'@ -ErrorAction SilentlyContinue

function Invoke-FocusChatGpt {
    $chat = Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    # 应用在运行但窗口句柄为 0（窗口已关闭 / 最小化到托盘）时无法用焦点触发，
    # 交给后面的重启路径（kill + 启动 = 必然触发一次 startup reconcile）。
    if (-not $chat) { return $false }
    $other = Get-Process chrome,msedge,explorer -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    [void][BridgeFix.Win]::ShowWindow($chat.MainWindowHandle, 6)     # 最小化
    Start-Sleep -Milliseconds 800
    if ($other) {
        [void][BridgeFix.Win]::SetForegroundWindow($other.MainWindowHandle)
        [void][BridgeFix.Win]::ShowWindow($other.MainWindowHandle, 9)
    }
    Start-Sleep -Milliseconds 800
    [void][BridgeFix.Win]::ShowWindow($chat.MainWindowHandle, 9)     # 还原 -> 重新获得焦点
    Start-Sleep -Milliseconds 400
    [void][BridgeFix.Win]::SetForegroundWindow($chat.MainWindowHandle)
    return $true
}

function Stop-ChatGpt {
    foreach ($p in @(Get-Process ChatGPT -ErrorAction SilentlyContinue)) {
        try {
            $p.Kill()
            [void]$p.WaitForExit(3000)
        } catch {
            # 个别进程权限更高（结束会被拒绝）：不要因此中断整个修复
            Write-Host "      警告：无法结束 ChatGPT 进程 $($p.Id)（$($_.Exception.Message)）" -ForegroundColor Yellow
        }
    }
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Get-Process ChatGPT -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
    if (Get-Process ChatGPT -ErrorAction SilentlyContinue) {
        Write-Host "      注意：仍有 ChatGPT 进程存活，将尝试直接启动新实例来触发 reconcile。" -ForegroundColor Yellow
    }
}

function Start-ChatGpt {
    [void][System.Diagnostics.Process]::Start('explorer.exe', "shell:AppsFolder\$($pkg.PackageFamilyName)!App")
}

function Get-BridgeEvents([datetime]$since, [int]$seconds = 5) {
    if ($seconds -gt 0) { Start-Sleep -Seconds $seconds }
    Get-ChildItem $logRoot -Recurse -File -Filter *.log -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-3) } | ForEach-Object {
        Select-String -Path $_.FullName -Pattern 'runtime_marketplace_reused|marketplace_folder_write_failed|bundled_plugins_reconcile_started' -Encoding utf8
      } | ForEach-Object {
        $ts = [regex]::Match($_.Line, '^(\S+Z)').Groups[1].Value
        if ($ts) {
            $d = [datetime]::Parse($ts).ToUniversalTime()
            if ($d -gt $since) { [regex]::Match($_.Line, '(runtime_marketplace_reused|marketplace_folder_write_failed|bundled_plugins_reconcile_started)').Groups[1].Value }
        }
      }
}

function Get-LatestBridgeEvent([datetime]$since) {
    $rows = @()
    Get-ChildItem $logRoot -Recurse -File -Filter *.log -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-20) } | ForEach-Object {
        Select-String -Path $_.FullName -Pattern 'runtime_marketplace_reused|marketplace_folder_write_failed' -Encoding utf8 | ForEach-Object {
            $ts = [regex]::Match($_.Line, '^(\S+Z)').Groups[1].Value
            if ($ts) {
                $d = [datetime]::Parse($ts).ToUniversalTime()
                if ($d -gt $since) {
                    $rows += [pscustomobject]@{ T = $d; E = [regex]::Match($_.Line, '(runtime_marketplace_reused|marketplace_folder_write_failed)').Groups[1].Value }
                }
            }
        }
      }
    ($rows | Sort-Object T | Select-Object -Last 1).E
}

# 已经修好且非强制 -> 直接退出（只读日志判断，不去打扰应用）
if (-not $Force) {
    $keyPath = Join-Path $dstRoot '.materialization-key'
    if (Test-Path $keyPath) {
        $since = (Get-Date).ToUniversalTime().AddMinutes(-20)
        if ((Get-LatestBridgeEvent $since) -eq 'runtime_marketplace_reused') {
            Write-Host "`n✔ 当前已处于已修复状态（最近一次插件市场物化命中 runtime_marketplace_reused），无需处理。" -ForegroundColor Green
            Write-Host "  强制重新生成请加 -Force。"
            return
        }
    }
}

# ------------------------------------------------- 1) 截获应用自己过滤后的清单
Write-Host "`n[1/4] 截获应用过滤后的市场清单（需要应用处于故障态：key 失配时它才会写 staging）..."
# 不能用 Start-Process：PS 5.1 在环境里同时存在 NO_PROXY / no_proxy 时会抛
# "Item has already been added"，因此直接用 .NET 启动子进程。
$proc = $null
function Start-CaptureWatcher {
    $script:proc = [System.Diagnostics.Process]::Start($node, "`"$captureScript`" `"$(Split-Path $dstRoot)`" `"$captureFile`"")
    Start-Sleep -Seconds 2
}
function Stop-CaptureWatcher {
    if ($script:proc -and -not $script:proc.HasExited) { $script:proc.Kill() }
}

# 截获一次；返回清单文本，失败返回 $null
# （应用会先创建文件、再写内容，读取必须校验内容有效，否则会截获到 0 字节的空文件）
function Get-ManifestCapture {
    Remove-Item $captureFile -Force -ErrorAction SilentlyContinue
    Start-CaptureWatcher                       # 必须先布好监听，应用的 startup reconcile 很早
    for ($i = 0; $i -lt 3 -and -not (Test-Path $captureFile); $i++) { [void](Invoke-FocusChatGpt); Start-Sleep -Seconds 3 }
    if (-not (Test-Path $captureFile)) {
        Write-Host "      触发不到重新物化，重启 ChatGPT 以强制一次 startup reconcile（监听器保持运行）..."
        Stop-ChatGpt
        Start-Sleep -Seconds 3
        Start-ChatGpt
        for ($i = 0; $i -lt 30 -and -not (Test-Path $captureFile); $i++) { Start-Sleep -Seconds 3 }
    }
    Stop-CaptureWatcher
    if (-not (Test-Path $captureFile)) { return $null }
    $text = [System.IO.File]::ReadAllText($captureFile, [Text.Encoding]::UTF8)
    if ($text.Trim().Length -eq 0 -or $text -notmatch '"plugins"') { return $null }
    return $text
}

$capturedText = $null
for ($try = 1; $try -le 3 -and -not $capturedText; $try++) {
    if ($try -gt 1) { Write-Host "      上次截获到的清单无效（空文件或不是清单），重试第 $try 次..." -ForegroundColor Yellow }
    $capturedText = Get-ManifestCapture
}
if (-not $capturedText) { throw "未能截获有效的市场清单（应用可能没有在刷新，先跑诊断脚本第 5 项确认）。" }
Write-Host ("      已截获：" + (Get-Item $captureFile).Length + " 字节")

# ------------------------------------------------- 2~4) 重建运行目录并验证命中
# 候选参数：visualize 变体与音频开关按应用默认值优先（音频开关 = 有 computer-use 插件 && 两个音频环境变量）
$candidates = @(
    @{ lv = 'live-disabled'; audio = '0' },
    @{ lv = 'live-enabled';  audio = '0' },
    @{ lv = 'live-disabled'; audio = '1' },
    @{ lv = 'live-enabled';  audio = '1' }
)

$done = $false
$usedLv = $null
foreach ($c in $candidates) {
    $stagingDir = "$dstRoot.build-$([guid]::NewGuid().ToString('N').Substring(0,8))"

    Write-Host "`n[2/4] 用读+写重建运行市场目录（lv=$($c.lv), audio=$($c.audio)）..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $node $buildScript $srcRoot $captureFile $stagingDir $appVersion $c.lv $c.audio > $buildReport
    $buildExit = $LASTEXITCODE
    $sw.Stop()
    $report = Get-Content $buildReport -Raw | ConvertFrom-Json
    foreach ($p in $report.pluginNames) { Write-Host "      $p" }
    Write-Host ("      同步 $($report.copiedFiles) 个文件，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
    if ($buildExit -ne 0) {
        Write-Host "      ✘ 自检未通过，未换入运行目录（详见 $buildReport）" -ForegroundColor Yellow
        foreach ($k in $report.checks.PSObject.Properties.Name) {
            if (-not $report.checks.$k) { Write-Host "        未通过：$k" -ForegroundColor Yellow }
        }
        Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        continue
    }
    Write-Host "      ✔ 自检通过：key / 清单 / visualize 技能内容 / 插件根 全部与应用的期望一致"

    Write-Host "[3/4] 换入新目录，并让应用立刻做一次 reconcile..."
    Stop-ChatGpt
    try {
        if (Test-Path $dstRoot) { Remove-Item $dstRoot -Recurse -Force }
        Move-Item -LiteralPath $stagingDir -Destination $dstRoot
    } catch {
        throw "换入运行市场目录失败：$($_.Exception.Message)（新目录保留在 $stagingDir）"
    }
    $t0 = (Get-Date).ToUniversalTime()
    Start-ChatGpt

    # 结束不掉应用时（进程权限更高），靠焦点触发它的 reconcile —— 效果与 startup reconcile 等价
    Write-Host "[4/4] 等待应用日志确认是否命中「复用」（最多 60 秒，期间用焦点触发 reconcile）..."
    $ev = @()
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 3
        $ev += Get-BridgeEvents $t0 0
        if ($ev -contains 'runtime_marketplace_reused') { break }
        if ($i % 2 -eq 1) { [void](Invoke-FocusChatGpt) }
    }
    $ev = $ev | Sort-Object -Unique
    Write-Host ("      事件：" + ($ev -join ', '))
    if ($ev -contains 'runtime_marketplace_reused') { $done = $true; $usedLv = "$($c.lv) / audio=$($c.audio)"; break }
}

Write-Host ""
if ($done) {
    Write-Host "[4/4] ✔ 修复成功（$usedLv）：应用已复用现有插件市场，不再尝试那次注定失败的复制。" -ForegroundColor Green
    Write-Host "      运行市场目录内容已同步到当前应用版本（$appVersion），应用会把新插件装进插件缓存。" -ForegroundColor Green
    Write-Host "      现在回到 ChatGPT 里新开一个对话，再让它操作 Chrome（例如「用 Chrome 打开推特」）。" -ForegroundColor Green
    Write-Host "      若诊断脚本第 3 项仍报 native host 缺失，再运行 repair-native-host.ps1 重建桥接。"
    Write-Host "      如需撤销：删除 `"$dstRoot\.materialization-key`" 即可恢复原状。"
    Write-Host "      注意：ChatGPT 每次版本更新后 key 与插件内容都会失配、故障复发，重新运行本脚本即可。"
} else {
    Write-Host "[4/4] ✘ 未命中复用分支。" -ForegroundColor Yellow
    Write-Host "      说明应用构建里的 key 结构或复用校验条件又变了（常见于大版本更新）。"
    Write-Host "      请把这两处内容发给 OpenAI 反馈："
    Write-Host "        - Windows 家庭版无 EFS，而 MSIX 包文件的 Encrypted 属性使 fs.cp 必然失败"
    Write-Host "        - windows-file-copy 的兜底守卫 (e.errno === <常量>) 未覆盖 errno -4094 (UNKNOWN)"
    exit 1
}
