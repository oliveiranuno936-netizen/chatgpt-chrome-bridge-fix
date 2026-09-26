# ChatGPT 浏览器桥接修复（ChatGPT/Codex 桌面版 × Chrome/Edge）

一套用于修复「**ChatGPT 桌面版无法连接到 Chrome / Edge 浏览器扩展桥接**」的诊断与修复脚本。
不改应用安装包、不改 `app.asar`、不需要管理员权限，全部操作可回滚。

**当前版本**：v0.3.3（2026-09-26；更新内容见 [CHANGELOG.md](CHANGELOG.md)）

> 适用前提：本机确实存在下面这个根因条件 —— ChatGPT 的 MSIX 包文件带 **EFS(Encrypted)** 属性，
> 而本机**不具备加密文件的能力**（典型：Windows 家庭版不支持 EFS）。诊断脚本第 2 项会告诉你是否成立。

---

## 1. 项目解决什么问题

### 症状

在 ChatGPT 桌面版里让它操作 Chrome（例如"打开推特"），得到这样的回答：

> Chrome 已安装，但 Codex 无法连接到 Chrome 的浏览器扩展桥接。
> 请在 ChatGPT/Codex 的「设置 → Computer use」中重新安装 Browser 插件，并确认 Chrome 扩展已启用。

此时按提示去做（重装扩展、按 UI 重装 Browser 插件、重启浏览器、重启应用）**都不会成功**。
用户侧能观察到的其它现象还包括浏览器工具栏里的 ChatGPT 扩展明明"已安装且已启用"。

### 根因（本机实测，详见 [docs/root-cause.md](docs/root-cause.md)）

1. `C:\Program Files\WindowsApps\OpenAI.Codex_<版本>_…\app` 下的 **5514/5514 个文件带 EFS 加密属性**，
   而本机是 Windows 家庭版，`cipher /e` 直接返回 `The request is not supported.`（**无 EFS 能力**）。
2. 应用在**窗口获得焦点 / 启动**时都会刷新内置插件市场：把应用包里的插件目录复制到
   `~/.codex/.tmp/bundled-marketplaces/openai-bundled`。复制会保留加密属性，因此要求目标文件也能被加密，
   于是**必然失败**：Win32 `0x80071770`（The specified file could not be encrypted）、
   Node 侧表现为 `UNKNOWN: unknown error, copyfile`（errno −4094）。
3. 应用其实准备了"读出来再写"的降级复制路径，但它的触发条件与实际返回的错误码不匹配 →
   **降级从未生效**（全部日志中该事件出现 0 次，而这条路径本身实测是可行的）。
4. 结果：刷新失败 → 应用判定"内置插件不可用" → 浏览器相关插件被停用 →
   于是提示"无法连接到浏览器扩展桥接，请重新安装插件" —— 而重装走的是同一条刷新路径，同样失败。
5. 该失败在本机日志中最早可追到 2026-09-01，更早的应用版本（26.901.x）也报同样的错 →
   不是某次更新引入的回归，而是长期存在的环境性问题。

### 修复思路

应用在刷新前会先检查：用户目录里是否存在**与当前版本、当前插件集合相匹配的缓存标记**。
若匹配，它就**直接复用现有副本**，完全不进入那次必然失败的复制。

本项目的修复脚本所做的，就是补齐让该缓存命中所需的两样东西：

- **应用自己过滤后的插件清单**（应用会按当前平台与功能可用性过滤内置插件，本机为 8 个插件）；
- **与该清单匹配的缓存标记文件**。

随后重启应用一次，确认缓存命中（日志出现"复用现有市场"事件）。

---

## 2. 主要功能

