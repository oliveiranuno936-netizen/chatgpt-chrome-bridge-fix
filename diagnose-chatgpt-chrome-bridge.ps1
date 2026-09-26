<#
    diagnose-chatgpt-chrome-bridge.ps1

    只读诊断：查清 ChatGPT/Codex 桌面版「无法连接到 Chrome / Edge 浏览器扩展桥接」
    到底卡在哪一环，以及本机的修复是否仍然有效。

    它检查 6 件事：
      1. ChatGPT 桌面版 MSIX 包是否安装、装在哪个版本目录
      2. 包内文件是否带 EFS(Encrypted) 属性，并实测「复制包内文件」是否失败
         （只在 %TEMP% 下写一个临时文件，用完即删）
      3. 浏览器扩展桥接的本机 native messaging host：清单文件 + 注册表项
      4. Chrome / Edge 里 ChatGPT 扩展是否已安装并启用（调用插件自带的官方检查脚本）
      5. 插件市场「物化」状态：.materialization-key 是否存在、运行目录内容是否与包内一致，
         日志里最后一次是复用成功（runtime_marketplace_reused）还是复制失败（marketplace_folder_write_failed）
      6. 电脑控制辅助服务（Codex 沙箱服务）是否在运行 —— 应用更新后它可能意外终止，
         表现为「窗口清单为空」「computer-use helper request failed」

    全程不修改应用、插件市场、注册表和系统设置。
    退出码：0 = 未发现已知故障；1 = 检测到故障（详见输出）
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

Write-Host "ChatGPT 浏览器桥接诊断" -ForegroundColor White
Write-Host "时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$codexHome = Join-Path $env:USERPROFILE '.codex'
$dstRoot   = Join-Path $codexHome '.tmp\bundled-marketplaces\openai-bundled'

# ----------------------------------------------------------------- 1) 应用包
Sect '1/6 ChatGPT 桌面版安装情况'
$pkg = Get-AppxPackage OpenAI.Codex -ErrorAction SilentlyContinue
if (-not $pkg) {
    Bad '未检测到 OpenAI.Codex（ChatGPT 桌面版 MSIX 包），后续检查无意义'
} else {
    Ok "已安装：$($pkg.Version)"
    Note "包目录：$($pkg.InstallLocation)"
}
$appDir  = if ($pkg) { Join-Path $pkg.InstallLocation 'app' } else { $null }
$srcRoot = if ($appDir) { Join-Path $appDir 'resources\plugins\openai-bundled' } else { $null }
$logRoot = if ($pkg) { Join-Path $env:LOCALAPPDATA "Packages\$($pkg.PackageFamilyName)\LocalCache\Local\Codex\Logs" } else { $null }

# ------------------------------------------------- 2) EFS 加密属性 + 复制实测
Sect '2/6 EFS 加密属性与「复制包内文件」实测'
if ($srcRoot -and (Test-Path $srcRoot)) {
    $appAttr = (Get-Item $appDir -Force).Attributes
    $dirEncrypted = $appAttr -match 'Encrypted'
    if ($dirEncrypted) {
        Warn '包内 app 目录带 EFS(Encrypted) 属性 —— 这是本故障的前提条件'
    } else {
        Ok '包内 app 目录未带 EFS 属性（本修复通常不需要；若确实连不上，请看第 3~5 项）'
    }

    $sample = Join-Path $srcRoot 'plugins\sites\.app.json'
    if (-not (Test-Path $sample)) {
        $sample = Get-ChildItem $appDir -Recurse -File -Force -ErrorAction SilentlyContinue |
                  Select-Object -First 1 -ExpandProperty FullName
    }
    if ($sample) {
        $probe = Join-Path $env:TEMP ("bridge-probe-" + [guid]::NewGuid().ToString('N') + ".json")
        try {
            Copy-Item -LiteralPath $sample -Destination $probe -Force -ErrorAction Stop
            Ok '复制包内文件成功（本机没复现「目标文件无法加密」这个根因条件）'
        } catch {
            # 这是「根因条件」，不是故障本身：只要应用能走复用分支就没事（见第 5 项）
            Warn ("复制包内文件失败：" + $_.Exception.Message)
            Note '这正是应用刷新插件市场时撞到的错误；它是故障的根因条件，本身不代表当前不可用'
        } finally {
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
        }
    } else {
        Warn '找不到可用于复制实测的样本文件'
    }
} else {
    Warn '找不到内置插件市场源目录，跳过本项'
}

