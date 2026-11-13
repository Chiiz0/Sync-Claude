# v0.1.10 真实 UI 验收与发布候选

验证日期：2026-11-12（America/Los_Angeles）。候选版本 0.1.10，构建号 12。**尚未发布**：本地会话同步场景、Apple 公证和最终发行包验证通过；网关真实续聊仍受服务端无可用账号阻塞。

## 真实环境

- 使用本机已有的一个官方账号和一个 API 配置，实际操作 Claude Desktop 与 Sync Claude 界面，不使用 FakeProcess 或人工改写会话元数据来替代 UI 操作。
- Claude Desktop 初始版本为 5.1231.2；后续正常重启后显示 5.11492.0，最终官方续聊在该版本上完成。
- 新建专用验收目录、父会话及原生分叉；所有验收请求均禁止读取文件、运行命令或修改项目。
- 两套不同官方账号间切换、其他机器和 Intel 架构不在此次真实验收范围。

## 结果

| 场景 | 结果 |
| --- | --- |
| 官方账号创建会话和原生分叉，并分别获得预期响应 | 通过 |
| 官方 → API 初次导入，显示父子层级及全部已有正文 | 通过，新增 5 条记录（包含已有的 3 条业务会话） |
| API → 官方恢复登录和原有模型选择 | 通过 |
| 原生 `/clear` 后生成新的 CLI 正文，再成功续聊 | 通过，原正文 ID 被保留在 `priorCliSessionIds` |
| 官方侧父会话归档、分叉移到顶层，切到已有 API 副本 | 通过，更新 2 份状态、接续 1 份正文、更新 1 份层级 |
| API 界面显示新接续正文、顶层子会话和已归档父会话 | 通过；保留 API 副本的模型选择和默认权限 |
| API 侧取消归档后切回官方 | 通过，更新 1 份已有会话，父会话重新显示 |
| 最后一次官方账号续聊 | 通过，返回 `SYNC-CLAUDE-UI-ROUNDTRIP-OK` |
| API 网关真实续聊 | 未通过：预检 HTTP 503，响应为 `No available accounts`；使用现有默认模型的实际请求也失败，已停止自动重试 |

在 2026-11-13 01:29:59 UTC（当地 11 月 12 日）使用最终发行包再次切到原有 API 配置，并在 Claude 原生界面点击“Check again”。原生详情仍显示 HTTP 503、`No available accounts: no available accounts`，探测模型为 `claude-opus-5-5`。复验结束后恢复原官方配置并退出 Claude，无新建会话。

直接读取配置文件发送请求曾得到 HTTP 401；随后确认该字段是 Claude 的 `__sealed__:v1:` 加密存储值，该检查无效，不作为密钥失效或服务可用性的证据。网关结论以上述原生客户端检查为准。

验收结束后回到原官方配置，归档保留两条验收会话，正常退出 Claude 和候选构建，并重新打开原已安装的 Sync Claude 0.1.9。未替换已安装应用，未删除会话或正文，无待恢复事务。

原有三条业务会话的正文指向、模型、归档和层级设置保持不变。收尾归档最后一条测试会话时，Claude 自动打开一条业务会话并提示模型迁移；已通过原生“撤销”恢复原模型。最终该记录仅 `lastFocusedAt` 发生正常浏览变化。

## 自动检查与签名

- `swift test`：190 项通过。
- `SYNC_CLAUDE_TEST_DESKTOP_VERSION=4.4212.0 swift test`：190 项通过。
- `SYNC_CLAUDE_TEST_DESKTOP_VERSION=5.1231.2 swift test`：190 项通过。
- Release 构建、Developer ID Application 签名、Hardened Runtime、安全时间戳及严格签名校验通过。
- 供公证使用的分发构建尚未启动；UI 验收使用其单独复制的应用。
- 发布准备提交 `79d35b734fce35504ae9e333f74330ead360a421` 的 [CI 运行 43280594782](https://github.com/Chiiz0/Sync-Claude/actions/runs/43280594782) 通过。

## 公证与发行包

- Apple 公证提交 `161807be-398a-4809-bfbb-f4e3cb6241f6` 返回 `Accepted`、`Ready for distribution`，日志 `issues` 为 `null`。
- 应用标识为 `com.syncclaude.desktop`，Developer ID 签名团队为 `BTU9K28V7U`。复用已有同团队公证凭据；profile 名称只是本机凭据别名，不决定应用标识。
- 从已公证 ZIP 解压出尚未启动的副本，附加票据后重新打包。最终 ZIP 再次解压后的严格签名、票据验证、Gatekeeper（`Notarized Developer ID`）和 arm64 架构检查全部通过。
- 从最终 ZIP 的解压副本启动，主界面正常读取已有账号与记录，版本窗口显示 `0.1.10`。完成后退出副本并恢复已安装的 `0.1.9`。
- 最终资产：`Sync-Claude-0.1.10-macos-arm64.zip`。
- ZIP SHA-256：`a9ec27027082d6969247fea13629d4b7897b443ec4391ef3ca85205f4f432962`。
- 可执行文件 SHA-256：`1f7dbded1c7d0daba83b4600127f173dbc9a27408054d8c68eebcff3b69fbca7`，与通过真实 UI 验收的签名候选一致。

本地证据位于忽略目录 `.build/ui-acceptance-0.1.10/`，包含测试日志、签名构建日志、验收前元数据备份及脱敏状态对比。用户数据和原始诊断文件不提交 Git、不上传 Release。

## 发布前仍需完成

1. 网关可用后重做真实 API 续聊；当前不能把外部服务失败计为通过。
2. 核验最终发布提交的 CI，建立版本标签，发布 ZIP 与 SHA256SUMS，再下载公开资产校验。
