import SwiftUI
import AppKit
import SyncCore

@main
struct SyncClaudeApp: App {
    @StateObject private var model = AppModel()
    init() {
        let args = CommandLine.arguments
        if args.count == 3 && args[1] == "--credential" {
            do { print(try CredentialStore.get(id: args[2])); exit(0) }
            catch { fputs("Sync Claude: credential unavailable\n", stderr); exit(1) }
        }
        if args.contains("--status") {
            do { let bytes = try JSONEncoder().encode(Engine().status()); print(String(decoding: bytes, as: UTF8.self)); exit(0) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if args.contains("--archive") {
            do { print(try Engine().archive().message); exit(0) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if args.contains("--purge-empty-recovery") {
            do {
                let engine = Engine()
                let ids = try engine.removedAccountRecords().filter { $0.sessionCount == 0 }.map(\.id)
                guard !ids.isEmpty else { print("没有空恢复项"); exit(0) }
                let preview = try engine.previewRecordPurge(ids: ids)
                guard preview.emptyOnly else { throw SyncError("恢复副本或旧操作备份含有效/未知内容，请在界面逐项检查。") }
                if let index = args.firstIndex(of: "--confirm-fingerprint"), args.indices.contains(index + 1) {
                    guard args[index + 1] == preview.fingerprint else { throw SyncError("预览指纹已变化，请重新检查。") }
                    print(try engine.purgeRecords(preview).message)
                } else {
                    let summary: [String: Any] = ["directories": preview.directoryCount, "recoveryCopies": preview.recoveryCopyCount, "files": preview.fileCount, "bytes": preview.bytes, "fingerprint": preview.fingerprint, "emptyOnly": preview.emptyOnly]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
                }
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if args.contains("--self-test-keychain") {
            let id = UUID().uuidString.lowercased(), secret = UUID().uuidString
            do {
                try CredentialStore.put(id: id, secret: secret)
                defer { CredentialStore.remove(id: id) }
                guard try CredentialStore.get(id: id) == secret else { exit(1) }
                print("Keychain round-trip passed; temporary credential removed."); exit(0)
            } catch { fputs("Keychain self-test failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
    }
    var body: some Scene {
        WindowGroup("Sync Claude") { MainView(model: model).frame(minWidth: 960, minHeight: 640) }
            .defaultSize(width: 1100, height: 740)
            .windowStyle(.titleBar)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandMenu("同步") {
                    Button("刷新状态") { model.refresh() }.keyboardShortcut("r")
                    Button("归档本机记录") { model.archive() }.disabled(model.busy)
                    Button("同步并重载 Claude") { model.sync() }.disabled(model.busy)
                }
            }
        MenuBarExtra("Sync Claude", systemImage: "arrow.triangle.2.circlepath") {
            Button("打开 Sync Claude") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
            Divider()
            ForEach(model.status?.profiles ?? []) { profile in
                Button((profile.active ? "✓ " : "") + profile.name) { model.switchTo(profile) }.disabled(model.busy)
            }
            Divider()
            Button("归档本机记录") { model.archive() }.disabled(model.busy)
            Button("退出 Sync Claude") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var status: Status?
    @Published var busy = false
    @Published var activity = "正在读取本机状态…"
    @Published var error: String?
    @Published var autoArchive = true
    @Published var askToRestart = false
    @Published var usageBusy = false
    @Published var deletionPreview: ProfileDeletionPreview?
    private var pendingRestart: (() -> Void)?
    let engine = Engine()
    private var timer: Timer?
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.busy else { return }
                if self.autoArchive && self.status?.pendingRecovery != true { self.archive(silent: true) } else { self.refresh() }
            }
        }
    }
    func refresh() {
        guard !busy else { return }
        busy = true
        Task {
            do {
                let result = try await Task.detached { [engine] in try engine.status() }.value
                status = result
                if activity == "正在读取本机状态…" { activity = "已读取本机数据，切换时自动合并 Code 记录。" }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    func run(_ text: String, silent: Bool = false, action: @escaping (Engine) throws -> Outcome) {
        guard !busy else { return }
        busy = true
        if !silent { activity = text }
        Task {
            do {
                let result = try await Task.detached { [engine] in try action(engine) }.value
                if !silent { activity = result.message }
                status = try await Task.detached { [engine] in try engine.status() }.value
            } catch {
                self.error = error.localizedDescription
                activity = "操作未完成。请查看提示。"
                if let latest = try? await Task.detached(operation: { [engine] in try engine.status() }).value { status = latest }
            }
            busy = false
        }
    }
    func archive(silent: Bool = false) { run("正在归档 Code 记录…", silent: silent) { try $0.archive() } }
    func restarting(_ text: String, action: @escaping (Engine, Bool) throws -> Outcome) {
        guard !busy else { return }
        // Check again here rather than trusting a status snapshot from the last timer tick.
        if MacClaudeProcess().workers > 0 {
            pendingRestart = { [weak self] in self?.run(text) { try action($0, true) } }
            askToRestart = true
        } else { run(text) { try action($0, false) } }
    }
    func confirmRestart() { let work = pendingRestart; pendingRestart = nil; askToRestart = false; work?() }
    func cancelRestart() { pendingRestart = nil; askToRestart = false }
    func sync() { restarting("正在保存历史、同步记录并重载 Claude…") { try $0.sync(allowOpenSessions: $1) } }
    func switchTo(_ profile: ProfileInfo) { restarting("正在切换到 \(profile.name)…") { try $0.switchProfile(id: profile.id, allowOpenSessions: $1) } }
    func saveAccount(_ name: String) { restarting("正在保存官方账号…") { try $0.saveAccount(name: name, allowOpenSessions: $1) } }
    func setAlias(_ profile: ProfileInfo, alias: String?) { run("正在保存配置别名…") { try $0.setProfileAlias(id: profile.id, kind: profile.kind, alias: alias) } }
    func prepareDeletion(_ profile: ProfileInfo) {
        guard !busy else { return }
        busy = true
        Task {
            do { deletionPreview = try await Task.detached { [engine] in try engine.profileDeletionPreview(id: profile.id, kind: profile.kind) }.value }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    func deleteProfile(_ preview: ProfileDeletionPreview) {
        restarting("正在备份并删除配置…") { try $0.deleteProfile(preview, allowOpenSessions: $1) }
    }
    func newLogin() { restarting("正在保存已有登录并准备添加官方账号…") { try $0.newLogin(allowOpenSessions: $1) } }
    func openClaude() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else { error = "未找到 Claude 桌面客户端"; return }
        NSWorkspace.shared.open(url)
    }
    func recover() { run("正在恢复上次操作…") { try $0.recover() } }
    func cleanRecords(_ previews: [AccountRecordInfo]) { restarting("正在备份并清理账户目录…") { try $0.cleanAccountRecords(previews, allowOpenSessions: $1) } }
    func restoreRecords(_ id: String) { restarting("正在恢复账户目录…") { try $0.restoreAccountRecords(id: id, allowOpenSessions: $1) } }
    func purgeRecords(_ preview: RecordPurgePreview) {
        if preview.deletesLiveDirectories { restarting("正在永久删除空目录…") { try $0.purgeRecords(preview, allowOpenSessions: $1) } }
        else { run("正在永久清除恢复副本…") { try $0.purgeRecords(preview) } }
    }
    func resumePurge() { restarting("正在继续永久清除…") { try $0.resumeRecordPurge(allowOpenSessions: $1) } }
    func refreshUsage() {
        guard !usageBusy else { return }
        usageBusy = true
        Task {
            do {
                let result = try await engine.refreshUsage()
                activity = result.message
                if !busy { status = try await Task.detached { [engine] in try engine.status() }.value }
            } catch { self.error = error.localizedDescription }
            usageBusy = false
        }
    }
    func repairContext(_ preview: GatewayContextInfo) { restarting("正在备份并修复默认 1M 设置…") { try $0.repairGatewayContext(preview, allowOpenSessions: $1) } }
    func addGateway(name: String, endpoint: String, models: String, auth: String, key: String, prefer1m: Bool) {
        let list = models.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        restarting("正在安全保存 API 配置…") { engine, allow in
            try engine.addGateway(name: name, endpoint: endpoint, models: list, auth: auth, key: key, helper: Bundle.main.executablePath ?? "", prefer1m: prefer1m, allowOpenSessions: allow)
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?
    @State private var query = ""
    @State private var showGateway = false
    @State private var showAccount = false
    @State private var aliasProfile: ProfileInfo?
    @State private var showAddAccountConfirmation = false
    @State private var showRecordManager = false
    @State private var pendingCleanup: [AccountRecordInfo] = []
    @State private var pendingRestore: String?
    @State private var pendingPurge: RecordPurgePreview?
    @State private var showUsage = false
    @State private var contextRepair: GatewayContextInfo?
    private let accent = Color(red: 0.75, green: 0.36, blue: 0.24)
    var selected: ProfileInfo? { model.status?.profiles.first { $0.id == selection } }
    var savedAccounts: [ProfileInfo] { model.status?.profiles.filter { $0.kind == "account" } ?? [] }
    var needsAccountOnboarding: Bool { savedAccounts.isEmpty || (model.status?.mode == "1p" && !savedAccounts.contains(where: { $0.active })) }
    var sessions: [SessionInfo] {
        (model.status?.sessions ?? []).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.project.localizedCaseInsensitiveContains(query) }
    }
    var canWrite: Bool { !model.busy && model.status?.compatible == true && model.status?.pendingRecovery != true }
    var canEditAlias: Bool { !model.busy && model.status?.pendingRecovery != true }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 25, weight: .medium)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sync Claude").font(.title3.weight(.semibold))
                        Text("账号切换，工作继续").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(22)
                List(selection: $selection) {
                    Section("API 配置") {
                        ForEach(model.status?.profiles.filter { $0.kind == "gateway" } ?? []) { profile in profileRow(profile) }
                    }
                    Section("已保存的官方账号 · \(savedAccounts.count)") {
                        ForEach(savedAccounts) { profile in profileRow(profile) }
                        if savedAccounts.isEmpty {
                            Text("点击下方“添加官方账号”开始登录").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.listStyle(.sidebar)
                Divider()
                VStack(spacing: 10) {
                    Button { showGateway = true } label: { Label("添加 API 配置", systemImage: "plus").frame(maxWidth: .infinity) }.disabled(!canWrite)
                    HStack {
                        Button("保存当前账号") { showAccount = true }.disabled(!canWrite || model.status?.canSaveOfficialAccount != true)
                        Button("添加官方账号") { showAddAccountConfirmation = true }.disabled(!canWrite)
                    }.font(.caption)
                    Button("官方账户用量") { showUsage = true }.frame(maxWidth: .infinity)
                }.padding(16)
            }.frame(minWidth: 245, idealWidth: 260, maxWidth: 310)
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        connection
                        historySection
                    }.padding(28)
                }
                footer
            }.frame(minWidth: 680)
        }
        .tint(accent)
        .toolbar {
            ToolbarItemGroup {
                Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(model.busy)
                Button { NSWorkspace.shared.open(model.engine.state) } label: { Label("备份与归档", systemImage: "folder") }
            }
        }
        .sheet(isPresented: $showGateway) { GatewayForm { name, url, models, auth, key, prefer1m in model.addGateway(name: name, endpoint: url, models: models, auth: auth, key: key, prefer1m: prefer1m) } }
        .sheet(isPresented: $showAccount) { AccountForm { model.saveAccount($0) } }
        .sheet(item: $aliasProfile) { profile in ProfileAliasForm(model: model, profile: profile) }
        .sheet(isPresented: $showUsage) { UsageOverview(model: model) }
        .sheet(isPresented: $showRecordManager, onDismiss: {
            let cleanup = pendingCleanup, restore = pendingRestore, purge = pendingPurge
            pendingCleanup = []; pendingRestore = nil; pendingPurge = nil
            if !cleanup.isEmpty { model.cleanRecords(cleanup) }
            else if let restore { model.restoreRecords(restore) }
            else if let purge { model.purgeRecords(purge) }
        }) {
            AccountRecordManager(model: model, clean: { pendingCleanup = $0; showRecordManager = false }, restore: { pendingRestore = $0; showRecordManager = false }, purge: { pendingPurge = $0; showRecordManager = false })
        }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
        .alert("删除“\(model.deletionPreview?.name ?? "此配置")”？", isPresented: Binding(get: { model.deletionPreview != nil }, set: { if !$0 { model.deletionPreview = nil } })) {
            Button("删除配置", role: .destructive) { if let preview = model.deletionPreview { model.deleteProfile(preview) }; model.deletionPreview = nil }
            Button("取消", role: .cancel) { model.deletionPreview = nil }
        } message: {
            Text((model.deletionPreview?.kind == "account"
                ? "将移除已保存的官方账号、登录快照、别名和用量缓存。不会注销 Claude 中保留的登录；需要再次使用时，可重新添加并保存账号。"
                : "将从 Claude 原生配置库移除此 API 配置及别名。需要再次使用时，请重新添加；钥匙串凭据仍会保留。")
                + "\n\nCode 会话和历史归档保留。删除前保留操作备份，目前不自动过期；此操作不是彻底擦除，也不属于“账户记录管理”的目录恢复。Claude 若正在运行会正常重开。")
        }
        .alert("修复新会话的默认 1M 设置", isPresented: Binding(get: { contextRepair != nil }, set: { if !$0 { contextRepair = nil } })) {
            Button("备份并修复") { if let preview = contextRepair { model.repairContext(preview) }; contextRepair = nil }
            Button("取消", role: .cancel) { contextRepair = nil }
        } message: { Text("让配置中已声明支持 1M 的模型优先使用 1M，并清除 Code / Cowork / Chat 中冲突或过期的模型选择。思考强度等其他偏好和已有会话保持不变；Claude 会正常重开。") }
        .alert("Claude 还有打开的 Code 会话", isPresented: $model.askToRestart) {
            Button("任务已完成，继续操作") { model.confirmRestart() }
            Button("稍后", role: .cancel) { model.cancelRestart() }
        } message: { Text("会话进程可能正在等待输入，也可能仍在执行。继续会正常退出并重开 Claude，暂停未完成的任务；项目和会话记录会保留。请确认任务已结束，或你已准备好暂停。") }
        .alert("添加官方账号", isPresented: $showAddAccountConfirmation) {
            Button("打开登录页面") { model.newLogin() }
            Button("取消", role: .cancel) {}
        } message: { Text("已有官方登录会先保存，再自动打开 Claude 登录页。在 Claude 中登录要添加的账号并进入 Code，然后返回这里点击“保存当前账号”，以后就能从账号列表切换。") }
        .onChange(of: model.status?.profiles.map(\.id)) { _ in
            let profiles = model.status?.profiles ?? []
            if !profiles.contains(where: { $0.id == selection }) { selection = profiles.first(where: { $0.active })?.id ?? profiles.first?.id }
        }
    }
    func profileRow(_ p: ProfileInfo) -> some View {
        HStack(spacing: 9) {
            Image(systemName: p.kind == "gateway" ? "network" : "person.crop.circle").frame(width: 20).foregroundStyle(p.active ? accent : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(p.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(p.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if p.active { Circle().fill(.green).frame(width: 6, height: 6).accessibilityLabel("当前配置") }
        }.padding(.vertical, 7).tag(p.id)
            .help(p.alias == nil ? p.name : "\(p.name)\n原名称：\(p.originalName)")
            .contextMenu {
                Button("编辑别名…") { aliasProfile = p }.disabled(!canEditAlias)
                Divider()
                Button(p.kind == "account" ? "删除官方账号…" : "删除 API 配置…", role: .destructive) { model.prepareDeletion(p) }.disabled(!canWrite || p.active)
                if p.active { Text("当前正在使用，请先切换其他配置") }
            }
    }
    var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("每次切换，都接着上次的工作").font(.system(size: 21, weight: .semibold))
                Text("统一保留这台 Mac 上的 Code 项目与会话").foregroundStyle(.secondary).font(.subheadline)
            }
            Spacer()
            HStack(spacing: 5) { Circle().fill(model.status?.running == true ? Color.green : Color.gray).frame(width: 6, height: 6); Text(model.status?.running == true ? "Claude 运行中" : "Claude 未运行").font(.caption) }
                .padding(.horizontal, 10).padding(.vertical, 7).background(.quaternary.opacity(0.5), in: Capsule())
        }.padding(28)
    }
    var connection: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Label("切换配置", systemImage: "slider.horizontal.3").font(.headline)
                Spacer()
                Text("Claude \(model.status?.version ?? "—")").font(.caption).foregroundStyle(.secondary)
            }
            if model.status?.pendingPurge == true {
                Label("永久清除尚未完成，已删除的副本不能恢复。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("继续永久清除") { model.resumePurge() }.disabled(model.busy)
            } else if model.status?.pendingRecovery == true {
                Label("上次操作尚未完成，请先恢复。", systemImage: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.orange)
                Button("恢复未完成操作") { model.recover() }.disabled(model.busy)
            } else if model.status?.compatible == false {
                Text("当前客户端版本还未验证写入兼容性，记录查看和归档仍可使用。").foregroundStyle(.orange)
            }
            if let p = selected { HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(p.name).font(.title2.weight(.medium)).lineLimit(2).textSelection(.enabled)
                        Button { aliasProfile = p } label: { Label("编辑别名", systemImage: "pencil") }.disabled(!canEditAlias)
                    }
                    Text(p.detail).font(.subheadline).foregroundStyle(.secondary)
                    if p.alias != nil { Text("原名称：\(p.originalName)").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                Button(p.active ? "重新应用" : p.kind == "account" ? "切换到此账号" : "切换到此配置") { model.switchTo(p) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!canWrite)
            } }
            if needsAccountOnboarding { accountOnboarding }
            Divider()
            if let context = selected?.context {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("默认模型：\(context.defaultModel ?? "由服务发现")").font(.caption).textSelection(.enabled)
                        Spacer()
                        Text(context.prefers1m ? "1M 优先" : context.supports1m ? "1M 可选" : "未声明 1M").font(.caption.weight(.medium)).foregroundStyle(context.prefers1m ? Color.green : Color.secondary)
                        Button("修复 1M 默认…") { contextRepair = context }.disabled(!canWrite || context.repairBlockedReason != nil)
                    }
                    ForEach(context.selections) { choice in
                        Text("\(choice.id.split(separator: "/").last.map(String.init)?.capitalized ?? "会话")：\(choice.model)\(choice.issue.map { " · " + $0 } ?? "")").font(.caption2).foregroundStyle(choice.issue == nil ? Color.secondary : Color.orange)
                    }
                    if let reason = context.repairBlockedReason { Text(reason).font(.caption2).foregroundStyle(.secondary) }
                    else if !context.prefers1m { Text("模型支持 1M，但默认偏好尚未启用。").font(.caption2).foregroundStyle(.orange) }
                }
                Divider()
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.shield").foregroundStyle(accent)
                Text("切换前保存登录与记录，自动重开 Claude。有会话进程时先确认任务已完成；不会强制终止进程。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(22).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))
    }
    var accountOnboarding: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.status?.canSaveOfficialAccount == true {
                Label("官方登录已识别，保存后即可切换", systemImage: "person.crop.circle.badge.checkmark").font(.headline)
                Text("请先在 Claude 进入一次 Code，再保存当前账号并同步记录。").font(.subheadline).foregroundStyle(.secondary)
                Button("保存当前账号") { showAccount = true }.buttonStyle(.borderedProminent).disabled(!canWrite)
            } else if model.status?.mode == "1p" {
                Label("完成官方账号登录", systemImage: "person.crop.circle.badge.plus").font(.headline)
                Text("在 Claude 中完成登录并进入 Code，返回这里刷新状态，然后保存当前账号。").font(.subheadline).foregroundStyle(.secondary)
                Button("打开 Claude 继续登录") { model.openClaude() }.buttonStyle(.borderedProminent).disabled(!canWrite)
            } else {
                Label("添加第一个官方账号", systemImage: "person.crop.circle.badge.plus").font(.headline)
                Text("登录并保存后，直接从左侧账号列表选择切换。").font(.subheadline).foregroundStyle(.secondary)
                Button("添加官方账号") { showAddAccountConfirmation = true }.buttonStyle(.borderedProminent).disabled(!canWrite)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }
    var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Code 记录").font(.title3.weight(.semibold))
                    Text("\(model.status?.sessions.count ?? 0) 条会话 · \(model.status?.ownerCount ?? 0) 个本地账户目录").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("账户记录管理") { showRecordManager = true }.disabled(model.busy)
                Button("仅归档") { model.archive() }.disabled(model.busy)
                Button("同步并重载") { model.sync() }.disabled(!canWrite)
            }
            if let count = model.status?.pendingDeletionCopies, count > 0 {
                Label("已主动删除的会话已从列表隐藏，另有 \(count) 份账号副本待删除。点击“同步并重载”或下次切换账号时同步。", systemImage: "trash")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索项目或会话", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            if sessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "尚未发现本地 Code 记录" : "没有匹配的记录").font(.headline)
                    Text("在 Claude 桌面端创建本地 Code 会话后，记录会出现在这里。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(36)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(sessions) { session in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "folder").foregroundStyle(accent).padding(10).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                Text(session.project.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).help(session.project)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(session.transcriptAvailable ? "历史可用" : "缺少历史正文").font(.caption2).foregroundStyle(session.transcriptAvailable ? Color.secondary : Color.orange)
                                if session.archived { Text("已归档").font(.caption2).foregroundStyle(.tertiary) }
                            }
                            Button { NSWorkspace.shared.open(URL(fileURLWithPath: session.project)) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).help("打开项目文件夹")
                        }.padding(.vertical, 13)
                        Divider()
                    }
                }
            }
            Text("共享本地 Code 记录；在任一账号主动删除的会话会从所有账号同步移除，也不会从归档重新加入。同步删除保留正文和操作备份，不等于永久擦除。云端与 Cowork 不在同步范围。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if model.busy { ProgressView().controlSize(.small) } else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                Text(model.activity).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Toggle("后台归档", isOn: $model.autoArchive).toggleStyle(.switch).controlSize(.mini).font(.caption).help("每 30 秒保留本地记录；不在 Claude 运行时写回。切换配置时自动同步。")
            }.padding(.horizontal, 22).padding(.vertical, 13)
        }
    }
}

