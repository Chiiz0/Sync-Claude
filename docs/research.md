# 调研记录

日期：2026-10-29。适配对象：Claude Desktop 4.29.0，macOS Apple Silicon。

## 依据

1. Anthropic [Desktop reference](https://code.claude.com/docs/en/desktop)、[Gateway connection](https://code.claude.com/docs/en/llm-gateway-connect)：Desktop 与 CLI 的推理路由配置入口不同。不能只改 CLI 的 `~/.claude/settings.json`。
2. Anthropic [3P overview](https://claude.com/docs/third-party/claude-desktop/overview)、[installation](https://claude.com/docs/third-party/claude-desktop/installation)：第三方模式使用本地会话存储；配置在启动时读取，应用配置后需重开。
3. Anthropic [configuration reference](https://claude.com/docs/third-party/claude-desktop/configuration#inferencecredentialhelper)：credential helper 是绝对路径的可执行程序，参数独立传递，stdout 返回裸 token 或带 token 的 JSON。使用此接口从钥匙串读取新建 API 配置的 Key。
4. 本机 `Claude.app/Contents/Resources/app.asar` 的只读结构检查：`configLibrary/_meta.json` 的 `appliedId` 指向生效配置；两个 profile 的 `deploymentMode` 控制模式。当前签名版忽略 `CLAUDE_USER_DATA_DIR`，所以不使用环境变量隔离账号的办法，也不修改应用 bundle。
5. 本机只读磁盘检查：Code 记录位于 `claude-code-sessions/<account>/<organization>/local_<uuid>.json`，`cliSessionId` 对应 `~/.claude/projects` 中的正文文件。Cowork 使用另一套目录与 VM 路径，本项目不将其当成 Code 直接搬运。

## CC Switch 参考

参考项目：[farion1231/cc-switch](https://github.com/farion1231/cc-switch)。核验版本：`ddcb111765be66ed9e7e43e240497fd2c9576688`。

- [Desktop 使用说明](https://github.com/farion1231/cc-switch/blob/ddcb111765be66ed9e7e43e240497fd2c9576688/docs/user-manual/zh/2-providers/2.6-claude-desktop.md)：确认它已分别支持 Claude Code 和 Claude Desktop；Desktop 切换依赖重启，CLI 配置与 Desktop 不通用。
- [claude_desktop_config.rs](https://github.com/farion1231/cc-switch/blob/ddcb111765be66ed9e7e43e240497fd2c9576688/src-tauri/src/claude_desktop_config.rs)：参考最小范围配置合并、保留第三方库条目、同时处理两个模式文件，以及失败回滚的设计。
- [账号快照切换](https://github.com/farion1231/cc-switch/blob/ddcb111765be66ed9e7e43e240497fd2c9576688/src-tauri/src/services/claude_account/snapshot/switch.rs)：参考先保留旧身份、核对目标身份、互斥、恢复日志等思路。其具体实现面向 Claude Code CLI 凭据槽位，不能代替 Desktop 的 Electron 登录存储。

本项目独立用 Swift 实现，没有复制 CC Switch 源码或打包它的程序。若后续直接复用代码，需要核对对应版本的许可证并随分发保留所需声明。

本版本复用本机原生配置库，因此 CC Switch 已写入其中的配置可以被识别。没有直接导入其 SQLite 数据库、访问其凭据库或实现它的多协议转换代理。

## 设计决定

- 使用原生 SwiftUI 窗口与菜单栏，不启动浏览器服务。
- 不尝试替换运行中请求的身份；工具负责正常重开。有 Code agent 进程时先让用户确认任务完成或可以暂停，后台操作默认拒绝继续。客户端回复结束后仍保留空闲进程，这是实机验证后调整交互的依据。
- 登录信息分账号保存；本地 Code 的非凭据元数据与主正文独立保留。
- 不将旧权限授权跨账号复制。共享本机记录不代表获得云端会话权限。
- 在原生格式未提供稳定公开写入 API 的情况下，严格限定已验证版本，并保留恢复材料。

一个官方账号与现有 API 的往返续聊已完成实机验证；两个官方账号之间的 A → B → A 仍待实机验证。结构测试与客户端重开验证不能代替真实推理验收。

## 2026-10-29 后续：用量与 1M 默认值

- 既有配置排查发现，`cowork_account_settings.json` 中 `__model_selector_state.code/cowork.model` 保存的标准模型选择可能覆盖 1M 偏好。仅检查配置开关不足以证明新会话默认值正确。
- 当前 [官方配置文档](https://claude.com/docs/third-party/claude-desktop/configuration#modelprefer1mcontext) 说明 `modelPrefer1mContext` 对已声明 1M 能力的模型优先使用 1M；静态列表仍需正确的 `supports1m`。`alwaysStartWithDefaultModel` 是另外的“每次固定首个模型”策略，本工具不擅自启用。
- 默认值修复只使用原生配置及账号偏好，不修改 Claude bundle，不给未确认能力的模型强行标记 1M，不修改已有会话元数据。新机器安装后先完成 Claude/API 初次配置，再由诊断显示当前值；首次账号目录尚未建立时可配置 1M 偏好，待进入 Code 后继续检查保存的选择。
- Claude 4.29.0 自带 `ccdPlanUsage` 模块使用 Anthropic `/api/oauth/usage`，Bearer 为当前账号 Code OAuth token，附 `anthropic-beta: oauth-2025-04-20`。本机真实请求已返回 HTTP 200。账号/生产域名/Code client scope 精确匹配，并检查 token 到期和快照校验；不读取其他服务的凭据，不自动续期 token。
- 官方[用量说明](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work) 区分时段和每周限额。工具展示接口给出的使用百分比和绝对重置时刻，不以本地会话 token 数估算订阅额度。
