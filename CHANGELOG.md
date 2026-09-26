# 更新日志

本项目的版本记录，版本号与 GitHub 上的 tag / Release 一一对应。

## v0.4.0 — 2026-09-26

**新增两个自检脚本（其中一个是唯一能证明桥接可用的检查）**

- `check-browser-bridge.mjs` + `check-browser-bridge.ps1` —— **端到端自检**：驱动应用自己的
  `node_repl` 服务（与 agent 完全同一条路径：node_repl js 工具 → 浏览器服务 → 应用 browser-use 管道 →
  扩展宿主 → Chrome），列出浏览器、标签页与 URL。静态检查全过而桥接已死很常见，只有它能给出结论。
  退出码 `0` = 桥接可用，`1` = 不可用，`2` = 环境问题。
- `check-bridge-health.ps1` —— **运行时健康自检**：实例唯一性（含"旧代"残留进程）、浏览器管道数量、
  扩展宿主、Codex 沙箱服务 + Secondary Logon、静态配置与最近一次物化。退出码 `0` = 运行时健康。

**本次真正卡住的根因：node_repl 的 Windows 沙箱依赖 Secondary Logon（seclogon）**

- 现象：所有浏览器/电脑控制调用失败，报 `nodeRepl.fetch request failed` 或
  `trusted Node process exited unexpectedly`；`node_repl` 的 stderr 是
  `windows sandbox failed: CreateProcessWithLogonW failed: 1056`。
- 原因：node_repl 用 `CreateProcessWithLogonW` 创建受限的 JS 执行进程，该 API 依赖
  **Secondary Logon（seclogon）**；它没在跑时沙箱起不来，于是**每一次** js 调用都失败，
  而所有静态检查（插件、清单、注册表、扩展）都正常。
- 处置：`Start-Service seclogon`（普通权限即可）。`diagnose` 第 6 项与 `fix` 现在都会检查它。

**另一条根因：复用条件一旦不成立，应用会把自己的浏览器插件卸载掉**

- 市场解析失败（EFS 复制失败）时，应用会把"不在内置清单里"的插件**逐个卸载**：browser、chrome、
  computer-use、unified-computer-use；随后 native host 清单、Chrome 注册表项、插件缓存目录
  （`~/.codex/plugins/cache/openai-bundled/chrome`）以及 config.toml 里插件写入的
  `[mcp_servers.node_repl]` 段（连带 `BROWSER_USE_CODEX_APP_VERSION`）都会消失。
- 因此修复顺序必须是：**先让"复用"命中**（阻止卸载），改好的状态会被应用自己重建
  （实测：重启后 startup reconcile 命中 `runtime_marketplace_reused`，插件与配置自动恢复）。
- 附带修正：`fix` 读取应用版本号增加回退路径（config.toml → `.codex-global-state.json` 的
  `appVersion`），因为插件被卸载后 config.toml 里的键会消失。

**僵尸实例与死管道（本次靠重启解决）**

- 同一台机器上会同时活着多个 ChatGPT 实例，每个实例占一条 `codex-browser-use` 管道；宿主按名字前缀
  找管道时可能连到旧实例的死管道 → 列标签页卡 21 秒 → 应用因"无法确定当前网址"停止电脑操作。
- 这类旧实例普通权限与提权都无法结束，**只能重启电脑**。实测：重启前 7 条管道 + 3 个僵尸实例；
  重启后 2 条管道、单实例，桥接随即恢复。

**实测证据（2026-09-26 16:10 前后）**

- `check-browser-bridge.ps1`：`browsers=[{"id":"1","type":"extension","family":"chrome"}]`、
  `tabs=[{id:"2059983772", title:"抖音开放平台 - 抖音小程序、字节小程序、头条小程序",
  url:"https://developer.open-douyin.com/"}]`，退出码 `0`
- `diagnose-chatgpt-chrome-bridge.ps1`：6 项全过，退出码 `0`
- `check-bridge-health.ps1`：运行时健康，退出码 `0`

