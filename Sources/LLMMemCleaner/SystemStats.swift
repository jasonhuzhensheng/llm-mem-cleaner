import Darwin
import Foundation
import IOKit

// MARK: - CPU

/// Whole-machine CPU usage from per-core tick counters; needs two samples to produce a rate.
final class CPUSampler {
    struct Snapshot {
        var total: Double = 0          // 0...1
        var perCore: [Double] = []
        var load1: Double = 0
    }

    private var previous: [(busy: UInt64, total: UInt64)] = []

    func sample() -> Snapshot {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return Snapshot() }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var current: [(busy: UInt64, total: UInt64)] = []
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            current.append((user + sys + nice, user + sys + nice + idle))
        }

        var snap = Snapshot()
        if previous.count == current.count {
            var busySum: UInt64 = 0, totalSum: UInt64 = 0
            snap.perCore = zip(previous, current).map { prev, cur in
                let busy = cur.busy &- prev.busy, total = cur.total &- prev.total
                busySum += busy; totalSum += total
                return total > 0 ? Double(busy) / Double(total) : 0
            }
            snap.total = totalSum > 0 ? Double(busySum) / Double(totalSum) : 0
        }
        previous = current

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        snap.load1 = loads[0]
        return snap
    }
}

// MARK: - GPU

struct GPUStats {
    var model = "GPU"
    var cores = 0
    var utilization = 0           // Device Utilization %
    var inUseMemory: UInt64 = 0   // memory currently held by GPU clients
    var wiredLimit: UInt64 = 0    // max memory the GPU may wire (unified memory)
    var wiredLimitIsDefault = true

    /// Model name and core count never change, so read them once.
    private static let identity: (model: String, cores: Int) = {
        var result = (model: "GPU", cores: 0)
        forEachService("IOAccelerator") { service in
            if let m = property(service, "model") as? String { result.model = m }
            if let c = property(service, "gpu-core-count") as? NSNumber { result.cores = c.intValue }
        }
        return result
    }()

    static func current() -> GPUStats {
        var stats = GPUStats()
        (stats.model, stats.cores) = identity
        forEachService("IOAccelerator") { service in
            // Read just this key instead of copying the accelerator's whole property table.
            if let perf = property(service, "PerformanceStatistics") as? [String: Any] {
                stats.utilization = (perf["Device Utilization %"] as? NSNumber)?.intValue ?? 0
                stats.inUseMemory = (perf["In use system memory"] as? NSNumber)?.uint64Value ?? 0
            }
        }

        let total = ProcessInfo.processInfo.physicalMemory
        var mb: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("iogpu.wired_limit_mb", &mb, &size, nil, 0)
        if mb > 0 {
            stats.wiredLimit = UInt64(mb) << 20
            stats.wiredLimitIsDefault = false
        } else {
            // macOS default: ~2/3 of RAM up to 36 GB, ~3/4 above.
            stats.wiredLimit = total > 36 * GB ? total / 4 * 3 : total / 3 * 2
        }
        return stats
    }
}

func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

func forEachService(_ className: String, _ body: (io_registry_entry_t) -> Void) {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iter) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iter) }
    var service = IOIteratorNext(iter)
    while service != 0 {
        body(service)
        IOObjectRelease(service)
        service = IOIteratorNext(iter)
    }
}

// MARK: - Disk

struct VolumeInfo {
    var total: UInt64 = 0
    var available: UInt64 = 0

    static func root() -> VolumeInfo {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return VolumeInfo() }
        return VolumeInfo(total: UInt64(v.volumeTotalCapacity ?? 0),
                          available: UInt64(v.volumeAvailableCapacityForImportantUsage ?? 0))
    }
}

/// Disk throughput summed over every block storage driver.
final class DiskIOSampler {
    private var previous: (read: UInt64, write: UInt64, at: Date)?

