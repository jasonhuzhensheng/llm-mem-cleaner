import AppKit
import Darwin

/// System-level memory savers: things macOS runs in the background that a local-LLM machine
/// can do without. Each reports what it costs now and how to turn it off.
struct SystemTweaks {
    /// A volume holding model files, and whether Spotlight indexes it.
    struct ModelVolume: Identifiable {
        let path: String
        var indexing: Bool
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    var modelVolumes: [ModelVolume] = []
    /// Model folders on the startup disk; these can only be excluded in System Settings.
    var homeModelFolders: [String] = []
    var spotlightMemory: UInt64 = 0

    var analysisPaused = false
    var analysisMemory: UInt64 = 0

    var intelligenceMemory: UInt64 = 0

    /// nil when the setting couldn't be read.
    var reduceTransparency: Bool?
    var windowServerMemory: UInt64 = 0

    var antivirus: (name: String, app: URL, memory: UInt64)?

    /// GPU memory the driver keeps allocated beyond what clients use; only a restart returns it.
    var gpuHeld: UInt64 = 0
}

enum SystemTweaksService {
    static let analysisLabels = ["com.apple.photoanalysisd", "com.apple.mediaanalysisd"]
    private static let analysisNames: Set<String> = ["photoanalysisd", "mediaanalysisd", "mediaanalysisd-access"]
    private static let spotlightNames: Set<String> = ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync",
                                                      "corespotlightd", "spotlightknowledged", "spotlightknowledged.importer",
                                                      "spotlightknowledged.updater"]
    private static let intelligenceMarkers = ["Intelligence", "siriknowledged", "knowledge-agent", "TGOnDevice",
                                              "generativeexperiencesd", "modelmanagerd", "/Siri", "knowledgeconstructiond"]
    private static let antivirusApps = ["Kaspersky", "Avast", "AVG", "Norton", "Sophos", "ESET", "Bitdefender",
                                        "Malwarebytes", "Intego", "McAfee", "Trend Micro"]
    private static let accessibilityDisplay = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display")!
    private static let intelligenceSettings = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!

    static func load() async -> SystemTweaks {
        var t = SystemTweaks()
        let usage = await processMemory()
        func sum(_ match: (String) -> Bool) -> UInt64 {
            usage.filter { match($0.path) }.reduce(0) { $0 + $1.bytes }
        }
        let name = { (p: String) in (p as NSString).lastPathComponent }
        t.spotlightMemory = sum { spotlightNames.contains(name($0)) }
        t.analysisMemory = sum { analysisNames.contains(name($0)) }
        t.intelligenceMemory = sum { p in intelligenceMarkers.contains { p.contains($0) } }
        t.windowServerMemory = sum { name($0) == "WindowServer" }

        // Model locations: the Hugging Face cache (often on an external disk) plus the usual runtimes.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var folders = ["\(home)/.ollama/models", "\(home)/.lmstudio/models", "\(home)/.cache/huggingface"]
        if let hf = await huggingFaceCache() { folders.insert(hf, at: 0) }
        var volumes: [String] = []
        for f in folders where FileManager.default.fileExists(atPath: f) {
            if f.hasPrefix("/Volumes/") {
                let parts = f.split(separator: "/", maxSplits: 2)
                if parts.count >= 2 { volumes.append("/Volumes/" + parts[1]) }
            } else {
                t.homeModelFolders.append(f)
            }
        }
        for v in Set(volumes).sorted() {
            t.modelVolumes.append(.init(path: v, indexing: await spotlightIndexing(v)))
        }

        let disabled = await Shell.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"])?.output ?? ""
        t.analysisPaused = analysisLabels.allSatisfy { disabled.contains("\"\($0)\" => disabled") || disabled.contains("\"\($0)\" => true") }

        if let r = await Shell.run("/usr/bin/defaults", ["read", "com.apple.universalaccess", "reduceTransparency"]) {
            t.reduceTransparency = r.status == 0 ? r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                : r.output.contains("does not exist") || r.output.contains("Could not find") ? false : nil
        }

        if let app = antivirusApps.lazy.compactMap(findApp).first {
            let vendor = app.deletingPathExtension().lastPathComponent
            let key = vendor.split(separator: " ").first.map(String.init) ?? vendor
            let lowerKey = key.lowercased()
            let mem = sum { p in p.lowercased().contains(lowerKey) || (lowerKey == "kaspersky" && name(p).hasPrefix("kav")) }
            t.antivirus = (vendor, app, mem)
        }

        let gpu = GPUStats.current()
        t.gpuHeld = gpu.allocatedMemory > gpu.inUseMemory ? gpu.allocatedMemory - gpu.inUseMemory : 0
        return t
    }

