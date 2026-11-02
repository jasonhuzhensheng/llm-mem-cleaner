import Foundation

/// Something that starts automatically: launchd agents/daemons, Homebrew services, legacy login items.
struct StartupItem: Identifiable {
    enum Kind: String, CaseIterable {
        case loginItem, userAgent, globalAgent, daemon, brew

        var title: String {
            switch self {
            case .loginItem: tr("登录项", "Login items")
            case .userAgent: tr("用户代理", "User agents")
            case .globalAgent: tr("全局代理", "Global agents")
            case .daemon: tr("系统守护进程", "System daemons")
            case .brew: tr("Homebrew 服务", "Homebrew services")
            }
        }

        var needsAdmin: Bool { self == .daemon }
    }

    let kind: Kind
    let label: String
    let path: String?         // plist (launchd/brew) or app path (login item)
    let program: String?
    var enabled: Bool
    var running: Bool

    var id: String { "\(kind.rawValue)|\(label)" }
}

enum StartupItems {
    static let uid = getuid()
    static let launchctl = "/bin/launchctl"
    static let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    static func load() async -> [StartupItem] {
        async let guiDisabled = disabledLabels(domain: "gui/\(uid)")
        async let sysDisabled = disabledLabels(domain: "system")
        async let running = runningLabels()
        async let brewItems = brewServices()
        async let loginItems = legacyLoginItems()

        let (gd, sd, run) = await (guiDisabled, sysDisabled, running)
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var items: [StartupItem] = []
        let dirs: [(String, StartupItem.Kind)] = [
            ("\(home)/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .globalAgent),
            ("/Library/LaunchDaemons", .daemon),
        ]
        for (dir, kind) in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for file in files.sorted() where file.hasSuffix(".plist") {
                let path = "\(dir)/\(file)"
                guard let data = FileManager.default.contents(atPath: path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String,
                      !label.hasPrefix("homebrew.mxcl.")  // listed under Homebrew instead
                else { continue }
                let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                let disabledSet = kind == .daemon ? sd : gd
                let plistDisabled = plist["Disabled"] as? Bool ?? false
                items.append(StartupItem(kind: kind, label: label, path: path, program: program,
                                         enabled: !(disabledSet[label] ?? plistDisabled),
                                         running: run.contains(label)))
            }
        }
        items += await brewItems
        items += await loginItems
        return items
    }

    /// Parses `launchctl print-disabled <domain>` → label: isDisabled.
    private static func disabledLabels(domain: String) async -> [String: Bool] {
        guard let out = await Shell.run(launchctl, ["print-disabled", domain])?.output else { return [:] }
        var result: [String: Bool] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            result[label] = value == "disabled" || value == "true"
        }
        return result
    }

