<#
    fix-chatgpt-chrome-bridge.ps1

    修复「ChatGPT/Codex 桌面版无法连接到 Chrome / Edge 浏览器扩展桥接」。

    适用场景（本机已确认）：
      Windows 家庭版不支持 EFS，但 ChatGPT 的 MSIX 包文件在
      C:\Program Files\WindowsApps\... 下带 EFS(Encrypted) 属性。
      应用每次获得焦点都会把内置插件市场从该目录复制到
      ~/.codex/.tmp/bundled-marketplaces/openai-bundled，
      复制必然失败 (Win32 0x80071770 "The specified file could not be encrypted" /
      Node "UNKNOWN: unknown error, copyfile", errno -4094)，
      于是插件解析失败、Chrome 插件被判定不可用。

    修复原理（不改动应用、不改动安装包、完全可逆）：
      应用在 vne() 里计算一个 ".materialization-key"；若
      ~/.codex/.tmp/bundled-marketplaces/openai-bundled/.materialization-key
      的内容与该 key 完全一致、且该目录下的
      .agents/plugins/marketplace.json 与应用的过滤结果一致，
      应用就直接「复用」现有市场副本，完全跳过那次注定失败的复制。

    脚本做三件事：
      1. 截获应用自己写出的「过滤后」市场清单（staging 目录，存在仅几十毫秒）
      2. 把该清单装入市场根目录，并按应用代码的字段顺序复刻 .materialization-key
      3. 重启应用触发 startup reconcile，从日志确认是否命中 runtime_marketplace_reused；
         若未命中则自动改用另一个 visualize variant 再试

    应用更新后 key 会失配、故障复发，重新运行本脚本即可（需要 ChatGPT 处于运行状态）。

    配套文件（同目录）：
      diagnose-chatgpt-chrome-bridge.ps1  只读诊断，定位卡在哪一环
      README.md                           使用说明
      docs/root-cause.md                  根因证据链与应用侧代码位置
#>
[CmdletBinding()]
param(
    [switch]$Force   # 即使当前状态看起来正常，也重新生成
)

$ErrorActionPreference = 'Stop'

$codexHome  = Join-Path $env:USERPROFILE '.codex'
$dstRoot    = Join-Path $codexHome '.tmp\bundled-marketplaces\openai-bundled'
$workDir    = Join-Path $codexHome '.tmp\codex-browser-bridge-fix'
$captureFile = Join-Path $workDir 'captured-manifest.json'

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

# packagedAppVersion = Electron app.getVersion()；应用自己把它写进了 config.toml
$appVersion = (Select-String -Path (Join-Path $codexHome 'config.toml') -Pattern '^BROWSER_USE_CODEX_APP_VERSION\s*=\s*"([^"]+)"' |
               Select-Object -First 1).Matches.Groups[1].Value
if (-not $appVersion) { throw '无法从 config.toml 读取 BROWSER_USE_CODEX_APP_VERSION。' }

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

Add-Type -Namespace BridgeFix -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
'@ -ErrorAction SilentlyContinue

# PowerShell 5.1 的 Set-Content -Encoding UTF8 会写入 BOM，会破坏 .mjs / key 文件
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-FocusChatGpt {
    $chat = Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $chat) { throw 'ChatGPT 未在运行：本修复需要它处于运行状态以触发 reconcile。' }
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
}

