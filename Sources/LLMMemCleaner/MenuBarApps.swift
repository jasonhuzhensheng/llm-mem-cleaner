import AppKit

/// Third-party menu bar apps: running agent (LSUIElement) apps installed in an Applications folder.
/// macOS draws every status item through one MenuBarAgent window, so the owning apps are the
/// unit we can list and quit without Accessibility permission.
struct MenuBarApp: Identifiable {
    let app: NSRunningApplication
    let memory: UInt64
    /// Kept by default: security, VPN, password managers, input tools.
    let protected: Bool
    var id: pid_t { app.processIdentifier }
    var name: String { app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "?" }
}

enum MenuBarApps {
    private static let protectedMarkers = ["1password", "bitwarden", "vpn", "tailscale", "wireguard", "littlesnitch",
                                           "lulu", "kaspersky", "karabiner", "inputmethod", "logi"]
    private static let settings = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!

    static func scan() -> [MenuBarApp] {
        let me = ProcessInfo.processInfo.processIdentifier
        let selfID = Bundle.main.bundleIdentifier ?? "local.llm-mem-cleaner"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .accessory, app.processIdentifier != me, app.bundleIdentifier != selfID,
                  let path = app.bundleURL?.path,
                  path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/"),
                  // Helpers nested in another app (…/Foo.app/Contents/…/Helper.app) aren't menu bar apps.
                  path.components(separatedBy: ".app/").count == 1,
                  !(app.bundleIdentifier ?? "").hasPrefix("com.apple.") else { return nil }
            let key = ((app.bundleIdentifier ?? "") + " " + path).lowercased()
            return MenuBarApp(app: app, memory: AppSampler.rusage(app.processIdentifier)?.ri_phys_footprint ?? 0,
                              protected: protectedMarkers.contains(where: key.contains))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Startup entries that would bring these apps back at login (login items, launch agents in their bundle).
    static func startupEntries(for apps: [MenuBarApp], in items: [StartupItem]) -> [StartupItem] {
        items.filter { item in
            item.enabled && apps.contains { a in
                guard let bundle = a.app.bundleURL?.path else { return false }
                return [item.path, item.program].contains { $0?.hasPrefix(bundle) ?? false }
                    || (item.kind == .loginItem && item.label == a.name)
                    || item.label == a.app.bundleIdentifier
            }
        }
    }

    static func openSettings() { NSWorkspace.shared.open(settings) }
}
