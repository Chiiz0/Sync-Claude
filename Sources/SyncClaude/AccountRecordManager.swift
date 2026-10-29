import SwiftUI
import SyncCore

struct AccountRecordManager: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let clean: ([AccountRecordInfo]) -> Void
    let restore: (String) -> Void
    let purge: (RecordPurgePreview) -> Void
    @State private var tab = 0
    @State private var selection = Set<String>()
    @State private var confirmCleanup = false
    @State private var reviewed: [AccountRecordInfo] = []
    @State private var purgePreview: RecordPurgePreview?
    @State private var preparingPurge = false
    @State private var preparationError: String?
    var records: [AccountRecordInfo] { model.status?.accountRecords ?? [] }
    var removed: [RemovedAccountRecord] { model.status?.removedAccountRecords ?? [] }
    var restored: [RemovedAccountRecord] { model.status?.restoredAccountBackups ?? [] }
    var visibleBackups: [RemovedAccountRecord] { tab == 2 ? restored : removed }
    var selected: [AccountRecordInfo] { records.filter { selection.contains($0.id) && $0.canClean } }
    var canWrite: Bool { !model.busy && !preparingPurge && model.status?.compatible == true && model.status?.pendingRecovery != true }
    var mixedSelection: Bool { selected.contains(where: { $0.empty }) && selected.contains(where: { !$0.empty }) }
    func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("账户记录管理").font(.title2.weight(.semibold))
                Spacer()
                if preparingPurge { ProgressView().controlSize(.small) }
                Button("刷新") { model.refresh() }.disabled(model.busy || preparingPurge)
            }
            Text("按账户和组织整理本机 Code 记录。当前保留的官方登录及 API 目录受到保护。").font(.subheadline).foregroundStyle(.secondary)
            Picker("记录类别", selection: $tab) {
                Text("账户目录 · \(records.count)").tag(0)
                Text("可恢复 · \(removed.count)").tag(1)
                Text("已恢复的备份 · \(restored.count)").tag(2)
            }.pickerStyle(.segmented)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if tab == 0 {
                        ForEach(records) { record in accountRow(record) }
                        if records.isEmpty { Text("没有本地账户目录").foregroundStyle(.secondary).padding() }
                    } else {
                        ForEach(visibleBackups) { record in removedRow(record) }
                        if visibleBackups.isEmpty { Text("没有保留的副本").foregroundStyle(.secondary).padding() }
                    }
                }.padding(2)
            }.frame(minHeight: 280, maxHeight: 390)
            Text(tab == 0
                ? "空目录可直接永久删除，不再保留恢复副本。有内容的目录先清理到“可恢复”，之后可永久清除副本。共享会话正文、历史归档、登录快照和 API 配置保留。"
                : "永久清除会删除此账户/组织目录的所有恢复副本（含以前恢复过的副本）及关联操作备份，不能撤销。共享会话正文和历史归档保留。恢复仍需副本校验通过且原目录不存在。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if tab == 0 {
                    Button("选择可清理的空目录") { selection = Set(records.filter { $0.canClean && $0.empty }.map(\.id)) }.disabled(!canWrite)
                    Text("已选 \(selected.count) 个").font(.caption).foregroundStyle(.secondary)
                    if mixedSelection { Text("请分开选择空目录和有内容的目录").font(.caption).foregroundStyle(.orange) }
                } else {
                    Button("永久清除本页全部副本…", role: .destructive) { preparePurge(ids: visibleBackups.map(\.id)) }.disabled(!canWrite || visibleBackups.isEmpty)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                if tab == 0 {
                    Button(!selected.isEmpty && selected.allSatisfy(\.empty) ? "永久删除空目录…" : "清理所选…", role: .destructive) {
                        if selected.allSatisfy(\.empty) { preparePurge(live: selected) }
                        else { reviewed = selected; confirmCleanup = true }
                    }.disabled(!canWrite || selected.isEmpty || mixedSelection)
                }
            }
        }.padding(24).frame(width: 700)
        .alert("清理 \(reviewed.count) 个账户目录？", isPresented: $confirmCleanup) {
            Button("清理并保留恢复副本", role: .destructive) { clean(reviewed) }
            Button("取消", role: .cancel) { reviewed = [] }
        } message: {
            Text("所选目录共 \(reviewed.reduce(0) { $0 + $1.sessionCount }) 条会话、\(size(reviewed.reduce(0) { $0 + $1.bytes }))。其中 \(reviewed.reduce(0) { $0 + $1.uniqueSessionCount }) 条目前仅在所选某个目录中可见；清理前会归档。Claude 将正常退出并重开。可在“可恢复”中撤销清理，共享正文与配置不会删除。")
        }
        .alert("永久清除 \(purgePreview?.directoryCount ?? 0) 个目录的副本？", isPresented: Binding(get: { purgePreview != nil }, set: { if !$0 { purgePreview = nil } })) {
            Button("永久清除，不能恢复", role: .destructive) { if let preview = purgePreview { purge(preview) }; purgePreview = nil }
            Button("取消", role: .cancel) { purgePreview = nil }
        } message: {
            if let preview = purgePreview {
                Text("将清除 \(preview.recoveryCopyCount) 份恢复副本及关联操作备份，共 \(preview.fileCount) 个文件、\(size(preview.bytes))。\(preview.emptyOnly ? "已核对均为空目录或空任务配置。" : "其中包含会话记录或其他内容，请确认不再需要这些副本。")\n\n\(preview.deletesLiveDirectories ? "所选原空目录也会删除，Claude 会正常重开。" : "不会重启 Claude，也不会删除重新建立的原目录。")不会为这些内容再生成备份。共享会话正文、历史归档及其他账号保留；本操作不等于从所有账号彻底擦除会话。")
            }
        }
        .alert("无法准备永久清除", isPresented: Binding(get: { preparationError != nil }, set: { if !$0 { preparationError = nil } })) {
            Button("知道了") { preparationError = nil }
        } message: { Text(preparationError ?? "") }
    }

    func preparePurge(ids: [String] = [], live: [AccountRecordInfo] = []) {
        guard !preparingPurge else { return }
        preparingPurge = true
        Task {
            do {
                let engine = model.engine
                purgePreview = try await Task.detached {
                    try live.isEmpty ? engine.previewRecordPurge(ids: ids) : engine.previewEmptyRecordDeletion(live)
                }.value
            } catch { preparationError = error.localizedDescription }
            preparingPurge = false
        }
    }

    func identity(_ profile: String, _ account: String, _ organization: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(profile == "Claude" ? "官方账号" : "API 账户") · \(account.prefix(8))").font(.headline)
            Text("账户 \(account)\n组织 \(organization)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    func accountRow(_ record: AccountRecordInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("选择目录 \(record.account.prefix(8)) / \(record.organization.prefix(8))", isOn: Binding(
                get: { selection.contains(record.id) },
                set: { if $0 { selection.insert(record.id) } else { selection.remove(record.id) } }
            )).labelsHidden().toggleStyle(.checkbox).disabled(!canWrite || !record.canClean)
            VStack(alignment: .leading, spacing: 8) {
                identity(record.profile, record.account, record.organization)
                Text("\(record.sessionCount) 条会话 · \(record.uniqueSessionCount) 条仅此目录可见 · \(record.fileCount) 个文件 · \(size(record.bytes))").font(.caption)
                if record.missingTranscriptCount > 0 { Text("\(record.missingTranscriptCount) 条缺少正文，目录副本仍会保留").font(.caption).foregroundStyle(.orange) }
                if let reason = record.blockedReason { Label(reason, systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                else if record.empty { Label("空目录，可清理", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
                else { Text("包含记录，请确认不再使用后清理").font(.caption).foregroundStyle(.secondary) }
                if record.savedLogin { Text("已保存登录快照；清理目录不会移除登录").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    func removedRow(_ record: RemovedAccountRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                identity(record.profile, record.account, record.organization)
                Text("\(record.sessionCount) 条会话 · \(size(record.bytes)) · \(Date(timeIntervalSince1970: record.cleanedAt).formatted(date: .abbreviated, time: .shortened)) 清理").font(.caption).foregroundStyle(.secondary)
                if record.restoredAt != nil { Text("目录已恢复；这里清除的只是保留的备份").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if record.restoredAt == nil { Button("恢复目录") { restore(record.id) }.disabled(!canWrite) }
            Button("永久清除…", role: .destructive) { preparePurge(ids: [record.id]) }.disabled(!canWrite)
        }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
