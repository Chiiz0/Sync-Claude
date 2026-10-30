import SwiftUI
import SyncCore

@MainActor final class UpdateModel: ObservableObject {
    @Published var showDetails = false
    @Published private(set) var checking = false
    @Published private(set) var latest: AppRelease?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var checkError: String?
    @Published var automatic: Bool {
        didSet { defaults.set(automatic, forKey: "updates.automatic"); if automatic { check(manual: false) } }
    }
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.3"
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    var availableVersion: String? { latest?.isNewer(than: currentVersion) == true ? latest?.version?.description : nil }
    init() {
        automatic = defaults.object(forKey: "updates.automatic") as? Bool ?? true
        lastChecked = defaults.object(forKey: "updates.lastSuccess") as? Date
        if let data = defaults.data(forKey: "updates.release"), let cached = try? JSONDecoder().decode(AppRelease.self, from: data), cached.isTrusted { latest = cached }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(manual: false) }
        }
        check(manual: false)
    }
    func check(manual: Bool) {
        if manual { showDetails = true }
        guard !checking else { return }
        if !manual {
            guard automatic, UpdateChecker.shouldCheck(now: Date(), lastAttempt: defaults.object(forKey: "updates.lastAttempt") as? Date, lastSuccess: lastChecked) else { return }
        }
        checking = true; checkError = nil
        defaults.set(Date(), forKey: "updates.lastAttempt")
        Task {
            do {
                latest = try await UpdateChecker.latest()
                lastChecked = Date(); defaults.set(lastChecked, forKey: "updates.lastSuccess")
                if let latest { defaults.set(try JSONEncoder().encode(latest), forKey: "updates.release") }
                else { defaults.removeObject(forKey: "updates.release") }
            } catch {
                checkError = "暂时无法检查更新：\(error.localizedDescription)"
            }
            checking = false
        }
    }
}

struct UpdateOverview: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: UpdateModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("版本与更新").font(.title2.weight(.semibold))
            Text("当前版本 \(model.currentVersion)").foregroundStyle(.secondary)
            if let version = model.availableVersion, let release = model.latest {
                Label("发现新版本 \(version)", systemImage: "arrow.down.circle").font(.headline)
                if !release.notes.isEmpty {
                    ScrollView { Text(release.notes).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
                }
                Button("查看版本并下载安装包") { NSWorkspace.shared.open(release.page) }.buttonStyle(.borderedProminent)
            } else if let latest = model.latest {
                Text(latest.version == ReleaseVersion(model.currentVersion) ? "已是最新正式版本。" : "最新公开版本为 \(latest.version?.description ?? latest.tag)，当前本机版本更新。")
            } else if model.lastChecked != nil { Text("暂时没有可用的正式版本。") }
            if model.checking { HStack { ProgressView().controlSize(.small); Text("正在检查…") } }
            if let error = model.checkError { Text(error).font(.caption).foregroundStyle(.orange) }
            if let date = model.lastChecked { Text("上次成功检查：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            Divider()
            Toggle("自动检查更新", isOn: $model.automatic)
            Text("启动时检查，每天最多自动检查一次。仅向 GitHub 请求本工具的公开版本信息，不发送账号、API 配置或会话内容。下载后由你安装，不会自动替换正在运行的应用。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("GitHub Releases") { NSWorkspace.shared.open(UpdateChecker.releasesPage) }
                Spacer()
                Button("立即检查") { model.check(manual: true) }.disabled(model.checking)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 540)
    }
}