| 文件 | 作用 | 会修改什么 |
| --- | --- | --- |
| `diagnose-chatgpt-chrome-bridge.ps1` | **只读诊断**：6 项检查定位卡点，输出中文可读报告；退出码 `0`=未发现已知故障，`1`=检测到故障 | 仅在 `%TEMP%` 写 1 个临时文件做"复制包内文件"实测，用完即删 |
| `fix-chatgpt-chrome-bridge.ps1`（配套 `capture-manifest.mjs`、`build-marketplace.mjs`） | **主修复**：截获应用自己写出的插件清单 → 用**「读出字节再写入」**的方式把包内插件市场同步到运行目录（应用自己的复制因 EFS 必然失败）→ 复刻缓存标记 → 换入并重启验证命中；换入前先自检三项复用条件；并确保电脑控制辅助服务（`CodexSandboxService`）在运行；退出码 `0`=修复成功，`1`=未命中 | 重建 `~/.codex/.tmp/bundled-marketplaces/openai-bundled/`（含插件文件，约 85 MB）；把 ChatGPT 重启 1~4 次 |
| `repair-native-host.ps1` | **重建扩展桥接**：写 native messaging host 清单、Chrome/Edge 两个注册表项、桥接程序配置，并用插件自带的官方自检脚本复核（通过时输出 `correct=true`）；幂等 | 写 `%LOCALAPPDATA%\OpenAI\extension\` 与 `HKCU\Software\{Google\Chrome,Microsoft\Edge}\NativeMessagingHosts\` |
| `check-chatgpt-connectivity.ps1`（入口）+ `chatgpt-check.mjs`（主体） | **网络侧自检**：4 项检查判断"打不开"是**隧道 / 出口节点**坏了还是 **Cloudflare 挑战**；退出码 `0`=链路正常，`1`=链路异常，`2`=参数错误 | 不修改任何东西（只发起网络探测） |
| `docs/root-cause.md` | 根因记录：环境事实、失败链路、证据所在位置与取证方法、建议反馈给应用厂商的问题 | — |

诊断脚本的 6 项检查：

1. ChatGPT 桌面版 MSIX 包是否安装、版本与包目录
2. 包内 `app` 目录是否带 EFS 属性，并**实测**复制包内文件是否失败
3. 扩展桥接（native messaging host）：清单文件、清单指向的桥接程序、Chrome/Edge 注册表项
4. Chrome / Edge 里 ChatGPT 扩展是否已安装并启用（调用插件自带的官方检查脚本）
5. 插件市场刷新状态：缓存标记文件是否存在、运行清单收录了哪些插件、**运行目录里的插件内容是否与包内一致**
   （应用更新后内容会过期，这也是复用条件之一）、近 24 小时事件统计，
   以及**最后一次**刷新是"复用成功"还是"复制失败"
6. 电脑控制辅助服务（`CodexSandboxService`）是否在运行 —— 它是桌面电脑控制用来拉起辅助进程的；
   应用更新后该服务可能意外终止（退出码 `1067`），症状是**窗口清单为空**、
   `computer-use helper request failed`、`nodeRepl.fetch request failed`

连通性自检的 4 项检查（走本地代理，逐项实测而不是"ping 一下"）：

1. 隧道本身：能否通过本地代理 `CONNECT` 到 `chatgpt.com:443` 并完成 TLS 握手（`--direct` 时改为直连 443）
2. ChatGPT 依赖的 10 个域名逐个握手：`chatgpt.com`、`ab.chatgpt.com`、`cdn.oaistatic.com`、
   `cdn.openai.com`、`files.oaiusercontent.com`、`ws.chatgpt.com`、`auth.openai.com`、
   `api.openai.com`、`challenges.cloudflare.com`、`openai.com`
3. 出口节点：读 `chatgpt.com/cdn-cgi/trace`，显示实际出口 IP、归属地与 Cloudflare 机房
4. 真实页面加载 ×10（间隔 1.2 秒）：统计 `HTTP 200` / Cloudflare 挑战 / 硬失败各几次，
   用来区分"隧道不稳"和"出口 IP 被重点标记"

它的输出是**英文 ASCII**（Windows 控制台默认代码页 936 会把 Node 输出的 UTF-8 中文变成乱码，故刻意如此）。
它回答的是"网络这条链路通不通"，**不涉及**本项目的 EFS 根因；两者配合使用可快速分清"网络问题"还是"应用问题"。

---

## 3. 使用方法

### 3.1 环境要求

- Windows 10 / 11；用系统自带的 **Windows PowerShell 5.1** 即可（脚本是 UTF-8 带 BOM，中文不会乱码；不依赖 PowerShell 7）
- 已安装 **ChatGPT 桌面版**（Microsoft Store 的 MSIX 包 `OpenAI.Codex`），且**至少启动过一次**
  （脚本要从 `~/.codex/config.toml` 读取应用自己写入的版本号与运行时路径）
- 修复脚本要求 ChatGPT 处于**运行状态**（它需要让应用触发一次刷新）
- 连通性自检（3.9）需要 node：装了 Node.js（18+）就用系统的；没装则自动使用 ChatGPT 桌面版自带的
  Node 运行时（前提是应用成功启动过一次）
- 不需要管理员权限：只写当前用户的 `HKCU`、`%LOCALAPPDATA%`、`%USERPROFILE%\.codex`

### 3.2 第 1 步：先诊断

```powershell
cd <项目目录>
powershell -ExecutionPolicy Bypass -File .\diagnose-chatgpt-chrome-bridge.ps1
```

输出示例（已修复状态，脚本原样输出）：

```
== 5/5 插件市场「物化」状态
  [ OK ] 运行市场清单存在，收录 8 个插件：codex-app-tools, sites, browser, …
  [ OK ] .materialization-key 存在（694 字节）
  [ -- ] 近 24 小时：复用成功 7 次，复制失败 80 次，解析失败 80 次，加密复制兜底触发 0 次
  [ -- ] 最后一次事件：2026-09-15 12:20:06 runtime_marketplace_reused
  [ OK ] 最近一次物化走的是「复用」分支 —— 修复当前有效