## v0.3.3 — 2026-09-26

**新增：把"扩展宿主"这一环纳入诊断，并记录典型症状**

- 症状：桌面电脑控制的**窗口清单能看到 Chrome（标题正确）**，但读取页面时被应用拦下
  （"could not determine the current browser URL ... enough confidence to enforce policy"），
  浏览器调用报 `nodeRepl.fetch request failed`（实测每次卡 21 秒后失败）。
- 机制：应用此时**已经认出**一个 Chrome 扩展浏览器（`backend=chrome browserID=n`），
  但请求"列出标签页"会超时 → 拿不到当前网址 → 安全策略要求必须知道网址，于是主动停止电脑操作。
  根因是扩展的**后台服务/原生消息端口处于休眠或陈旧**状态（典型 MV3 行为）。
- 处置：在 Chrome 的 `chrome://extensions` 里把 ChatGPT 扩展**「重新加载」**（唤醒后台、重建原生端口），
  然后**新开一个对话**重试；必要时完全退出 Chrome 再打开。
- `diagnose-chatgpt-chrome-bridge.ps1`：第 4 项现在会报告 `extension-host.exe` 的数量与最近启动时间，
  并直接给出上述"重新加载扩展"的处置提示。

## v0.3.2 — 2026-09-26

**新增失效模式：应用更新会让电脑控制辅助服务意外终止**

- 症状（来自用户侧）：让它操作 Chrome 时**窗口清单为空**，读取浏览器状态返回
  `nodeRepl.fetch request failed`（应用侧的真实文案是 `computer-use helper request failed`），
  于是整个电脑控制不可用 —— 但此时**浏览器桥接与插件市场其实都是好的**（诊断 1~5 项全过）。
- 根因：`CodexSandboxService.OpenAI.Codex` 处于 **Stopped，退出码 `1067`**（进程意外终止）。
  该服务的可执行文件位于带版本号的 MSIX 包目录
  （`...\WindowsApps\OpenAI.Codex_<版本>_x64__<hash>\app\resources\codex-windows-sandbox-service.exe`），
  应用更新替换包目录后旧路径失效，服务就再没起来。桌面电脑控制拉起辅助进程要靠它，
  所以表现为「窗口清单为空 / helper request failed」。
- 修复：`Start-Service CodexSandboxService.OpenAI.Codex`（**不需要管理员权限**，服务 ACL 允许当前用户启动）。
  本机实测：启动后状态稳定 Running，辅助进程正常。

**变更**

- `diagnose-chatgpt-chrome-bridge.ps1`：新增第 6 项检查「电脑控制辅助服务是否在运行」，
  未运行判为 `[FAIL]`（诊断现在共 6 项）
- `fix-chatgpt-chrome-bridge.ps1`：每次运行都会检查并**自动启动**该服务，启动失败时给出
  `services.msc` 的手动操作提示
- README：诊断检查清单、FAQ、已知限制同步更新

**已知限制**

- 「服务崩溃后自动重启」需要在管理员权限下配置（`sc failure ... actions= restart/5000`），
  普通用户权限会返回 `Access is denied`；本版本只做"发现未运行就启动"。

## v0.3.1 — 2026-09-26

**适配应用 `26.924.1866.0`（内部版本 `26.924.20706`）+ 修掉上一版暴露的四个问题**

- **缓存标记又变了**：新构建**删除了 `computerUseSkillVariant` 字段**（音频开关也改为
  「有 `computer-use` 插件 && 两个音频环境变量」，不再看 `legacy-mcp`）。标记是字符串全等比较，
  多一个字段就永远不相等 —— v0.3.0 写出的标记因此不可能命中。`build-marketplace.mjs` 已按新结构更新。
- **native host 桥接在更新后消失**：诊断第 3 项报清单文件与 Chrome 注册表项缺失
  （应用更新/安装流程中被清掉了）。这次修复后需要补跑 `repair-native-host.ps1`
  （官方自检 `correct=true`），README 与输出提示里都写明了这一步。
