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

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
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

        // Longest bundle path first so nested bundles match the most specific app.
        var byBundle: [(prefix: String, index: Int)] = []
        var usages: [AppUsage] = []
        for app in apps {
            guard let url = app.bundleURL else { continue }
            byBundle.append((url.path + "/", usages.count))
            usages.append(AppUsage(app: app))
        }
        byBundle.sort { $0.prefix.count > $1.prefix.count }

        let now = Date()
        let dt = previousAt.map { max(now.timeIntervalSince($0), 0.001) }
        var current: [pid_t: Counters] = [:]

        for pid in Self.allPIDs() where pid > 0 {
            guard let path = Self.executablePath(pid),
                  let match = byBundle.first(where: { path.hasPrefix($0.prefix) }),
                  let ru = Self.rusage(pid) else { continue }
            let c = Counters(cpuNs: UInt64(Double(ru.ri_user_time + ru.ri_system_time) * machToNs),
                             diskBytes: ru.ri_diskio_bytesread + ru.ri_diskio_byteswritten)
            current[pid] = c

            usages[match.index].footprint += ru.ri_phys_footprint
            usages[match.index].processCount += 1
            if let dt, let p = previous[pid] {
                usages[match.index].cpu += Double(c.cpuNs &- min(p.cpuNs, c.cpuNs)) / 1e9 / dt
                usages[match.index].diskPerSec += Double(c.diskBytes &- min(p.diskBytes, c.diskBytes)) / dt
            }
        }

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
