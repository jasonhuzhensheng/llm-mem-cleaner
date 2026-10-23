import AppKit
import Darwin

/// Background processes (daemons, agents, helpers) that don't show up as Dock apps,
/// grouped by executable name so e.g. five `node` processes appear as one row.
struct BackgroundProcess: Identifiable {
    enum Kind {
        case own          // ours to stop
        case respawns     // ours, but launchd restarts it (Photos analysis etc.)
        case spotlight    // indexing; fix by excluding folders
        case antivirus    // root + self-protected
        case system       // root or another system user; can't touch
    }

    let name: String
    var pids: [pid_t]
    var bytes: UInt64
    /// true when measured as RSS via `ps` (other users' processes); false for exact phys_footprint.
    var approximate: Bool
    var kind: Kind

    var id: String { name }
}

enum BackgroundProcesses {
    /// Smaller groups aren't worth listing.
    static let minBytes: UInt64 = 50 << 20

    private static let respawning: Set<String> = [
        "photoanalysisd", "photolibraryd", "mediaanalysisd", "corespotlightd", "chronod",
        "suggestd", "knowledge-agent", "cloudd", "bird",
    ]
    private static let spotlight: Set<String> = ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync"]
    /// Run as the user but are part of the desktop itself; stopping them blanks or breaks the UI.
    private static let desktop: Set<String> = [
        "Finder", "Dock", "SystemUIServer", "ControlCenter", "NotificationCenter", "WindowManager",
        "loginwindow", "WallpaperAgent", "WallpaperImageExtension", "Spotlight", "TextInputMenuAgent",
    ]

    static func kind(name: String, path: String, own: Bool) -> BackgroundProcess.Kind {
        let lower = path.lowercased()
        if lower.contains("kaspersky") || lower.contains("antivirus") || name.hasPrefix("kav") { return .antivirus }
        if spotlight.contains(name) { return .spotlight }
        guard own, !desktop.contains(name) else { return .system }
        return respawning.contains(name) ? .respawns : .own
    }

    /// Everything not in `appPIDs`, using `ps` (setuid, so it can see root processes' RSS)
    /// and the exact footprint for our own processes.
    static func sample(excluding appPIDs: Set<pid_t>) async -> [BackgroundProcess] {
        guard let out = await Shell.run("/bin/ps", ["-axo", "pid=,uid=,rss=,comm="])?.output else { return [] }
        let me = getuid()
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var groups: [String: BackgroundProcess] = [:]

        for line in out.split(separator: "\n") {
            // pid, uid, rss are space-separated numbers; the command path may itself contain spaces.
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = pid_t(fields[0]), let uid = uid_t(fields[1]),
                  let rssKB = UInt64(fields[2]), pid > 0, pid != selfPID, !appPIDs.contains(pid) else { continue }
            let path = String(fields[3])
            let name = (path as NSString).lastPathComponent
            let own = uid == me

            var bytes = rssKB * 1024
            var approximate = true
            if own, let fp = AppSampler.rusage(pid)?.ri_phys_footprint {
                bytes = fp
                approximate = false
            }

            if var g = groups[name] {
                g.pids.append(pid)
                g.bytes += bytes
                g.approximate = g.approximate || approximate
                groups[name] = g
            } else {
                groups[name] = BackgroundProcess(name: name, pids: [pid], bytes: bytes, approximate: approximate,
                                                 kind: kind(name: name, path: path, own: own))
            }
        }
        return groups.values.filter { $0.bytes >= minBytes }.sorted { $0.bytes > $1.bytes }
    }

    /// SIGTERM every process in the group; returns how many were stopped.
    static func stop(_ group: BackgroundProcess) -> Int {
        group.pids.filter { kill($0, SIGTERM) == 0 }.count
    }

    static func openSpotlightPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!)
    }
}
