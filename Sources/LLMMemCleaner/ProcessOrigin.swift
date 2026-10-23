import Darwin
import Foundation

/// Who a process belongs to: macOS itself, or the user (apps, tools and third-party services).
enum ProcessOrigin {
    case user, system

    /// Locations only macOS installs into (sealed system volume and Apple-managed folders).
    private static let systemPrefixes = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/usr/lib/", "/sbin/", "/bin/",
        "/Library/Apple/", "/private/var/db/",
    ]

    /// Classifies by install location. When the path can't be read (sandboxed children,
    /// processes that renamed themselves), falls back to ownership: ours → user, else system.
    static func of(path: String?, pid: Int) -> ProcessOrigin {
        guard let path, path.hasPrefix("/") else {
            return kill(pid_t(pid), 0) == 0 && getuid() != 0 ? .user : .system
        }
        return systemPrefixes.contains { path.hasPrefix($0) } ? .system : .user
    }

    static func of(pid: Int) -> ProcessOrigin { of(path: executablePath(pid), pid: pid) }
}

func executablePath(_ pid: Int) -> String? {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(Int32(pid), &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
}

/// Full executable name; IOKit and `ps` truncate names to 16 characters.
func executableName(_ pid: Int) -> String? {
    executablePath(pid).map { ($0 as NSString).lastPathComponent }
}