结论：未发现已知故障。
```

说明：

- 第 2 项报 `[WARN] 复制包内文件失败：The specified file could not be encrypted.` 是**正常的**：
  它是根因条件，不代表当前不可用（判定"当前是否可用"看第 5 项）。
- 退出码：`0` 未发现已知故障，`1` 检测到故障。

### 3.3 第 2 步：若第 3 项报缺失，先重建桥接

```powershell
powershell -ExecutionPolicy Bypass -File .\repair-native-host.ps1
```

它会用本机应用自身的数据（插件缓存里的扩展 ID 数据文件、`config.toml` 里的版本与运行时路径）
写出清单 / 注册表项 / 桥接配置，然后用插件自带的官方自检脚本确认 `correct=true`。脚本幂等，可反复运行。

- 退出码：`0` 成功（含官方自检通过）；`1` 官方自检未通过（需要跑诊断脚本看细节）
- 若插件缓存里存在应用自己维护的"当前版本别名"（junction），脚本优先使用它，
  这样跨插件版本依然有效；没有则回退到最新的版本目录

> 只影响当前用户（`HKCU` + `%LOCALAPPDATA%`）。若浏览器正开着，完全退出 Chrome / Edge 后重开。

### 3.4 第 3 步：修插件市场刷新（主修复）

```powershell
powershell -ExecutionPolicy Bypass -File .\fix-chatgpt-chrome-bridge.ps1
```

做的事情与耗时：

1. `[1/4]` 挂文件监听器，等应用写出**临时市场清单**（该目录只存在几十毫秒）并截获它；
   若应用暂时不再刷新，脚本会**重启一次 ChatGPT** 强制触发（监听器保持运行）
2. `[2/4]` 用**「读出字节再写入」**的方式把包内插件市场完整同步到暂存目录
   （应用自己的 `fs.cp` 会要求目标文件也能被加密而失败，读+写不会），写入清单与缓存标记，
   并在换入前**自检应用的三项复用条件**（标记内容、清单、visualize 技能内容）
3. `[3/4]` 关闭 ChatGPT → 换入新目录 → 重新启动；若 ChatGPT 是提权启动、结束不掉，
   则改为**用焦点触发一次 reconcile**（与启动时的 reconcile 等价）
4. `[4/4]` 检查日志是否出现"复用现有市场"事件（最多等 60 秒，期间反复触发）；未命中则换下一组内部参数重来（共 4 组候选）
5. 全过程通常 **1~2 分钟**（同步约 800 个文件 / 85 MB，实测 1~5 秒；其余花在应用重启上）

成功输出（脚本原样输出）：

```
[4/4] ✔ 修复成功（visualize variant = live-disabled）：应用已复用现有插件市场，不再尝试那次注定失败的复制。
```

同步插件内容还有一个好处：应用随后会把**当前版本**的插件装进
`~/.codex/plugins/cache/openai-bundled/`（浏览器/Chrome 插件不会停在旧版本，
`chrome\latest` 也会指向新版本，native host 清单正是通过它找到桥接程序）。

参数与退出码：

| 项 | 说明 |
| --- | --- |
| `-Force` | 即使当前看起来已修好，也重新生成一遍 |
| 退出码 `0` | 修复成功；或检测到"当前已处于已修复状态"，直接退出（只读日志判断，不打扰应用） |
| 退出码 `1` | 4 组候选参数都没命中 —— 说明应用构建里缓存标记的组成或复用校验条件又变了，需要重新分析（见"已知限制"） |

脚本会在 `%USERPROFILE%\.codex\.tmp\codex-browser-bridge-fix\` 留下工作文件
（`captured-manifest.json` = 截获到的应用清单，`last-build.json` = 最近一次构建与自检结果），便于排查。

### 3.5 第 4 步：回到 ChatGPT 验证

**新开一个对话**再让它操作浏览器（例如"用 Chrome 打开推特"）。
沿用旧对话时，那一轮的工具状态是缓存的，可能仍报旧错。

### 3.6 ChatGPT 更新之后

应用更新会同时改变**版本号、各插件版本与插件内容**（缓存标记的组成也可能变）→ 复用条件失配 → 故障复发。
此时**重新运行第 3 步即可**，脚本会把插件内容一并同步到新版本：

```powershell
powershell -ExecutionPolicy Bypass -File .\fix-chatgpt-chrome-bridge.ps1
```

先用第 1 步的诊断确认是否复发：第 5 项会给出"复用成功 / 复制失败"以及"插件内容是否过期"的中文结论，
并列出近 24 小时的失败次数。

### 3.7 回滚

| 脚本 | 回滚方式 |
| --- | --- |
| `fix-chatgpt-chrome-bridge.ps1` | 按修复脚本结束时打印的路径，删除运行市场目录里的**缓存标记文件**（删除后应用会回到"重新复制并失败"的原始状态） |
| `repair-native-host.ps1` | 删除 `%LOCALAPPDATA%\OpenAI\extension\com.openai.codexextension.json` 与 `HKCU\Software\{Google\Chrome,Microsoft\Edge}\NativeMessagingHosts\com.openai.codexextension` |
| `diagnose-…` | 无需回滚（只读 + 一个临时文件） |

### 3.8 常见问题

| 现象 | 处理 |
| --- | --- |
| 脚本报 `OpenAI.Codex 未安装` | 本工具面向 Microsoft Store 版 ChatGPT 桌面版；未安装则无从修复 |
| 脚本报找不到应用自带的 `node.exe` | 应用数据不完整，先启动一次 ChatGPT 让它自解压运行时 |
| 脚本报读不到应用版本号（`config.toml` 里没有） | ChatGPT 至少需要成功启动过一次 |
| 脚本报 `未能截获应用的市场清单` | ChatGPT 没在运行，或它当前**没有**在刷新（即当前其实已经好了）。先跑诊断脚本第 5 项确认 |
| 脚本报 `[3/3] ✘ 未命中复用分支` | 应用大版本更新改变了缓存标记的组成或清单过滤规则。先跑诊断脚本第 5 项看最后一次刷新结果 |
| 修完还是连不上 | 跑诊断脚本：若第 3 项 `[FAIL]` → 用 `repair-native-host.ps1`；若第 4 项 `[FAIL]` → 在浏览器扩展页里启用 ChatGPT 扩展；若第 5 项最后一次是失败 → 回到第 3 步 |
| 诊断第 5 项报「插件内容已过期」 | 应用更新后运行目录里的插件还是旧版本 → 直接回到第 3 步，修复脚本会同步到当前版本 |
| 窗口清单能看到 Chrome，但**读不到网址**、报 `nodeRepl.fetch request failed` | 扩展的后台/原生端口休眠或陈旧（诊断第 4 项会列出 `extension-host.exe` 的启动时间）→ 在 Chrome 的 `chrome://extensions` 里把 ChatGPT 扩展**「重新加载」**，然后**新开对话**重试；必要时完全退出 Chrome 再打开 |
| 诊断第 3 项报 native host 清单 / Chrome 注册表项缺失 | 应用更新或安装流程可能把桥接清掉 → 跑 `repair-native-host.ps1`（官方自检通过会输出 `correct=true`），再复检 |
| 诊断第 6 项报「服务未运行」/ 窗口清单为空 / `helper request failed` / `nodeRepl.fetch request failed` | 电脑控制辅助服务被应用更新搞挂了 → 跑第 3 步（修复脚本会自动启动它），或手动：`Start-Service CodexSandboxService.OpenAI.Codex`（也可在 services.msc 里启动） |
| 修复脚本报「无法结束 ChatGPT 进程（Access is denied）」 | 应用是提权启动的（子进程同样提权）。脚本不会中断，会改用焦点触发 reconcile；更干净的做法是在任务管理器里结束全部 ChatGPT 进程后重开，再跑第 3 步 |
| 浏览器卡在「Just a moment…」/「请稍候…」、页面反复刷新 | 通常与桥接无关：跑 3.9 的连通性自检，若 `Cloudflare challenged` 偏高 → 换一个标记更少的节点 |

