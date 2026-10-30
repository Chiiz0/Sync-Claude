import SwiftUI
import SyncCore

struct DeletedSessionManager: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let purge: (SessionPurgePreview) -> Void
    @State private var records: [DeletedSessionInfo] = []
    @State private var selection = Set<String>()
    @State private var loading = false
    @State private var error: String?
    @State private var preview: SessionPurgePreview?
    @State private var confirmed: SessionPurgePreview?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("已删除会话").font(.title2.weight(.semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("刷新") { Task { await load() } }.disabled(loading)
            }
            Text("这些会话已从统一列表隐藏，但仍有以下正文或备份。只有主动删除过的会话才会出现在这里。").foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(records) { row in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("选择 \(row.title)", isOn: Binding(get: { selection.contains(row.id) }, set: { if $0 { selection.insert(row.id) } else { selection.remove(row.id) } }))
                                .labelsHidden().toggleStyle(.checkbox).disabled(loading)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.title).font(.headline).textSelection(.enabled)
                                Text(row.project).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Text("账号记录 \(row.nativeCopies) 份 · 元数据归档 \(row.archiveVersions) 版 · 备份 \(row.backupCopies) 份 · 正文及附件 \(row.transcriptCopies) 个文件").font(.caption)
                                Text("删除于 \(Date(timeIntervalSince1970: row.deletedAt).formatted(date: .abbreviated, time: .shortened)) · \(row.id)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                if row.nativeCopies == 0 { Text("Claude 账号中已无记录，保留内容来自归档或备份。").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if records.isEmpty && !loading { Text("没有需要清理的已删除会话").foregroundStyle(.secondary).padding() }
                }
            }.frame(minHeight: 260, maxHeight: 420)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text("预览会列出具体文件和占用。正文被其他会话共用时会阻止清理；范围变化后需要重新确认。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("全选") { selection = Set(records.map(\.id)) }.disabled(loading || records.isEmpty)
                Text("已选 \(selection.count) 条").font(.caption)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("预览永久清理…", role: .destructive) { prepare() }
                    .disabled(loading || selection.isEmpty || model.busy || model.status?.compatible != true)
            }
        }.padding(24).frame(width: 760)
        .task { await load() }
        .sheet(item: $preview, onDismiss: {
            if let confirmed { self.confirmed = nil; purge(confirmed) }
        }) { item in
            SessionPurgeReview(preview: item, busy: model.busy) { confirmed = item; preview = nil }
        }
    }
    func load() async {
        guard !loading else { return }
        loading = true; error = nil
        do {
            let engine = model.engine
            records = try await Task.detached { try engine.deletedSessionRecords() }.value
            selection.formIntersection(records.map(\.id))
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    func prepare() {
        guard !loading else { return }
        loading = true; error = nil
        let engine = model.engine, ids = selection.sorted()
        Task {
            do { preview = try await Task.detached { try engine.previewSessionPurge(ids: ids) }.value }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

struct SessionPurgeReview: View {
    @Environment(\.dismiss) private var dismiss
    let preview: SessionPurgePreview
    let busy: Bool
    let confirm: () -> Void
    @State private var acknowledged = false
    func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认永久清理范围").font(.title2.weight(.semibold))
            Text("\(preview.sessions.count) 条已删除会话 · \(preview.files.count) 个文件 · \(size(preview.bytes))").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview.sessions) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).font(.headline)
                            Text(row.project).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    ForEach(Dictionary(grouping: preview.files, by: \.category).keys.sorted(), id: \.self) { category in
                        let files = preview.files.filter { $0.category == category }
                        DisclosureGroup("\(category)：\(files.count) 个文件，\(size(files.reduce(0) { $0 + $1.bytes }))") {
                            ForEach(files) { file in
                                Text("\(file.path) · \(size(file.bytes))").font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                            }
                        }
                    }
                    Text("同时更新 \(preview.updatedIndexes) 份索引/备份清单，保留其中其他会话。").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(minHeight: 220, maxHeight: 340)
            Text("将正常退出 Claude 后删除所列文件，不再生成这些内容的备份。中断可继续清理，已删除内容不能恢复。删除标记继续保留，防止旧记录重新导入。").font(.callout)
            Text("项目文件、登录/API 配置、其他会话、系统备份和手工保存在其他位置的副本不在清理范围。").font(.caption).foregroundStyle(.secondary)
            Toggle("我已核对范围，理解这些正文和备份将无法恢复", isOn: $acknowledged).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("永久清理 \(preview.sessions.count) 条会话", role: .destructive) { confirm() }.disabled(!acknowledged || busy)
            }
        }.padding(24).frame(width: 720)
    }
}
