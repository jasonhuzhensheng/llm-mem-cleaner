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
            guard !on else { return tr("请在系统设置中重新添加", "Re-add it in System Settings") }
            let name = item.label.replacingOccurrences(of: "\"", with: "\\\"")
            let r = await Shell.run("/usr/bin/osascript",
                                    ["-e", "tell application \"System Events\" to delete login item \"\(name)\""])
            return r?.status == 0 ? nil : tr("删除失败（需要允许控制“系统事件”）", "Couldn't remove (allow control of System Events)")
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