### 3.9 网络侧自检（可选，用来分清「网络问题」还是「应用问题」）

```powershell
powershell -ExecutionPolicy Bypass -File .\check-chatgpt-connectivity.ps1
```

参数：

| 参数 | 说明 |
| --- | --- |
| `-ProxyPort 7890` | 代理端口不是默认的 `7892` 时指定 |
| `-Proxy 127.0.0.1:7890` | 直接给 `host:port` |
| `-Direct` | 不走代理、直连 `:443`：用来确认"是网络封了"还是"代理坏了" |
| `-NodeExe <路径>` | 手动指定 `node.exe` |
| `-ShowHelp` | 打印底层 `chatgpt-check.mjs` 的帮助（也可直接 `node chatgpt-check.mjs`） |

输出示例（健康状态，脚本原样输出）：

```
=== ChatGPT connectivity self-check ===
mode proxy 127.0.0.1:7892

[1/4] local proxy
  OK  127.0.0.1:7892                 reachable, TLS TLSv1.3

[2/4] domains ChatGPT depends on
  OK  chatgpt.com                    118ms  cn=chatgpt.com
  OK  ab.chatgpt.com                 96ms  cn=*.chatgpt.com
  ...

[3/4] exit node
  OK  egress ip                      203.0.113.7  loc=US  colo=LAX  warp=off

[4/4] page load x10 (detects intermittent failures)
  +  +  +  +  +  +  +  +  +  +

  OK  real page (HTTP 200)           10/10
  OK  cloudflare challenge           0/10
  OK  hard failures                  0/10

=== VERDICT ===
Everything is healthy: proxy, all ChatGPT domains, exit node, and real page load.
```

