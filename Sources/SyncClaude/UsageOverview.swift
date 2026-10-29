import SwiftUI
import Combine
import SyncCore

struct UsageOverview: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    private let timer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()
    var rows: [OfficialUsage] { model.status?.officialUsage ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("官方账户用量").font(.title2.weight(.semibold))
                Spacer()
                if model.usageBusy { ProgressView().controlSize(.small) }
                Button("刷新全部") { model.refreshUsage() }.disabled(model.usageBusy || rows.isEmpty)
            }
            Text("无需切换当前配置，即可查询这台 Mac 上已保存的官方账号。").font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(rows) { account in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(account.name).font(.headline)
                                if let plan = account.plan { Text(plan.uppercased()).font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule()) }
                                Spacer()
                                Text(String(account.id.prefix(8))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            if let error = account.error { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                            if account.windows.isEmpty {
                                Text(model.usageBusy ? "正在读取官方用量…" : "尚无可用数据").font(.subheadline).foregroundStyle(.secondary)
                            }
                            ForEach(account.windows) { window in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(window.label).font(.subheadline)
                                        Spacer()
                                        Text(window.utilization.map { String(format: "%.0f%% 已用", $0) } ?? "用量未知").font(.subheadline.monospacedDigit())
                                    }
                                    if let value = window.utilization { ProgressView(value: min(max(value / 100, 0), 1)).tint(value >= 90 ? .orange : .accentColor) }
                                    if let reset = window.resetsAt {
                                        let date = Date(timeIntervalSince1970: reset)
                                        TimelineView(.periodic(from: .now, by: 30)) { context in
                                            Text("\(date.formatted(date: .abbreviated, time: .shortened)) 重置 · \(remaining(until: date, now: context.date))").font(.caption).foregroundStyle(.secondary)
                                        }
                                    } else { Text("服务未提供重置时间").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            if let time = account.fetchedAt {
                                Text("\(account.error == nil ? "更新时间" : "上次成功更新")：\(Date(timeIntervalSince1970: time).formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(18).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if rows.isEmpty { Text("先在官方模式登录并保存账号，即可在这里查看多个账号的用量。").foregroundStyle(.secondary).padding(20) }
                }.padding(2)
            }.frame(minHeight: 240, maxHeight: 460)
            Text("窗口打开期间每 5 分钟刷新。重置时间来自官方服务，按本机时区 \(TimeZone.current.identifier) 显示；到点后等待服务确认，不自行归零。第三方 API 用量不计入这里。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 660)
        .onAppear { model.refreshUsage() }
        .onReceive(timer) { _ in model.refreshUsage() }
    }
    func remaining(until date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "已到重置时间，等待刷新" }
        let minutes = Int(ceil(seconds / 60)), days = minutes / 1440, hours = (minutes % 1440) / 60
        if days > 0 { return "约 \(days) 天 \(hours) 小时后" }
        if hours > 0 { return "约 \(hours) 小时 \(minutes % 60) 分钟后" }
        return "约 \(minutes) 分钟后"
    }
}