    // MARK: Actions

    /// Turns Spotlight indexing of a whole volume on or off (admin prompt).
    static func setIndexing(_ volume: String, on: Bool) async -> Bool {
        let quoted = "'" + volume.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return await Shell.runAsAdmin("mdutil -i \(on ? "on" : "off") \(quoted)")?.status == 0
    }

    /// Pauses Photos/media analysis: disabled in launchd (so it isn't relaunched) and stopped now.
    /// Resuming re-enables them; macOS starts them again when it needs to.
    static func setAnalysisPaused(_ paused: Bool) async -> Bool {
        let domain = "gui/\(getuid())"
        var ok = true
        for label in analysisLabels {
            let r = await Shell.run("/bin/launchctl", [paused ? "disable" : "enable", "\(domain)/\(label)"])
            ok = ok && r?.status == 0
        }
        if paused {
            for pid in AppSampler.allPIDs() where pid > 0 {
                if let n = executableName(Int(pid)), analysisNames.contains(n) { kill(pid, SIGTERM) }
            }
        }
        return ok
    }

    /// Writes the accessibility setting; if macOS refuses (it may require Full Disk Access),
    /// opens the setting instead. Returns true when it was written.
    static func setReduceTransparency(_ on: Bool) async -> Bool {
        let r = await Shell.run("/usr/bin/defaults", ["write", "com.apple.universalaccess", "reduceTransparency", "-bool", on ? "true" : "false"])
        if r?.status == 0 { return true }
        NSWorkspace.shared.open(accessibilityDisplay)
        return false
    }

    static func openIntelligenceSettings() { NSWorkspace.shared.open(intelligenceSettings) }

    static func openSpotlightPrivacy(revealing folders: [String]) {
        BackgroundProcesses.openSpotlightPrivacy()
        NSWorkspace.shared.activateFileViewerSelecting(folders.map { URL(fileURLWithPath: $0) })
    }

    static func open(_ app: URL) { NSWorkspace.shared.open(app) }

    // MARK: Helpers

    /// Footprint for our own processes, RSS via `ps` for root/system ones.
    private static func processMemory() async -> [(path: String, bytes: UInt64)] {
        guard let out = await Shell.run("/bin/ps", ["-axo", "pid=,uid=,rss=,comm="])?.output else { return [] }
        let me = getuid()
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = pid_t(f[0]), let uid = uid_t(f[1]), let rss = UInt64(f[2]) else { return nil }
            let path = String(f[3])
            let bytes = uid == me ? (AppSampler.rusage(pid)?.ri_phys_footprint ?? rss * 1024) : rss * 1024
            return (path, bytes)
        }
    }

    private static func huggingFaceCache() async -> String? {
        if let env = ProcessInfo.processInfo.environment["HF_HUB_CACHE"], !env.isEmpty { return env }
        let out = await Shell.run("/bin/launchctl", ["getenv", "HF_HUB_CACHE"])?.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out?.isEmpty == false ? out : nil
    }

    private static func spotlightIndexing(_ volume: String) async -> Bool {
        let out = await Shell.run("/usr/bin/mdutil", ["-s", volume])?.output ?? ""
        return out.contains("Indexing enabled")
    }

    private static func findApp(_ vendor: String) -> URL? {
        let dir = URL(fileURLWithPath: "/Applications")
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        // Prefer the antivirus product over a vendor's VPN or password manager.
        let matches = apps.filter { $0.hasPrefix(vendor) && $0.hasSuffix(".app") }
        let pick = matches.first { $0.localizedCaseInsensitiveContains("virus") || $0.localizedCaseInsensitiveContains("security") } ?? matches.first
        return pick.map { dir.appending(path: $0) }
    }
}
