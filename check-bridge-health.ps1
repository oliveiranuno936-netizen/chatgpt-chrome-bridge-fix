<#
    check-bridge-health.ps1

    一键自检：ChatGPT 桌面版 ↔ Chrome 浏览器桥接的「运行时健康」。
    与 diagnose-chatgpt-chrome-bridge.ps1 的区别：
      diagnose 查的是「配置/文件/日志」是否正确；
      本脚本查的是「运行时是否处于可用状态」——实例是否唯一、管道是否干净、
      扩展宿主是否已连上、沙箱服务是否在跑。用于重启后、或每次重连失败时快速定位。

    只读：不修改任何东西。退出码 0 = 运行时健康，1 = 存在会阻断桥接的问题。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$script:problems = @()

function Sect([string]$t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Bad([string]$m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:problems += $m }
function Warn([string]$m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Note([string]$m) { Write-Host "  [ -- ] $m" }

Write-Host "ChatGPT 浏览器桥接运行时自检" -ForegroundColor White
Write-Host "时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# ------------------------------------------------------------------ 1) 实例唯一性
Sect '1/5 ChatGPT 实例（必须唯一，多个实例会互相抢管道）'
$all      = @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue)
$byStart  = $all | Group-Object { $_.CreationDate } | Sort-Object Name
$roots    = @($all | Where-Object { $_.CreationDate -lt (Get-Date).AddHours(-2) })
$windowed = @(Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
Write-Host ("  [ -- ] 进程 $($all.Count) 个，有窗口的实例 $($windowed.Count) 个")
if ($windowed.Count -gt 1) { Bad "有多个带窗口的实例 —— 请完全退出 ChatGPT 后只开一个" }
elseif ($windowed.Count -eq 1) { Ok "只有一个带窗口的实例（正常的单实例状态）" }
else { Warn "没有带窗口的实例（ChatGPT 可能没在运行；桥接需要它运行）" }

# 比当前实例代（最新进程时间 -5 分钟）更早的进程 = 上次运行留下的僵尸
$newestStart = ($all | Sort-Object CreationDate -Descending | Select-Object -First 1).CreationDate
$zombies = @($all | Where-Object { $newestStart -and $_.CreationDate -lt $newestStart.AddMinutes(-5) })
if ($zombies.Count -gt 0) {
    # 旧代进程不一定致命（实测桥接仍可用），但会占着浏览器管道，建议重启清掉
    Warn "检测到 $($zombies.Count) 个旧代进程（会占着浏览器管道，重启电脑可清）：" +
        (($zombies | Sort-Object CreationDate | Select-Object -First 3 | ForEach-Object { "pid=$($_.ProcessId)@$($_.CreationDate.ToString('HH:mm:ss'))" }) -join ', ')
} else {
    Ok "没有发现上轮遗留的僵尸实例"
}

# ------------------------------------------------------------------ 2) 管道
Sect '2/5 浏览器管道（宿主按名字前缀找管道，残留旧管道会让它连错目标）'
$pipes = @([System.IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -match 'codex-browser-use' })
Write-Host ("  [ -- ] codex-browser-use 管道 $($pipes.Count) 条")
$pipes | Sort-Object | ForEach-Object { Write-Host "        $_" }
if ($pipes.Count -gt 6) { Bad "管道过多（$($pipes.Count) 条）—— 通常意味着还有旧实例占着管道" }
else { Ok "管道数量正常（单实例通常 1~6 条，每次浏览器会话新增一条）" }
$dash  = @($pipes | Where-Object { $_ -match 'codex-browser-use-' })
$slash = @($pipes | Where-Object { $_ -match 'codex-browser-use\\' })
Write-Host ("  [ -- ] '-<guid>' 形式 $($dash.Count) 条；'\<guid>' 形式 $($slash.Count) 条（两种都存在说明有多轮实例的特征）")

# ------------------------------------------------------------------ 3) 扩展宿主
Sect '3/5 扩展宿主进程（Chrome 在扩展请求时拉起，连上应用才有桥接）'
$hosts = @(Get-Process extension-host -ErrorAction SilentlyContinue)
if ($hosts.Count -eq 0) {
    Warn '当前没有 extension-host.exe —— 浏览器任务发起时 Chrome 会拉起它'
} else {
    Ok "extension-host.exe $($hosts.Count) 个；最近启动 " + (($hosts | Sort-Object StartTime -Descending | Select-Object -First 1).StartTime.ToString('HH:mm:ss'))
}
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
Write-Host ("  [ -- ] 系统上次启动：$($boot.ToString('yyyy-MM-dd HH:mm:ss'))（宿主启动时间早于它是不可能的；宿主明显早于最近一次修复则可能是陈旧连接）")

# ------------------------------------------------------------------ 4) 沙箱服务
Sect '4/5 电脑控制辅助服务（Codex 沙箱服务）'
$svc = Get-Service -Name 'CodexSandboxService*' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $svc) { Note '未找到该服务（本机可能没启用桌面电脑控制）' }
elseif ($svc.Status -eq 'Running') { Ok "服务正在运行：$($svc.Name)（$($svc.StartType)）" }
else { Bad "服务未运行（$($svc.Status)）：Start-Service $($svc.Name) 即可启动（无需管理员）" }

# node_repl 沙箱用 CreateProcessWithLogonW，依赖 Secondary Logon；它没跑时 js/浏览器调用全失败
$sec = Get-Service -Name 'seclogon' -ErrorAction SilentlyContinue
if (-not $sec) { Note '未找到 seclogon 服务' }
elseif ($sec.Status -eq 'Running') { Ok 'Secondary Logon（seclogon）正在运行 —— node_repl 沙箱登录的前提' }
else { Bad "Secondary Logon（seclogon）未运行（$($sec.Status)）：js/浏览器/电脑控制会报 CreateProcessWithLogonW failed —— Start-Service seclogon" }

# ------------------------------------------------------------------ 5) 静态配置 + 最近一次物化
Sect '5/5 静态配置与最近一次插件市场物化'
$manifest = Join-Path $env:LOCALAPPDATA 'OpenAI\extension\com.openai.codexextension.json'
if (Test-Path $manifest) { Ok 'native host 清单存在' } else { Bad "native host 清单缺失：$manifest（跑 repair-native-host.ps1）" }
foreach ($k in @('HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension',
                 'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.openai.codexextension')) {
    if (Test-Path $k) { Ok "注册表项存在：$($k.Split('\')[-1]) @ $($k.Split('\')[2])" } else { Bad "注册表项缺失：$k（跑 repair-native-host.ps1）" }
}

$pfn = (Get-AppxPackage OpenAI.Codex -ErrorAction SilentlyContinue).PackageFamilyName
if ($pfn) {
    $logRoot = Join-Path $env:LOCALAPPDATA "Packages\$pfn\LocalCache\Local\Codex\Logs"
    $rows = @()
    Get-ChildItem $logRoot -Recurse -File -Filter *.log -ErrorAction SilentlyContinue | ForEach-Object {
        Select-String -Path $_.FullName -Pattern 'runtime_marketplace_reused|marketplace_folder_write_failed' -Encoding utf8 | ForEach-Object {
            $ts = [regex]::Match($_.Line, '^(\S+Z)').Groups[1].Value
            if ($ts) { $rows += [pscustomobject]@{ T = [datetime]::Parse($ts).ToUniversalTime(); E = [regex]::Match($_.Line, '(runtime_marketplace_reused|marketplace_folder_write_failed)').Groups[1].Value } }
        }
    }
    $last = $rows | Sort-Object T | Select-Object -Last 1
    if ($last) {
        Note "最近一次物化：$($last.T.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))  $($last.E)"
        if ($last.E -eq 'runtime_marketplace_reused') { Ok '插件市场走的是「复用」分支 —— 前提条件良好' }
        else { Bad '插件市场最近一次是「复制失败」—— 先跑 fix-chatgpt-chrome-bridge.ps1' }
    } else { Note '近段时间没有插件市场日志（应用可能没运行过）' }
}

# ------------------------------------------------------------------ 结论
Write-Host ""
if ($script:problems.Count -eq 0) {
    Write-Host "结论：运行时健康，桥接具备可用条件。" -ForegroundColor Green
    Write-Host "      若浏览器任务仍报 nodeRepl.fetch request failed：在 chrome://extensions 重新加载 ChatGPT 扩展后，新开对话重试。" -ForegroundColor Gray
    exit 0
} else {
    Write-Host "结论：检测到 $($script:problems.Count) 处会阻断桥接的问题：" -ForegroundColor Red
    $i = 1
    foreach ($p in $script:problems) { Write-Host "  $i) $p"; $i++ }
    Write-Host ""
    Write-Host "按提示处理后重跑本脚本；配置类问题用 fix-chatgpt-chrome-bridge.ps1 / repair-native-host.ps1。" -ForegroundColor Yellow
    exit 1
}