- **截获清单的竞态 bug**：应用会先创建 staging 文件、再写内容，v0.3.0 有概率截获到 0 字节的空文件，
  随后整轮修复失败（上一版 4 组候选全部空转）。现在会校验内容非空且是带 `plugins` 的 JSON，
  不合格就继续等/重试（最多 3 轮）。
- **应用进程结束不掉时不再中断**：若 ChatGPT 是提权启动的（本次实测有进程返回 `Access is denied`），
  `Stop-ChatGpt` 现在只警告不终止脚本，改用**焦点触发 reconcile**（诊断验证过：焦点触发与
  startup reconcile 等价），并在等待循环里反复触发。
- 文案修正：截获大小改为报告文件真实字节数（之前把函数返回值数组的长度当成了字符数）。

**实测结果（2026-09-26，应用 `26.924.1866.0` / 插件 `26.924.20706`）**

- `[2/4]` 同步 813 个文件用时 1.0 秒，四项自检通过；`[4/4]` 事件
  `bundled_plugins_reconcile_started` → `runtime_marketplace_reused`，退出码 `0`
- `repair-native-host.ps1`：官方自检 `correct=true`
- 复检：诊断退出码 `0`（5 项全过），插件缓存更新为
  `browser`/`chrome`/`computer-use`/`unified-computer-use` `26.924.20706`、`codex-app-tools 0.1.5`、`visualize 1.0.41`

## v0.3.0 — 2026-09-19

**修复：应用更新到 `26.915.4065.0` 后旧方案失效（首次出现"必须换机制"的复发）**

- 症状：浏览器桥接再次报"无法连接到浏览器扩展桥接"；诊断脚本第 5 项报最后一次刷新为
  `bundled_plugins_marketplace_resolve_failed`，退出码 `1`
- 原因有两处，缺一不可：
  1. 新构建的缓存标记**多了一个展示开关字段**，而标记是按字符串全等比较的 —— 旧脚本写出的内容必然不等；
  2. 复用条件里**新增了对插件文件内容的校验**（visualize 技能文件必须与包内逐字节一致）。
     应用更新后包内插件内容也变了（该文件 30663 → 32281 字节），而运行目录里还是上一版本的副本。
- 旧方案（只写清单 + 标记、不动插件文件）因此无法命中。现在改为**用「读出字节再写入」自己完成那次复制**
  （应用自己的 `fs.cp` 会要求目标文件也能被加密，因此必然失败），从而同时满足标记、清单、内容三项条件。

**变更**

- `fix-chatgpt-chrome-bridge.ps1`：流程改为 4 步 —— 截获清单 → 读+写重建运行市场目录（含插件文件）→
  关闭应用换入新目录 → 启动并验证；**换入前先自检三项复用条件**，不通过就不换（不会把环境搞坏）；
  候选参数由 2 组扩到 4 组
- 新增 `capture-manifest.mjs`、`build-marketplace.mjs`（原内嵌脚本改为独立文件，便于复用与审查）
- `diagnose-chatgpt-chrome-bridge.ps1`：第 5 项新增"运行目录里的插件内容是否与包内一致"检查，
  把这次的新失效模式提前标出来
- 同步插件内容的附带收益：应用会把**当前版本**的插件装进 `~/.codex/plugins/cache/openai-bundled/`

**实测结果（2026-09-19，应用 `26.915.4065.0` / 插件 `26.915.31945`）**

- 修复脚本：`[2/4]` 同步 808 个文件（约 85 MB）用时 1.1 秒，四项自检全部通过；
  `[4/4]` 日志出现 `bundled_plugins_reconcile_started` → `runtime_marketplace_reused`，退出码 `0`
- 复检：诊断脚本退出码 `0`，第 5 项显示"复用成功"且"visualize 技能内容与包内一致"；
  插件缓存更新为 `browser`/`chrome`/`computer-use`/`unified-computer-use` `26.915.31945`、`visualize 1.0.38`
