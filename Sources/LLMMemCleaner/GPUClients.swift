import Darwin
import Foundation
import IOKit

/// A process using the GPU, with its share of GPU time since the last sample.
struct GPUClient: Identifiable {
    let pid: Int
    let name: String
    var gpu: Double              // 0...1 of GPU time (what Activity Monitor shows as GPU %)
    var footprint: UInt64?       // nil for other users' processes (can't read)
    var canStop: Bool
    var id: Int { pid }
}

/// Per-process GPU usage from the accelerator's user clients: each Metal client carries
/// `AppUsage[].accumulatedGPUTime` (ns), which we diff between samples.
final class GPUClientSampler {
    private var previous: [Int: UInt64] = [:]
    private var previousAt: Date?

    func sample() -> [GPUClient] {
        var totals: [Int: (name: String, ns: UInt64)] = [:]

        forEachService("IOAccelerator") { accel in
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &children) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(children) }
            var child = IOIteratorNext(children)
            while child != 0 {
                if let creator = property(child, "IOUserClientCreator") as? String,
                   let (pid, name) = parseUserClientCreator(creator) {
                    let usage = property(child, "AppUsage") as? [[String: Any]] ?? []
                    let ns = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
                    totals[pid, default: (name, 0)].ns += ns
                }
                IOObjectRelease(child)
                child = IOIteratorNext(children)
            }
        }

        let now = Date()
        defer {
            previous = totals.mapValues(\.ns)
            previousAt = now
        }
        guard let at = previousAt else { return [] }
        let dt = max(now.timeIntervalSince(at), 0.001)

        return totals.compactMap { pid, t in
            guard let prev = previous[pid], t.ns > prev else { return nil }
            let share = Double(t.ns - prev) / 1e9 / dt
            guard share >= 0.001 else { return nil }
            return GPUClient(pid: pid, name: executableName(pid) ?? t.name, gpu: min(share, 1),
                             footprint: AppSampler.rusage(pid_t(pid))?.ri_phys_footprint,
                             canStop: kill(pid_t(pid), 0) == 0)
        }
        .sorted { $0.gpu > $1.gpu }
    }
}

/// Parses IOKit's "pid 9860, mlx-serve" user-client creator string.
func parseUserClientCreator(_ s: String) -> (pid: Int, name: String)? {
    guard s.hasPrefix("pid "), let comma = s.firstIndex(of: ","),
          let pid = Int(s[s.index(s.startIndex, offsetBy: 4)..<comma]) else { return nil }
    return (pid, s[s.index(after: comma)...].trimmingCharacters(in: .whitespaces))
}

/// Full executable name; IOKit and `ps` truncate names to 16 characters.
func executableName(_ pid: Int) -> String? {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(Int32(pid), &buf, UInt32(buf.count)) > 0 else { return nil }
    return (String(cString: buf) as NSString).lastPathComponent
}
