# 更新日志

本项目的版本记录，版本号与 GitHub 上的 tag / Release 一一对应。

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
