import SwiftUI

/// One-click "crazy" startup cleanup on the Startup tab.
struct StartupCleanupSection: View {
    @Bindable var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let list = model.startupSuggestions {
                suggestions(list)
            } else {
                Button {
                    Task { await model.planStartupCleanup() }
                } label: {
                    Label(tr("一键疯狂清理启动项", "Crazy startup cleanup"), systemImage: "flame")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.orange)
                .disabled(model.busy)
                if model.startupUndoAvailable {
                    Button(tr("撤销上次清理", "Undo last cleanup")) { Task { await model.undoStartupCleanup() } }
                        .controlSize(.small).disabled(model.busy)
                }
            }
        }
    }

    @ViewBuilder private func suggestions(_ list: [StartupSuggestion]) -> some View {
        let groups: [(StartupSuggestion.Tier, String)] = [
            (.recommended, tr("建议关闭", "Recommended")),
            (.optional, tr("也可以关（疯狂模式已勾选）", "Also off in crazy mode")),
            (.keep, tr("保留", "Kept")),
        ]
        if list.isEmpty {
            Text(tr("没有启用中的启动项。", "No enabled startup items.")).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(groups, id: \.0) { tier, title in
            let items = list.filter { $0.tier == tier }
            if !items.isEmpty {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(items) { s in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { model.startupSelection.contains(s.id) },
                            set: { on in if on { model.startupSelection.insert(s.id) } else { model.startupSelection.remove(s.id) } }))
                            .labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.item.label).font(.callout).lineLimit(1).truncationMode(.middle)
                            Text("\(s.item.kind.title) · \(s.reason)").font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                }
            }
        }
        HStack {
            Button {
                Task { await model.runStartupCleanup() }
            } label: {
                Text(tr("关闭选中的 \(model.startupSelection.count) 项", "Turn off \(model.startupSelection.count) items"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.orange)
            .disabled(model.startupSelection.isEmpty || model.busy)
            Button(tr("取消", "Cancel")) { model.startupSuggestions = nil }.disabled(model.busy)
        }
        Text(tr("关闭 = 停止并禁止开机启动，文件保留。系统守护进程会统一弹一次管理员密码。可随时「撤销上次清理」。",
                "Off = stopped and blocked at login; files are kept. System daemons share one admin prompt. Undo any time."))
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
