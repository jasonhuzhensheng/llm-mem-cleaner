import Foundation
import IOKit

/// Apple Neural Engine (ANE) status.
///
/// macOS exposes no ANE utilization to unprivileged apps (the IOReport energy counters for
/// CPU/ANE stay frozen without root), so instead we list which processes currently hold a
/// connection to the ANE driver — each one is a process running a model on it.
struct NeuralEngineStatus {
    struct Client: Identifiable {
        let pid: Int
        let name: String
        var connections: Int
        var origin: ProcessOrigin = .user
        var id: Int { pid }
    }

    var cores = 0
    var architecture = ""
    var clients: [Client] = []

    var inUse: Bool { !clients.isEmpty }
}

enum NeuralEngine {
    /// Driver services whose children are the per-process ANE connections
    /// (load balancer on multi-ANE chips, the ANE itself on others).
    private static let driverClasses = ["H1xANELoadBalancer", "H11ANEIn"]
    /// The system ANE daemon always holds a connection; it isn't "usage".
    private static let ignoredClients: Set<String> = ["aned", "ANECompilerService", "ANEStorageMaintainer"]

    private static let hardware: (cores: Int, architecture: String) = {
        var result = (cores: 0, architecture: "")
        forEachService("H11ANEIn") { service in
            guard let props = property(service, "DeviceProperties") as? [String: Any] else { return }
            result.cores = (props["ANEDevicePropertyNumANECores"] as? NSNumber)?.intValue ?? 0
            result.architecture = props["ANEDevicePropertyTypeANEArchitectureTypeStr"] as? String ?? ""
        }
        return result
    }()

    static func current() -> NeuralEngineStatus {
        var status = NeuralEngineStatus(cores: hardware.cores, architecture: hardware.architecture)
        var byPID: [Int: NeuralEngineStatus.Client] = [:]

        for cls in driverClasses {
            forEachService(cls) { driver in
                var children: io_iterator_t = 0
                guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &children) == KERN_SUCCESS else { return }
                defer { IOObjectRelease(children) }
                var child = IOIteratorNext(children)
                while child != 0 {
                    // e.g. "pid 9860, mlx-serve"
                    if let creator = property(child, "IOUserClientCreator") as? String,
                       let client = parseUserClientCreator(creator), !ignoredClients.contains(client.name) {
                        byPID[client.pid, default: .init(pid: client.pid, name: client.name, connections: 0)].connections += 1
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(children)
                }
            }
        }
        status.clients = byPID.values
            .map { c -> NeuralEngineStatus.Client in
                let path = executablePath(c.pid)
                return NeuralEngineStatus.Client(pid: c.pid, name: path.map { ($0 as NSString).lastPathComponent } ?? c.name,
                                                 connections: c.connections, origin: ProcessOrigin.of(path: path, pid: c.pid))
            }
            .sorted { $0.connections > $1.connections }
        return status
    }
}
