import AppKit
import Darwin

/// A GUI app plus all of its helper processes (Chrome renderers, Electron helpers, …).
struct AppUsage: Identifiable {
    let app: NSRunningApplication
    var footprint: UInt64 = 0
    var processCount = 0
    var cpu: Double = 0              // 1.0 == one full core
    var diskPerSec: Double = 0       // read + write

    var id: pid_t { app.processIdentifier }
    var name: String { app.localizedName ?? "pid \(app.processIdentifier)" }
}

/// Groups processes by owning app and turns cumulative CPU / disk counters into rates.
final class AppSampler {
    /// Apps we never offer to quit.
    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.loginwindow",
    ]

    private struct Counters { var cpuNs: UInt64; var diskBytes: UInt64 }
    private var previous: [pid_t: Counters] = [:]
    private var previousAt: Date?

    /// A process's executable can't change while its PID lives, so look each one up once.
    /// nil = not inside any .app bundle (most daemons), so it's skipped without a syscall next time.
    private var pathCache: [pid_t: String?] = [:]
    private var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)

    /// rusage CPU times are in mach absolute time units, not nanoseconds, on Apple Silicon.
    private let machToNs: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return ok == 0 ? info : nil
    }

    /// Cached executable path for processes that live inside an app bundle.
    private func bundledPath(_ pid: pid_t) -> String? {
        if let cached = pathCache[pid] { return cached }
        let n = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = n > 0 ? String(cString: pathBuffer) : nil
        let result = path.flatMap { $0.contains(".app/") ? $0 : nil }
        pathCache[pid] = .some(result)
        return result
    }

    /// Every "<…>.app" prefix of `path`, innermost first, so nested helper bundles
    /// resolve to the most specific running app.
    private static func bundlePrefixes(of path: String) -> [Substring] {
        var prefixes: [Substring] = []
        var search = path.startIndex
        while let r = path.range(of: ".app/", range: search..<path.endIndex) {
            prefixes.append(path[..<r.upperBound])
            search = r.upperBound
        }
        return prefixes.reversed()
    }

    static func allPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) * 2)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(got, 0))))
    }

    /// Regular (Dock-visible) apps, each charged with every process whose binary lives inside its bundle.
    func sample() -> [AppUsage] {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me
                && !Self.protectedBundleIDs.contains($0.bundleIdentifier ?? "")
        }

        var bundleIndex: [Substring: Int] = [:]
        var usages: [AppUsage] = []
        for app in apps {
            guard let url = app.bundleURL else { continue }
            bundleIndex[Substring(url.path + "/")] = usages.count
            usages.append(AppUsage(app: app))
        }

        let now = Date()
        let dt = previousAt.map { max(now.timeIntervalSince($0), 0.001) }
        var current: [pid_t: Counters] = [:]
        let pids = Self.allPIDs()

        for pid in pids where pid > 0 {
            guard let path = bundledPath(pid),
                  let index = Self.bundlePrefixes(of: path).lazy.compactMap({ bundleIndex[$0] }).first,
                  let ru = Self.rusage(pid) else { continue }
            let c = Counters(cpuNs: UInt64(Double(ru.ri_user_time + ru.ri_system_time) * machToNs),
                             diskBytes: ru.ri_diskio_bytesread + ru.ri_diskio_byteswritten)
            current[pid] = c

            usages[index].footprint += ru.ri_phys_footprint
            usages[index].processCount += 1
            if let dt, let p = previous[pid] {
                usages[index].cpu += Double(c.cpuNs &- min(p.cpuNs, c.cpuNs)) / 1e9 / dt
                usages[index].diskPerSec += Double(c.diskBytes &- min(p.diskBytes, c.diskBytes)) / dt
            }
        }

        // Forget exited PIDs so the cache can't grow without bound or match a reused PID.
        let live = Set(pids)
        pathCache = pathCache.filter { live.contains($0.key) }
        previous = current
        previousAt = now
        return usages.filter { $0.processCount > 0 }
    }

    /// Polite quit first; force-quit whatever is still running after `grace` seconds.
    static func quit(_ apps: [NSRunningApplication], grace: TimeInterval = 5) async {
        for app in apps { app.terminate() }
        try? await Task.sleep(for: .seconds(grace))
        for app in apps where !app.isTerminated { app.forceTerminate() }
    }
}
