import CoreWLAN
import Darwin
import Foundation

struct SpeedTestResult {
    var downloadBps: Double
    var uploadBps: Double
    var rpm: Double           // round-trips per minute under load (Apple's "responsiveness")
    var idleRTTms: Double
    var interface: String

    enum Rating { case low, medium, high }
    /// Apple's own buckets for networkQuality responsiveness.
    var responsiveness: Rating { rpm < 200 ? .low : rpm < 800 ? .medium : .high }
}

struct WiFiInfo {
    var rssi: Int             // dBm
    var noise: Int            // dBm
    var txRateMbps: Double
    var band: String
    var channel: Int

    var snr: Int { rssi - noise }
    enum Quality { case excellent, good, fair, poor }
    var quality: Quality {
        switch rssi {
        case (-55)...: .excellent
        case (-67)...: .good
        case (-75)...: .fair
        default: .poor
        }
    }
}

enum NetworkTools {
    /// Runs macOS's built-in `networkQuality` test (~20–30 s against Apple's CDN).
    static func speedTest() async -> SpeedTestResult? {
        guard let r = await Shell.run("/usr/bin/networkQuality", ["-c"]),
              let data = r.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dl = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              let ul = (json["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
        return SpeedTestResult(downloadBps: dl, uploadBps: ul,
                               rpm: (json["responsiveness"] as? NSNumber)?.doubleValue ?? 0,
                               idleRTTms: (json["base_rtt"] as? NSNumber)?.doubleValue ?? 0,
                               interface: json["interface_name"] as? String ?? "")
    }

    static func wifiInfo() -> WiFiInfo? {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn(), iface.rssiValue() != 0 else { return nil }
        let band: String
        switch iface.wlanChannel()?.channelBand {
        case .band2GHz: band = "2.4 GHz"
        case .band5GHz: band = "5 GHz"
        case .band6GHz: band = "6 GHz"
        default: band = "—"
        }
        return WiFiInfo(rssi: iface.rssiValue(), noise: iface.noiseMeasurement(),
                        txRateMbps: iface.transmitRate(), band: band,
                        channel: iface.wlanChannel()?.channelNumber ?? 0)
    }

    /// Interface carrying the default route (en0 for Wi-Fi on most Macs).
    static func defaultInterface() async -> String? {
        guard let out = await Shell.run("/sbin/route", ["-n", "get", "default"])?.output else { return nil }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "interface" { return parts[1] }
        }
        return nil
    }

    /// Flushes the DNS cache and renews the DHCP lease on `interface` (one admin prompt).
    /// The connection drops for a few seconds while the lease renews.
    static func optimize(interface: String) async -> Bool {
        let safe = interface.filter { $0.isLetter || $0.isNumber }
        let cmd = "dscacheutil -flushcache; killall -HUP mDNSResponder; ipconfig set \(safe) DHCP"
        return await Shell.runAsAdmin(cmd)?.status == 0
    }

    /// SIGTERM a process the user owns; returns false if it isn't ours or is already gone.
    static func terminate(pid: Int) -> Bool {
        kill(pid_t(pid), SIGTERM) == 0
    }
}

func formatMbps(_ bitsPerSec: Double) -> String {
    String(format: bitsPerSec >= 1e9 ? "%.2f Gbps" : "%.0f Mbps", bitsPerSec >= 1e9 ? bitsPerSec / 1e9 : bitsPerSec / 1e6)
}
