# 0.1.4 本机窗口恢复修复验证

日期：2026-11-01（America/Los_Angeles）。验证版本：0.1.4 (6)。[正式版本与安装包](https://github.com/Chiiz0/Sync-Claude/releases/tag/v0.1.4)。

## 故障与原因

- 本机安装的 0.1.3 (5) 进程仍在运行，重新打开应用后无法获得主窗口。
- 对故障进程采样 3 秒：主线程在 AppKit 事件循环中等待，未发现主线程卡在归档、网络或锁上。这只说明采样期间没有阻塞，不代表排除了其他时段的所有卡顿。
- 重启旧版后主窗口正常；点击关闭，再次打开应用，只有辅助窗口，没有主界面，复现了用户报告的现象。
- 旧菜单栏操作使用 `NSApp.windows.first?.makeKeyAndOrderFront(nil)`。该数组包含辅助窗口，顺序不能作为主窗口身份；主窗口已关闭时，这段代码也无法创建窗口。
- 应用没有处理 Dock/Finder 的 reopen 事件。默认行为会受到其他可见窗口影响，不能保证恢复主窗口。

## 修复

- 使用 `Window("Sync Claude", id: "main")` 建立唯一主窗口；菜单栏与 File 菜单复用同一个打开按钮，通过 `openWindow(id:)` 恢复或重建窗口并激活应用。
- `NSApplicationDelegateAdaptor` 接入 reopen 处理：保留 SwiftUI 的打开动作，下一轮主队列执行，不因 `hasVisibleWindows` 为真而跳过恢复。
- 主窗口关闭后应用继续运行，应用级模型及后台归档定时器继续保留。
- 增加 `⌘0` 打开主窗口；检查更新时先显示主窗口，使更新面板有可见宿主。
- 采用 macOS 13 起提供的 API，保持现有最低系统版本。

API 行为依据：[Apple Window 文档](https://developer.apple.com/documentation/swiftui/window)、[Apple reopen 委托文档](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:))。

## 本机验证

环境：Apple Silicon，macOS 27.0.1 (26A434)，Claude Desktop 4.4212.0。

| 验证 | 结果 |
| --- | --- |
| `swift test`，Desktop 4.29.0 适配 | 98 项通过，无失败 |
| `SYNC_CLAUDE_TEST_DESKTOP_VERSION=4.4212.0 swift test` | 98 项通过，无失败 |
| Debug / Release 构建 | 通过，无编译警告 |
| Developer ID 签名及严格签名校验 | 通过，与原安装使用相同签名身份 |
| 关闭主窗口后再次唤起 | 恢复 `main` 窗口；测试进程 PID 未变化 |
| 最小化、隐藏后打开 | 已执行窗口操作并通过 Finder / 打开命令恢复主界面 |
| File → 打开 Sync Claude | 主界面可见，使用唯一 `main` 窗口 |
| 应用菜单 → 检查更新 | 正常显示 0.1.4 版本面板及最新公开版 0.1.3 |
| 安装后的 `--status` | 正常返回，现有配置与会话可读取 |
| 原安装位置启动 | `~/Applications/Sync Claude.app` 正常显示主界面 |

窗口验证为真实应用 UI 冒烟测试；98 项自动测试覆盖已有核心功能，并不替代 GUI 测试。菜单栏按钮与 File 打开命令共用同一组件，本次没有直接点击系统状态栏图标做单独验收。其他电脑、macOS 13 和长期驻留仍需后续验证。

## 本地交付

- 已在原路径安装 0.1.4 (6)，启动后保持运行。
- 原 0.1.3 应用保存在 `.build/window-fix-20261101/previous-installation/Sync Claude.app`，可用于回退。
- 测试及构建日志位于 `.build/window-fix-tests-4.29.0.log`、`.build/window-fix-tests-4.4212.0.log`、`.build/window-fix-build.log`；故障采样为本机临时诊断文件，不随源码分发。
- 没有切换 Claude 账号、执行同步删除或永久清理。正常后台归档保持启用。

## 公证与分发包

- 使用与 0.1.3 相同的 Developer ID Application 身份签名，包含 Hardened Runtime 和安全时间戳。
- Apple 公证 submission `e6635a23-80ee-40cf-bf31-6ef9512e168c` 为 `Accepted`，公证日志无 issues。
- 从提交的 ZIP 解压到尚未启动的目录后附加票据，再生成最终分发 ZIP；解压产物通过严格签名、公证票据和 Gatekeeper 校验，架构为 arm64。
- 分发包中的可执行文件与本机窗口冒烟测试所用版本相同，未在测试后修改产品源码。
- 资产：`Sync-Claude-0.1.4-macos-arm64.zip`、`SHA256SUMS`。ZIP 的 SHA-256 为 `80e433c6c66d10c72a0c9c259d28dcbf172cb199cfcef89b03a94a39e75849c1`。
- 升级时退出 Sync Claude，把新应用替换到原位置后重新打开；账号快照、配置和归档保留。
