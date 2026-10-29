import SwiftUI
import SyncCore

struct ProfileAliasForm: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let profile: ProfileInfo
    @State private var alias: String
    @FocusState private var focused: Bool

    init(model: AppModel, profile: ProfileInfo) {
        self.model = model
        self.profile = profile
        _alias = State(initialValue: profile.alias ?? "")
    }

    private var trimmed: String { alias.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        trimmed.count <= 80 && !trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private var disabled: Bool { model.busy || model.status?.pendingRecovery == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("编辑配置别名").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text(profile.kind == "account" ? "官方账号" : "API 配置").font(.caption).foregroundStyle(.secondary)
                Text("原名称：\(profile.originalName)").textSelection(.enabled)
                Text(profile.detail).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                TextField("别名", text: $alias, prompt: Text(profile.originalName)).textFieldStyle(.roundedBorder).focused($focused)
                Text(valid ? "最多 80 个字符；留空可恢复原名称。" : "请输入最多 80 个字符的单行别名。")
                    .font(.caption).foregroundStyle(valid ? Color.secondary : Color.orange)
            }
            Text("别名用于 Sync Claude 的配置列表、菜单栏和官方账户用量面板，保存后立即生效，无需重启 Claude。")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                if profile.alias != nil {
                    Button("恢复原名称") { model.setAlias(profile, alias: nil); dismiss() }.disabled(disabled)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存别名") { model.setAlias(profile, alias: trimmed.isEmpty ? nil : trimmed); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(disabled || !valid)
            }
        }.padding(28).frame(width: 480).onAppear { focused = true }
    }
}