- `chrome\latest` junction 已指向新版本，native host 清单正是通过它找到新的 `extension-host.exe`

## v0.2.0 — 2026-09-15

**新增**

- `chatgpt-check.mjs` + `check-chatgpt-connectivity.ps1` —— 网络侧连通性自检：4 项检查
  1. 隧道本身：通过本地代理 `CONNECT` 到 `chatgpt.com:443` 并完成 TLS 握手（`--direct` 时改为直连 443）
  2. ChatGPT 依赖的 10 个域名逐个握手
  3. 真实出口节点：读 `chatgpt.com/cdn-cgi/trace`，显示出口 IP、归属地、Cloudflare 机房
  4. 真实页面加载 ×10：统计 `HTTP 200` / Cloudflare 挑战 / 硬失败，区分"隧道不稳"与"出口 IP 被标记"
- 代理可配置：`--proxy <host:port>` / `--proxy-port <port>` / `--direct` / 环境变量 `CHATGPT_PROXY`，
  默认 `127.0.0.1:7892`；退出码 `0` = 链路正常，`1` = 隧道或出口节点异常，`2` = 参数错误
- `.ps1` 入口自动查找 `node.exe`：系统 PATH 优先，其次使用 ChatGPT 桌面版自带运行时（无需先装 Node.js）

**变更**

- 连通性自检由本机临时脚本通用化而来（去掉本机绝对路径与硬编码代理端口、去掉加速器品牌名）；
  输出保持英文 ASCII —— Windows 控制台默认代码页 936 会把 Node 输出的 UTF-8 中文变成乱码

**实测记录：故障在应用更新后复发一次（本次未改动修复脚本）**

- ChatGPT 桌面版自动更新 `26.908.4834.0` → `26.908.9136.0`（内置插件版本 `26.908.40834` → `26.908.70816`）
- 症状：浏览器桥接再次报"无法连接到浏览器扩展桥接"，诊断脚本第 5 项报最后一次刷新为
  `bundled_plugins_marketplace_resolve_failed`，退出码 `1`
- 原因：缓存标记与"应用版本 + 各插件版本"绑定，应用一升级就失配 —— 这正是需要**重跑修复脚本**的场景
- 处理：重跑 `fix-chatgpt-chrome-bridge.ps1`，1~2 分钟恢复（截获应用新清单 → 重写缓存标记 →
  重启后命中"复用现有市场"分支），诊断脚本随即回到"复用成功"、退出码 `0`
- 结论：**应用每次更新后复发属预期行为**，处理方式就是重跑第 3 步（见 README「3.6 更新之后」）

## v0.1.0 — 2026-09-15

首个版本。

**新增**

- `diagnose-chatgpt-chrome-bridge.ps1` —— 只读诊断：5 项检查定位卡点
  （退出码 `0` = 未发现已知故障，`1` = 检测到故障）
- `fix-chatgpt-chrome-bridge.ps1` —— 主修复：补齐应用所需的插件清单与缓存标记，
  重启应用验证缓存命中；两组内部参数自动依次尝试（退出码 `0` = 修复成功，`1` = 未命中）
- `repair-native-host.ps1` —— 重建扩展桥接：native messaging host 清单、
  Chrome/Edge 注册表项、桥接程序配置，并用插件自带的官方脚本自检；幂等
- `docs/root-cause.md` —— 根因记录：环境事实、失败链路、证据位置与取证方法

**适用范围**

- Windows 10 / 11，Windows PowerShell 5.1 即可，不需要管理员权限
- 针对「系统不具备文件加密能力（如 Windows 家庭版），而 ChatGPT/Codex 桌面版的
  MSIX 包文件带加密标记，导致应用刷新内置插件市场必然失败」这一根因

**已知限制**

- 只针对上述根因；应用大版本更新后缓存标记会失配，重新运行修复脚本即可
- 不修改应用安装包与 `app.asar`，全部操作可回滚（见 README「回滚」一节）