    func sample() -> (readPerSec: Double, writePerSec: Double) {
        var read: UInt64 = 0, write: UInt64 = 0
        forEachService("IOBlockStorageDriver") { service in
            if let s = property(service, "Statistics") as? [String: Any] {
                read += (s["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (s["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
        }
        let now = Date()
        defer { previous = (read, write, now) }
        guard let p = previous else { return (0, 0) }
        let dt = max(now.timeIntervalSince(p.at), 0.001)
        return (Double(read &- p.read) / dt, Double(write &- p.write) / dt)
    }
}

// MARK: - Network

struct InterfaceRate: Identifiable {
    let name: String
    var inPerSec: Double
    var outPerSec: Double
    var id: String { name }
}

/// Per-interface throughput from getifaddrs link counters (32-bit, so wrap-around is handled).
final class NetworkSampler {
    private var previous: [String: (inB: UInt32, outB: UInt32)] = [:]
    private var previousAt: Date?

    func sample() -> [InterfaceRate] {
        var current: [String: (inB: UInt32, outB: UInt32)] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("lo") { continue }
            current[name] = (data.pointee.ifi_ibytes, data.pointee.ifi_obytes)
        }

        let now = Date()
        defer { previous = current; previousAt = now }
        guard let at = previousAt else { return [] }
        let dt = max(now.timeIntervalSince(at), 0.001)
        return current.compactMap { name, cur in
            guard let p = previous[name] else { return nil }
            return InterfaceRate(name: name,
                                 inPerSec: Double(cur.inB &- p.inB) / dt,
                                 outPerSec: Double(cur.outB &- p.outB) / dt)
        }
        .sorted { $0.inPerSec + $0.outPerSec > $1.inPerSec + $1.outPerSec }
    }
}

/// Per-process network throughput via `nettop` (cumulative byte counters, diffed between samples).
final class ProcessNetworkSampler {
    struct Row: Identifiable {
        let name: String
        let pid: Int
        var inPerSec: Double
        var outPerSec: Double
        var id: Int { pid }
    }

    private var previous: [Int: (inB: UInt64, outB: UInt64)] = [:]
    private var previousAt: Date?

    func sample() async -> [Row] {
        guard let out = await Shell.run("/usr/bin/nettop", ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"])?.output
        else { return [] }

        var current: [Int: (name: String, inB: UInt64, outB: UInt64)] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, let dot = cols[0].lastIndex(of: "."),
                  let pid = Int(cols[0][cols[0].index(after: dot)...]),
                  let inB = UInt64(cols[1]), let outB = UInt64(cols[2]) else { continue }
            current[pid] = (String(cols[0][..<dot]), inB, outB)
        }

        let now = Date()
        defer {
            previous = current.mapValues { ($0.inB, $0.outB) }
            previousAt = now
        }
        guard let at = previousAt else { return [] }
        let dt = max(now.timeIntervalSince(at), 0.001)
        return current.compactMap { pid, cur in
            guard let p = previous[pid] else { return nil }
            let r = Row(name: cur.name, pid: pid,
                        inPerSec: Double(cur.inB &- min(p.inB, cur.inB)) / dt,
                        outPerSec: Double(cur.outB &- min(p.outB, cur.outB)) / dt)
            return r.inPerSec + r.outPerSec > 0 ? r : nil
        }
        .sorted { $0.inPerSec + $0.outPerSec > $1.inPerSec + $1.outPerSec }
    }
}

func formatRate(_ bytesPerSec: Double) -> String {
    switch bytesPerSec {
    case ..<1024: String(format: "%.0f B/s", bytesPerSec)
    case ..<(1024 * 1024): String(format: "%.1f KB/s", bytesPerSec / 1024)
    case ..<(1024 * 1024 * 1024): String(format: "%.1f MB/s", bytesPerSec / 1024 / 1024)
    default: String(format: "%.2f GB/s", bytesPerSec / 1024 / 1024 / 1024)
    }
}

// MARK: - Shell helpers

enum Shell {
    struct Result { let status: Int32; let output: String }

    /// Runs a binary off the main thread and captures stdout+stderr.
    static func run(_ exe: String, _ args: [String]) async -> Result? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Runs a shell command as root, showing the standard macOS admin password prompt.
    static func runAsAdmin(_ command: String) async -> Result? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return await run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }
}