    /// Labels in the user's launchd domain that currently have a live PID.
    private static func runningLabels() async -> Set<String> {
        guard let out = await Shell.run(launchctl, ["list"])?.output else { return [] }
        var set = Set<String>()
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t")
            if cols.count == 3, cols[0] != "-" { set.insert(String(cols[2])) }
        }
        return set
    }

    private static func brewServices() async -> [StartupItem] {
        guard let brew, let out = await Shell.run(brew, ["services", "list", "--json"])?.output,
              let data = out.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { s in
            guard let name = s["name"] as? String else { return nil }
            let status = s["status"] as? String ?? "none"
            return StartupItem(kind: .brew, label: name, path: s["file"] as? String, program: nil,
                               enabled: status == "started" || status == "scheduled",
                               running: status == "started")
        }
    }

    /// "Open at Login" apps added the classic way (needs Automation permission for System Events).
    private static func legacyLoginItems() async -> [StartupItem] {
        let script = """
        tell application "System Events"
          set out to ""
          repeat with i in every login item
            set out to out & (name of i) & tab & (path of i) & linefeed
          end repeat
          return out
        end tell
        """
        guard let r = await Shell.run("/usr/bin/osascript", ["-e", script]), r.status == 0 else { return [] }
        return r.output.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let name = cols.first, !name.isEmpty else { return nil }
            return StartupItem(kind: .loginItem, label: name, path: cols.count > 1 ? cols[1] : nil,
                               program: nil, enabled: true, running: false)
        }
    }

    /// Turns an item off (and stops it) or back on. Returns an error message on failure.
    static func setEnabled(_ item: StartupItem, _ on: Bool) async -> String? {
        let domain = "gui/\(uid)"
        switch item.kind {
        case .userAgent, .globalAgent:
            guard let path = item.path else { return tr("缺少 plist 路径", "Missing plist path") }
            if on {
                _ = await Shell.run(launchctl, ["enable", "\(domain)/\(item.label)"])
                _ = await Shell.run(launchctl, ["bootstrap", domain, path])
            } else {
                _ = await Shell.run(launchctl, ["bootout", domain, path])
                _ = await Shell.run(launchctl, ["disable", "\(domain)/\(item.label)"])
            }
            return nil

        case .daemon:
            guard let path = item.path else { return tr("缺少 plist 路径", "Missing plist path") }
            let label = shellQuote(item.label), plist = shellQuote(path)
            let cmd = on
                ? "launchctl enable system/\(label); launchctl bootstrap system \(plist) || true"
                : "launchctl bootout system/\(label) || true; launchctl disable system/\(label)"
            guard let r = await Shell.runAsAdmin(cmd), r.status == 0 else { return tr("已取消或需要管理员权限", "Cancelled or admin rights required") }
            return nil

        case .brew:
            guard let brew else { return tr("未找到 brew", "brew not found") }
            let r = await Shell.run(brew, ["services", on ? "start" : "stop", item.label])
            return r?.status == 0 ? nil : (r?.output ?? tr("brew 执行失败", "brew failed"))

        case .loginItem:
            if on {
                guard let path = item.path else { return tr("请在系统设置中重新添加", "Re-add it in System Settings") }
                let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
                let r = await Shell.run("/usr/bin/osascript", ["-e",
                    "tell application \"System Events\" to make login item at end with properties {path:\"\(escaped)\", hidden:false}"])
                return r?.status == 0 ? nil : tr("重新添加失败（需要允许控制“系统事件”）", "Couldn't re-add (allow control of System Events)")
            }
            let name = item.label.replacingOccurrences(of: "\"", with: "\\\"")
            let r = await Shell.run("/usr/bin/osascript",
                                    ["-e", "tell application \"System Events\" to delete login item \"\(name)\""])
            return r?.status == 0 ? nil : tr("删除失败（需要允许控制“系统事件”）", "Couldn't remove (allow control of System Events)")
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// "Crazy cleanup": every startup item that isn't needed for the Mac, security or the user's own
/// automations, pre-checked, with a one-click undo of the last run.
struct StartupSuggestion: Identifiable {
    enum Tier: Int { case recommended, optional, keep }
    let item: StartupItem
    let tier: Tier
    let reason: String
    var id: String { item.id }
}

enum StartupCleanup {
    private static let undoKey = "startupCleanupUndo"

    private static let updaterMarkers = ["update", "keystone", "sparkle", "syncreporter", "reporter", "telemetry",
                                         "crash", "steamclean", "epicgames", "ccxprocess", "adobe", "launcher"]
    /// Security, VPN, input, drivers and sync clients whose loss is surprising or risky.
    private static let keepMarkers = ["kaspersky", "expressvpn", "nordvpn", "tailscale", "wireguard", "1password",
                                      "bitwarden", "littlesnitch", "objective-see", "lulu", "karabiner", "inputmethod",
                                      "logi", "wacom", "displaylink", "elgato", "rogueamoeba", "audio", "bluetooth"]

    static func suggestions(_ items: [StartupItem]) -> [StartupSuggestion] {
        let user = NSUserName().lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let selfBundle = Bundle.main.bundleIdentifier ?? "local.llm-mem-cleaner"
        return items.filter(\.enabled).map { item in
            let text = (item.label + " " + (item.program ?? "") + " " + (item.path ?? "")).lowercased()
            let program = item.program ?? ""
            func s(_ tier: StartupSuggestion.Tier, _ zh: String, _ en: String) -> StartupSuggestion {
                StartupSuggestion(item: item, tier: tier, reason: tr(zh, en))
            }
            if text.contains(selfBundle.lowercased()) || text.contains("llmmemcleaner") || text.contains("llm mem cleaner") {
                return s(.keep, "本软件", "This app")
            }
            if item.label.lowercased().contains(user) || item.label.hasPrefix("local.") || item.label.hasPrefix("com.codex.")
                || program.hasPrefix("/usr/bin/python") || program.hasPrefix("/bin/") || program.hasSuffix(".sh") {
                return s(.keep, "你自己的脚本或工具", "Your own script or tool")
            }
            if keepMarkers.contains(where: text.contains) {
                return s(.keep, "安全、VPN、输入法或驱动，关掉可能出问题", "Security, VPN, input or driver; risky to turn off")
            }
            if program.hasPrefix("/"), !program.hasPrefix(home + "/Library/LaunchAgents"),
               !FileManager.default.fileExists(atPath: program) {
                return s(.recommended, "程序已不存在（残留）", "Program no longer exists (leftover)")
            }
            if updaterMarkers.contains(where: text.contains) {
                return s(.recommended, "更新器、启动器或统计上报，用到时会自己再启动", "Updater, launcher or telemetry; starts again when needed")
            }
            switch item.kind {
            case .loginItem:
                return s(.optional, "开机后不再自动打开，需要时手动打开", "Won't open at login; open it yourself when needed")
            case .brew:
                return s(.optional, "Homebrew 服务，需要时用 brew services start", "Homebrew service; start it with brew services when needed")
            default:
                return s(.optional, "第三方后台服务，对应软件的部分功能可能要手动启动", "Third-party background service; parts of its app may need starting by hand")
            }
        }
        .sorted { ($0.tier.rawValue, $0.item.label) < ($1.tier.rawValue, $1.item.label) }
    }

    /// Turns the items off; system daemons go through a single admin prompt. Saves an undo record.
    static func disable(_ items: [StartupItem]) async -> (done: [StartupItem], failed: [String]) {
        var done: [StartupItem] = [], failed: [String] = []
        let daemons = items.filter { $0.kind == .daemon && $0.path != nil }
        if !daemons.isEmpty {
            let cmd = daemons.map { d in
                let label = StartupItems.shellQuote(d.label)
                return "launchctl bootout system/\(label) || true; launchctl disable system/\(label)"
            }.joined(separator: "; ")
            if let r = await Shell.runAsAdmin(cmd), r.status == 0 { done += daemons } else { failed += daemons.map(\.label) }
        }
        for item in items where item.kind != .daemon {
            if await StartupItems.setEnabled(item, false) == nil { done.append(item) } else { failed.append(item.label) }
        }
        saveUndo(done)
        return (done, failed)
    }

    // MARK: Undo

    private struct Record: Codable { let kind: String; let label: String; let path: String?; let program: String? }

    static var hasUndo: Bool { UserDefaults.standard.data(forKey: undoKey) != nil }

    /// Appends to the existing record so several cleanups can all be undone.
    private static func saveUndo(_ items: [StartupItem]) {
        guard !items.isEmpty else { return }
        let old = UserDefaults.standard.data(forKey: undoKey).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        let records = old + items.map { Record(kind: $0.kind.rawValue, label: $0.label, path: $0.path, program: $0.program) }
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: undoKey)
    }

    /// Turns everything from the last cleanup back on.
    static func undo() async -> [String] {
        guard let data = UserDefaults.standard.data(forKey: undoKey),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        let items = records.compactMap { r in
            StartupItem.Kind(rawValue: r.kind).map {
                StartupItem(kind: $0, label: r.label, path: r.path, program: r.program, enabled: false, running: false)
            }
        }
        var failed: [String] = []
        let daemons = items.filter { $0.kind == .daemon && $0.path != nil }
        if !daemons.isEmpty {
            let cmd = daemons.map { d in
                "launchctl enable system/\(StartupItems.shellQuote(d.label)); launchctl bootstrap system \(StartupItems.shellQuote(d.path!)) || true"
            }.joined(separator: "; ")
            if await Shell.runAsAdmin(cmd)?.status != 0 { failed += daemons.map(\.label) }
        }
        for item in items where item.kind != .daemon {
            if await StartupItems.setEnabled(item, true) != nil { failed.append(item.label) }
        }
        if failed.isEmpty { UserDefaults.standard.removeObject(forKey: undoKey) }
        return failed
    }
}