function Get-BridgeEvents([datetime]$since, [int]$seconds = 5) {
    Start-Sleep -Seconds $seconds
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
$captureScript = Join-Path $workDir 'capture-manifest.mjs'
$captureCode = @'
import fs from "node:fs";
import path from "node:path";
const parent = process.argv[2];
const out = process.argv[3];
const deadline = Date.now() + 300000;
function attempt() {
  let entries = [];
  try { entries = fs.readdirSync(parent); } catch { return false; }
  for (const name of entries) {
    if (!/^openai-bundled\.staging-/.test(name)) continue;
    const manifest = path.join(parent, name, ".agents", "plugins", "marketplace.json");
    let fd;
    try { fd = fs.openSync(manifest, "r"); } catch { continue; }
    const buf = fs.readFileSync(fd, "utf8");
    fs.writeFileSync(out, buf, "utf8");
    console.log("captured " + buf.length + " bytes from " + name);
    return true;
  }
  return false;
}
const watcher = fs.watch(parent, () => { if (attempt()) { watcher.close(); process.exit(0); } });
const iv = setInterval(() => {
  if (attempt()) { clearInterval(iv); watcher.close(); process.exit(0); }
  if (Date.now() > deadline) { clearInterval(iv); watcher.close(); console.error("timeout"); process.exit(2); }
}, 5);
'@
Write-Utf8NoBom $captureScript $captureCode

Write-Host "`n[1/3] 截获应用过滤后的市场清单（需要应用处于故障态：key 失配时会尝试复制）..."
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
function Restart-ChatGpt {
    Write-Host "      触发不到重新物化，重启 ChatGPT 以强制一次 startup reconcile（监听器保持运行）..."
    Get-Process ChatGPT -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
    [void][System.Diagnostics.Process]::Start('explorer.exe', "shell:AppsFolder\$($pkg.PackageFamilyName)!App")
    Start-Sleep -Seconds 2
}

Remove-Item $captureFile -Force -ErrorAction SilentlyContinue
Start-CaptureWatcher                       # 必须先布好监听，应用的 startup reconcile 很早
for ($i = 0; $i -lt 3 -and -not (Test-Path $captureFile); $i++) { Invoke-FocusChatGpt; Start-Sleep -Seconds 3 }
if (-not (Test-Path $captureFile)) {
    Restart-ChatGpt
    for ($i = 0; $i -lt 30 -and -not (Test-Path $captureFile); $i++) { Start-Sleep -Seconds 3 }
}
Stop-CaptureWatcher
if (-not (Test-Path $captureFile)) { throw "未能截获应用的市场清单。" }
Write-Host ("      已截获：" + (Get-Content $captureFile -Raw).Length + " 字节")

# ------------------------------------------------- 2) 写入清单与 materialization key
$writeScript = Join-Path $workDir 'write-key.mjs'
$writeCode = @'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
const [src, dst, captured, appVersion, cuVariant, lvVariant] = process.argv.slice(2);
const capturedText = fs.readFileSync(captured, "utf8");
fs.writeFileSync(path.join(dst, ".agents", "plugins", "marketplace.json"), capturedText, "utf8");
const manifest = JSON.parse(capturedText);
const plugins = manifest.plugins.map((p) => {
  const pj = JSON.parse(fs.readFileSync(path.join(src, p.source.path, ".codex-plugin", "plugin.json"), "utf8"));
  return { name: pj.name, version: pj.version };
}).sort((a, b) => a.name.localeCompare(b.name));
const vis = manifest.plugins.find((p) => p.name === "visualize");
let visualizeSkillContentHash;
if (vis && fs.existsSync(path.join(src, vis.source.path, "skills", "visualize", "SKILL.md"))) {
  visualizeSkillContentHash = crypto.createHash("sha256")
    .update(fs.readFileSync(path.join(src, vis.source.path, "skills", "visualize", "SKILL.md"), "utf8")).digest("hex");
}
const cu = cuVariant === "null" ? null : cuVariant;
const lv = lvVariant === "null" ? null : lvVariant;
const key = JSON.stringify({
  version: 1,
  appVersion,
  bundleId: fs.readFileSync(path.join(src, ".bundle-id"), "utf8").trim(),
  marketplaceName: "openai-bundled",
  computerUseSkillVariant: cu,
  computerUseAudioEnabled: cu !== "legacy-mcp" && plugins.some((p) => p.name === "computer-use") && false,
  liveVisualizationSkillVariant: lv,
  ...(visualizeSkillContentHash === undefined ? {} : { visualizeSkillContentHash }),
  plugins,
});
fs.writeFileSync(path.join(dst, ".materialization-key"), key + "\n", "utf8");
console.log("manifest plugins: " + plugins.length + " | lv: " + lv);
'@
Write-Utf8NoBom $writeScript $writeCode

Write-Host "`n[2/3] 写入市场清单与 materialization key，并重启应用验证（focus 触发不可靠，用 startup reconcile）..."
$done = $false
$usedLv = $null
foreach ($lv in @('live-disabled', 'live-enabled')) {
    & $node $writeScript $srcRoot $dstRoot $captureFile $appVersion 'null' $lv | Write-Host
    $t0 = (Get-Date).ToUniversalTime()
    Restart-ChatGpt
    $ev = @()
    for ($i = 0; $i -lt 18; $i++) {
        Start-Sleep -Seconds 3
        $ev += Get-BridgeEvents $t0 0
        if ($ev -contains 'runtime_marketplace_reused') { break }
        if ($ev -contains 'marketplace_folder_write_failed') { break }
    }
    $ev = $ev | Sort-Object -Unique
    Write-Host ("      事件：" + ($ev -join ', '))
    if ($ev -contains 'runtime_marketplace_reused') { $done = $true; $usedLv = $lv; break }
}

Write-Host ""
if ($done) {
    Write-Host "[3/3] ✔ 修复成功（visualize variant = $usedLv）：应用已复用现有插件市场，不再尝试那次注定失败的复制。" -ForegroundColor Green
    Write-Host "      现在回到 ChatGPT 里重新下达一次 Chrome 操作（例如「打开推特」）即可。" -ForegroundColor Green
    Write-Host "      如需撤销：删除 `"$dstRoot\.materialization-key`" 即可恢复原状。"
    Write-Host "      注意：ChatGPT 每次版本更新后 key 都会失配、故障复发，重新运行本脚本即可。"
} else {
    Write-Host "[3/3] ✘ 未命中复用分支。" -ForegroundColor Yellow
    Write-Host "      说明应用构建里的 key 结构又有变化（常见于大版本更新），或者市场清单过滤规则变了。"
    Write-Host "      请把这两处内容发给 OpenAI 反馈："
    Write-Host "        - Windows 家庭版无 EFS，而 MSIX 包文件的 Encrypted 属性使 fs.cp 必然失败"
    Write-Host "        - windows-file-copy 的兜底守卫 (e.errno === <常量>) 未覆盖 errno -4094 (UNKNOWN)"
    exit 1
}