怎么读结论：

| 输出 | 含义 | 处理 |
| --- | --- | --- |
| `the local proxy is NOT usable` | 代理没起来，或它的节点挂了 | 重启加速器，等它显示"已连接"后重跑 |
| `Tunnel is broken for: …` | 部分域名握手失败 | 换节点 / 换线路 |
| `drops or resets requests intermittently` | 隧道不稳（偶发失败） | 换节点 / 换线路 |
| `Cloudflare challenged N/10` 且 `N > 3` | 链路通，但出口 IP 被 Cloudflare 重点标记（机房 IP） | 换住宅 / 低标记节点 —— 这正是"浏览器卡在 请稍候…"的常见原因 |
| `Everything is healthy` | 网络链路没问题 | 问题在应用侧：先跑第 1 步诊断，或按 3.6 重跑修复脚本 |

退出码：`0` = 链路正常（偶发 Cloudflare 挑战视为正常），`1` = 链路异常，`2` = 参数写错。

---

## 目录结构

```
chatgpt-chrome-bridge-fix/
├─ README.md                          本文件
├─ CHANGELOG.md                       更新日志（版本记录）
├─ LICENSE                            MIT 许可证
├─ diagnose-chatgpt-chrome-bridge.ps1 只读诊断（6 项检查，退出码 0/1）
├─ fix-chatgpt-chrome-bridge.ps1      主修复（读+写同步插件市场并复刻缓存标记）
├─ capture-manifest.mjs               截获应用过滤后的市场清单（主修复调用）
├─ build-marketplace.mjs              读+写重建运行市场目录并复刻缓存标记（主修复调用）
├─ repair-native-host.ps1             重建 native messaging host 桥接（幂等，含官方自检）
├─ check-chatgpt-connectivity.ps1      网络侧自检入口（自动查找 node 并转发参数）
├─ chatgpt-check.mjs                   网络侧自检主体（Node，无第三方依赖）
└─ docs/
   └─ root-cause.md                   根因记录：环境事实、失败链路与取证方法
```