struct GatewayForm: View {
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var key = ""
    @State private var models = ""
    @State private var auth = "bearer"
    @State private var prefer1m = false
    let save: (String, String, String, String, String, Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("添加 API 配置").font(.title2.weight(.semibold))
            Text("连接提供 Anthropic Messages API 的服务。密钥保存在本机钥匙串中。").font(.subheadline).foregroundStyle(.secondary)
            Form {
                TextField("配置名称", text: $name)
                TextField("API 地址", text: $url, prompt: Text("https://api.example.com"))
                SecureField("API Key", text: $key)
                Picker("认证方式", selection: $auth) { Text("Bearer").tag("bearer"); Text("x-api-key").tag("x-api-key") }
                TextField("模型 ID", text: $models, prompt: Text("留空自动发现；多个 ID 用逗号分隔"))
                Toggle(models.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "优先使用服务已声明的 1M 模型" : "所填模型均已确认支持 1M，默认优先使用", isOn: $prefer1m)
            }.textFieldStyle(.roundedBorder)
            Text("支持 Claude 模型 ID。若服务只提供 OpenAI 格式或其他模型，请先使用 CC Switch 等兼容网关。保存后可在左侧切换。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("安全保存") { save(name, url, models, auth, key, prefer1m); key = ""; dismiss() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty || url.isEmpty || key.isEmpty) }
        }.padding(28).frame(width: 530)
    }
}
struct AccountForm: View {
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    let save: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("保存当前官方账号").font(.title2.weight(.semibold))
            Text("给当前登录起个名字。工具会自动重开 Claude，并保留这台 Mac 上的登录快照；以后可从左侧或菜单栏切回。").font(.subheadline).foregroundStyle(.secondary)
            TextField("例如：个人账号 / 工作账号", text: $name).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存账号") { save(name); dismiss() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty) }
        }.padding(28).frame(width: 440)
    }
}