# ------------------------------------------------------- 3) native messaging host
Sect '3/6 浏览器扩展桥接（native messaging host）'
$hostName    = 'com.openai.codexextension'
$manifestPath = Join-Path $env:LOCALAPPDATA "OpenAI\extension\$hostName.json"
if (Test-Path $manifestPath) {
    Ok "native host 清单存在：$manifestPath"
    try {
        $mf = Get-Content $manifestPath -Raw | ConvertFrom-Json
        if ($mf.name -eq $hostName) { Ok "清单 name 正确：$($mf.name)" } else { Bad "清单 name 异常：$($mf.name)" }
        if ($mf.path -and (Test-Path $mf.path)) { Ok "清单指向的 extension-host.exe 存在" }
        else { Bad "清单指向的 extension-host.exe 不存在：$($mf.path)" }
        Note ("allowed_origins：" + (($mf.allowed_origins) -join ', '))
    } catch { Bad "清单不是合法 JSON：$($_.Exception.Message)" }
} else {
    Bad "native host 清单缺失：$manifestPath（扩展无法与本机应用通信）"
}

foreach ($b in @(
    @{ Name = 'Chrome'; Key = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension' },
    @{ Name = 'Edge';   Key = 'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.openai.codexextension' }
)) {
    $val = $null
    if (Test-Path $b.Key) { $val = (Get-ItemProperty $b.Key).'(default)' }
    if ($val) { Ok "$($b.Name) 注册表项已登记 -> $val" }
    else { Bad "$($b.Name) 注册表项缺失：$($b.Key)" }
}

# ------------------------------------------------------- 4) 浏览器扩展是否启用
Sect '4/6 Chrome / Edge 里的 ChatGPT 扩展'
$node = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node') -Recurse -Filter node.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
$checker = Get-ChildItem (Join-Path $codexHome 'plugins\cache\openai-bundled\chrome') -Recurse -Filter 'check-extension-installed.js' -ErrorAction SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
if (-not $checker) {
    Warn '找不到插件自带的 check-extension-installed.js（插件缓存可能不完整），跳过本项'
} elseif (-not $node) {
    Warn '找不到应用自带的 node.exe，跳过本项'
} else {
    foreach ($family in @('chrome', 'edge')) {
        $raw = & $node $checker --browser $family --json 2>$null | Out-String
        try {
            $r = $raw | ConvertFrom-Json
            if ($r.installed -and $r.enabled) {
                Ok "$($r.browserName)：扩展已安装并启用（$($r.extensionId) v$(($r.profiles[0].versions) -join ','))"
            } elseif ($r.installed -and -not $r.enabled) {
                Bad "$($r.browserName)：扩展已安装但被禁用"
            } else {
                Bad "$($r.browserName)：未安装 ChatGPT 扩展"
            }
        } catch {
            Warn "$family 检查失败（$($raw.Trim().Split([Environment]::NewLine)[0])）"
        }
    }
}

# ------------------------------------------------------- 5) 插件市场物化状态
Sect '5/6 插件市场「物化」状态'
$keyPath = Join-Path $dstRoot '.materialization-key'
$mfPath  = Join-Path $dstRoot '.agents\plugins\marketplace.json'
if (Test-Path $mfPath) {
    try {
        $mp = Get-Content $mfPath -Raw | ConvertFrom-Json
        Ok "运行市场清单存在，收录 $($mp.plugins.Count) 个插件：$((($mp.plugins | ForEach-Object { $_.name }) -join ', '))"
    } catch { Bad "运行市场清单不是合法 JSON：$($_.Exception.Message)" }
} else {
    Bad "运行市场清单缺失：$mfPath"
}
if (Test-Path $keyPath) { Ok ".materialization-key 存在（$((Get-Item $keyPath).Length) 字节）" }
else { Bad ".materialization-key 缺失（应用会去复制那份加密文件并失败）" }

# 复用条件里还有一条：visualize 技能文件内容必须与包内一致（应用更新后插件内容会变）
if ((Test-Path $mfPath) -and $srcRoot -and (Test-Path $srcRoot)) {
    try {
        $vis = (Get-Content $mfPath -Raw | ConvertFrom-Json).plugins | Where-Object { $_.name -eq 'visualize' } | Select-Object -First 1
        if ($vis) {
            $rel    = ($vis.source.path -replace '^\./', '') -replace '/', '\'
            $srcVis = Join-Path (Join-Path $srcRoot $rel) 'skills\visualize\SKILL.md'
            $dstVis = Join-Path (Join-Path $dstRoot $rel) 'skills\visualize\SKILL.md'
            if ((Test-Path $srcVis) -and (Test-Path $dstVis)) {
                if ((Get-FileHash $srcVis -Algorithm SHA256).Hash -eq (Get-FileHash $dstVis -Algorithm SHA256).Hash) {
                    Ok 'visualize 技能内容与包内一致（复用条件之一）'
                } else {
                    Bad '运行目录里的插件内容已过期（visualize 技能与包内不一致）—— 复用条件不成立，请运行修复脚本'
                }
            } else {
                Warn 'visualize 技能文件缺失，跳过内容一致性检查'
            }
        }
    } catch {
        Warn "内容一致性检查失败：$($_.Exception.Message)"
    }
}

if ($logRoot -and (Test-Path $logRoot)) {
    $rows = @()
    $since = (Get-Date).ToUniversalTime().AddHours(-24)
    Get-ChildItem $logRoot -Recurse -File -Filter *.log -ErrorAction SilentlyContinue | ForEach-Object {
        Select-String -Path $_.FullName -Pattern 'runtime_marketplace_reused|marketplace_folder_write_failed|bundled_plugins_marketplace_resolve_failed|windows_encrypted_copy_fallback_started' -Encoding utf8 |
          ForEach-Object {
            $ts = [regex]::Match($_.Line, '^(\S+Z)').Groups[1].Value
            if ($ts) {
                $d = [datetime]::Parse($ts).ToUniversalTime()
                if ($d -gt $since) {
                    $rows += [pscustomobject]@{ T = $d; E = [regex]::Match($_.Line, '(runtime_marketplace_reused|marketplace_folder_write_failed|bundled_plugins_marketplace_resolve_failed|windows_encrypted_copy_fallback_started)').Groups[1].Value }
                }
            }
          }
    }
    $reuse   = @($rows | Where-Object { $_.E -eq 'runtime_marketplace_reused' })
    $failed  = @($rows | Where-Object { $_.E -eq 'marketplace_folder_write_failed' })
    $resolve = @($rows | Where-Object { $_.E -eq 'bundled_plugins_marketplace_resolve_failed' })
    $fallbk  = @($rows | Where-Object { $_.E -eq 'windows_encrypted_copy_fallback_started' })

    Note ("近 24 小时：复用成功 $($reuse.Count) 次，复制失败 $($failed.Count) 次，解析失败 $($resolve.Count) 次，加密复制兜底触发 $($fallbk.Count) 次")
    $last = $rows | Sort-Object T | Select-Object -Last 1
    if ($last) {
        Note "最后一次事件：$($last.T.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')) $($last.E)"
        if ($last.E -eq 'runtime_marketplace_reused') { Ok '最近一次物化走的是「复用」分支 —— 修复当前有效' }
        else { Bad '最近一次物化没有走「复用」分支 —— 故障仍然存在，请运行 fix-chatgpt-chrome-bridge.ps1' }
    } else {
        Warn '近 24 小时内没有相关日志（应用可能没运行或被清理过）'
    }
} else {
    Warn "找不到应用日志目录：$logRoot"
}

# ------------------------------------------- 6) 电脑控制辅助服务（Codex 沙箱服务）
Sect '6/6 电脑控制辅助服务（Codex 沙箱服务）'
$sandboxSvc = Get-Service -Name 'CodexSandboxService*' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $sandboxSvc) {
    Note '未找到 Codex 沙箱服务（本机可能没启用桌面电脑控制，不影响浏览器桥接）'
} elseif ($sandboxSvc.Status -eq 'Running') {
    Ok "服务正在运行：$($sandboxSvc.Name)"
} else {
    Bad "服务未运行（$($sandboxSvc.Status)）：桌面电脑控制会报「窗口清单为空 / computer-use helper request failed」—— 运行 fix-chatgpt-chrome-bridge.ps1 会自动启动它"
}

# ------------------------------------------------------------------- 结论
Write-Host ""
if ($script:problems.Count -eq 0) {
    Write-Host "结论：未发现已知故障。" -ForegroundColor Green
    exit 0
} else {
    Write-Host "结论：检测到 $($script:problems.Count) 处问题：" -ForegroundColor Red
    $i = 1
    foreach ($p in $script:problems) { Write-Host "  $i) $p"; $i++ }
    Write-Host ""
    Write-Host "修复方式：powershell -ExecutionPolicy Bypass -File .\fix-chatgpt-chrome-bridge.ps1" -ForegroundColor Yellow
    exit 1
}
