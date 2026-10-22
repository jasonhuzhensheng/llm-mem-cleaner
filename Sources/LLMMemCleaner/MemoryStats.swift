import Darwin
import Foundation

/// System-wide memory snapshot, computed the same way Activity Monitor does.
struct MemoryStats {
    var total: UInt64
    var used: UInt64        // app + wired + compressed
    var wired: UInt64
    var compressed: UInt64
    var swapUsed: UInt64
    var pressureFreePercent: Int  // kern.memorystatus_level: 100 = no pressure

    var available: UInt64 { total > used ? total - used : 0 }

    enum Pressure { case normal, warning, critical }
    var pressure: Pressure {
        switch pressureFreePercent {
        case ..<15: return .critical
        case ..<35: return .warning
        default: return .normal
        }
    }

    static func current() -> MemoryStats {
        let total = ProcessInfo.processInfo.physicalMemory
        let pageSize = UInt64(vm_kernel_page_size)

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        var used: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0
        if kr == KERN_SUCCESS {
            let app = UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count)
            wired = UInt64(vm.wire_count) * pageSize
            compressed = UInt64(vm.compressor_page_count) * pageSize
            used = app * pageSize + wired + compressed
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var level: Int32 = 100
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_level", &level, &levelSize, nil, 0)

        return MemoryStats(total: total, used: used, wired: wired, compressed: compressed,
                           swapUsed: swap.xsu_used, pressureFreePercent: Int(level))
    }
}

/// Rough Q4_K_M footprint (weights + KV cache for a modest context) for common model sizes.
struct ModelTier: Identifiable {
    let name: String
    let requiredBytes: UInt64
    var id: String { name }

    static let all: [ModelTier] = [
        .init(name: "7–8B", requiredBytes: 6 * GB),
        .init(name: "13–14B", requiredBytes: 10 * GB),
        .init(name: "32–34B", requiredBytes: 22 * GB),
        .init(name: "70B", requiredBytes: 44 * GB),
        .init(name: "120B+", requiredBytes: 70 * GB),
    ]
}

let GB: UInt64 = 1 << 30
/// Headroom left for macOS itself when deciding whether a model fits.
let systemReserve: UInt64 = 4 * GB

func formatBytes(_ b: UInt64) -> String {
    String(format: "%.1f GB", Double(b) / Double(GB))
}
