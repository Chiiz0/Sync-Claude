# 发布 macOS 版本

默认本地构建不需要开发者证书。公开分发包在 macOS 签名机上制作；证书私钥和公证凭据仅保存在本机钥匙串，不提交 Git 或上传到 Release。

## 测试与签名

先更新 `scripts/build-app.sh` 中的版本/构建号及 `CHANGELOG.md`，运行：

```sh
swift test
SYNC_CLAUDE_TEST_DESKTOP_VERSION=4.4212.0 swift test
SIGNING_IDENTITY='<Developer ID Application identity>' zsh scripts/build-app.sh
codesign --verify --deep --strict 'dist/Sync Claude.app'
codesign -dv --verbose=4 'dist/Sync Claude.app'
```

确认签名类型为 Developer ID Application，包含 Hardened Runtime 和安全时间戳。应用不需要额外放宽运行时的 entitlement。

## 公证与票据

使用已通过 `notarytool store-credentials` 保存的本机 profile。以下 `<profile>` 是名称，不是密码：

```sh
ditto -c -k --keepParent --norsrc --noextattr \
  'dist/Sync Claude.app' dist/notary-submission.zip
xcrun notarytool submit dist/notary-submission.zip \
  --keychain-profile '<profile>' --output-format json
```

保存返回的 submission ID，后续只查询该 ID，不重复上传：

```sh
xcrun notarytool info '<submission-id>' --keychain-profile '<profile>'
xcrun notarytool log '<submission-id>' --keychain-profile '<profile>' \
  .build/notarization-log.json
```

仅在状态为 `Accepted`、日志无待处理问题时继续：

```sh
xcrun stapler staple 'dist/Sync Claude.app'
xcrun stapler validate 'dist/Sync Claude.app'
codesign --verify --deep --strict 'dist/Sync Claude.app'
spctl --assess --type execute --verbose=2 'dist/Sync Claude.app'
```

按照 [Apple 公证文档](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)，将票据附加到应用后重新打包。ZIP 本身不能附加票据；最终压缩包必须包含已附加票据的应用。

在首次启动之前完成票据附加和打包。本次签名机对已运行的构建目录拒绝写入，`stapler` 返回 Error 73；从同一已公证 ZIP 解压出尚未启动的副本后，票据附加、签名和 Gatekeeper 校验均正常通过，无需修改签名或放宽系统保护。

## 打包与发布

以下为 v0.1.1 的 Apple Silicon 资产名称。确保目标 ZIP 不存在，避免向旧归档追加内容：

```sh
ditto -c -k --keepParent --norsrc --noextattr \
  'dist/Sync Claude.app' dist/Sync-Claude-0.1.1-macos-arm64.zip
(cd dist && shasum -a 256 Sync-Claude-0.1.1-macos-arm64.zip > SHA256SUMS)
```

解压到新目录，再验证签名、公证票据、Gatekeeper 和可执行文件架构；从解压产物启动应用做冒烟检查。发布 ZIP、`SHA256SUMS` 和脱敏验证结果，不发布 `.build`、用户 Application Support 目录、钥匙串或诊断原始日志。

提交已验证源码，建立版本标签，通过 `gh` 创建 Release。发布后下载资产再次比较 SHA-256，并核对本地 HEAD、远端分支和标签一致。GitHub Actions 只执行不含凭据的测试与 ad-hoc 构建。
