import SwiftUI

/// Menu bar tab: third-party menu bar apps with a one-click "crazy" clear.
struct MenuBarTab: View {
    @Bindable var model: MonitorModel
    @State private var alsoStartup = true

    /// Everything not protected is checked until the user changes it.
    private var selection: Set<pid_t> {
        model.menuBarSelection ?? Set(model.menuBarApps.filter { !$0.protected }.map(\.id))
    }

    var body: some View {
        let apps = model.menuBarApps
        let chosen = apps.filter { selection.contains($0.id) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                BigNumber(title: tr("第三方菜单栏应用", "Third-party menu bar apps"), value: "\(apps.count)")
                Spacer()
                Button(tr("系统图标设置", "System icons")) { MenuBarApps.openSettings() }.controlSize(.small)
            }

            Button {
                Task { await model.clearMenuBar(chosen, alsoStartup: alsoStartup) }
            } label: {
                Label(tr("一键疯狂清理菜单栏 · \(chosen.count) 个", "Crazy clear menu bar · \(chosen.count)"), systemImage: "flame")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.orange)
            .disabled(chosen.isEmpty || model.busy)
            Toggle(tr("同时关闭它们的开机启动（可在「启动项」撤销）", "Also stop them opening at login (undo on the Startup tab)"),
                   isOn: $alsoStartup)
                .toggleStyle(.checkbox).font(.caption)

            if apps.isEmpty {
                Text(tr("菜单栏里没有第三方应用。", "No third-party apps in the menu bar."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(apps) { a in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { selection.contains(a.id) },
                        set: { on in
                            var s = selection
                            if on { s.insert(a.id) } else { s.remove(a.id) }
                            model.menuBarSelection = s
                        }))
                        .labelsHidden().toggleStyle(.checkbox)
                    if let icon = a.app.icon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(a.name).font(.callout)
                        if a.protected {
                            Text(tr("安全、VPN 或输入工具，默认保留", "Security, VPN or input tool; kept by default"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(formatBytes(a.memory)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            Divider()
            Text(tr("清理 = 退出这些应用，它们的图标随之消失。Wi-Fi、电池、时钟等系统图标点「系统图标设置」隐藏。",
                    "Clearing quits these apps, which removes their icons. Hide system icons (Wi-Fi, battery, clock…) via System icons."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