## 已知限制

- **不是万能修复**：只针对上面那条 EFS 根因。网络/代理、账号登录、扩展被浏览器策略禁用、
  插件缓存缺失等其它原因导致的"连不上"，本项目不做处理（诊断脚本会把它们分别标出来）。
- **依赖应用内部实现**：缓存标记的组成、复用校验条件、插件清单的过滤规则与日志事件名都取自当前应用版本
  （已验证到 `26.924.1866.0` / 插件 `26.924.20706`）。应用大版本更新后可能失效 ——
  脚本会明确报"未命中复用分支"，而不是静默"假装修好"。已经适配过两次机制变化：
  v0.3.0 补上了新出现的展示开关字段与"技能文件内容必须与包内一致"的要求，
  v0.3.1 跟进新构建**删掉 `computerUseSkillVariant` 字段**的改动。
- **应用更新还可能顺手清掉扩展桥接**：若诊断第 3 项报 native host 清单或 Chrome 注册表项缺失，
  跑 `repair-native-host.ps1` 重建即可（这一步与插件市场是两件独立的事）。
- **修复会重建运行市场目录**（约 85 MB，位于 `~/.codex/.tmp/bundled-marketplaces/`）：
  它是用「读+写」把包内插件复制出来的，因此会占磁盘；删掉该目录或其中的缓存标记即可回滚。
- **电脑控制辅助服务需要单独留意**：`CodexSandboxService` 的可执行文件位于带版本号的 MSIX 包目录里，
  应用更新后旧目录被替换，服务可能意外终止（退出码 `1067`）。修复脚本会把它启动起来，
  但"崩溃后自动重启"需要在管理员权限下配置（`sc failure`）—— 普通用户权限会被拒绝。
- **修复脚本会重启 ChatGPT** 1~4 次（读取清单与逐组参数验证都需要应用配合）。
- **连通性自检依赖本地代理**：默认按 `127.0.0.1:7892` 探测（常见的混合端口），端口不同请用
  `-ProxyPort` 指定；它只回答"链路通不通"，不判断账号状态、地区限制与浏览器扩展是否启用。
- **不改应用本体**：不修改 `WindowsApps` 下的安装包、不修改 `app.asar`、不需要管理员权限。
- 本项目是本地修复工具，与 OpenAI 无隶属关系；应用侧真正的修复建议见
  [docs/root-cause.md](docs/root-cause.md) 最后一节。

## 许可证

本项目（脚本与文档）以 [MIT License](LICENSE) 发布，Copyright (c) 2026 sqh。

该许可仅覆盖本目录下的脚本与文档，**不涉及** OpenAI、ChatGPT、Codex 的商标、应用本体及其安装包 ——
本项目不修改也不分发它们，只是在本机读写应用自身的运行时数据。
