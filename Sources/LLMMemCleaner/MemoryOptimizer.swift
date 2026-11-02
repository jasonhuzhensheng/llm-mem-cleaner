import AppKit
import Darwin

/// Something big and idle that "Crazy optimize" offers to unload, stop or quit.
struct OptimizeCandidate: Identifiable {
    enum Action {
        case unloadModel(RunningModel)
        case stopService(LLMService)
        case stopColima(profile: String)
        case stopProcesses([pid_t])
        case quitApp(NSRunningApplication)
    }

    let id: String
    let title: String
    let detail: String
    let memory: UInt64
    let action: Action
    /// Pre-checked in the list.
    let recommended: Bool
    /// Allowed in automatic mode: idle models, model services and VMs. Never apps (unsaved work)
    /// or unknown processes.
    let automatic: Bool
}

/// Average CPU of a set of processes over the last few minutes, so a model server that's
/// between requests isn't mistaken for one nobody is using.
final class IdleTracker {
    private struct Sample { let at: Date; let cpuNs: UInt64 }
    private var history: [pid_t: [Sample]] = [:]
    private let machToNs: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    static let window: TimeInterval = 300
    /// Below this (fraction of one core) a process counts as idle.
    static let idleCPU = 0.03

    private func cpuNs(_ pid: pid_t) -> UInt64? {
        AppSampler.rusage(pid).map { UInt64(Double($0.ri_user_time + $0.ri_system_time) * machToNs) }
    }

    func record(_ pids: [pid_t]) {
        let now = Date()
        for pid in pids {
            guard let ns = cpuNs(pid) else { history[pid] = nil; continue }
            var h = (history[pid] ?? []).filter { now.timeIntervalSince($0.at) <= Self.window }
            h.append(Sample(at: now, cpuNs: ns))
            history[pid] = h
        }
    }

    /// Summed CPU (1.0 == one core) since the oldest sample, or nil without a usable baseline.
    func cpu(_ pids: [pid_t], minSpan: TimeInterval) -> Double? {
        let now = Date()
        var total = 0.0
        for pid in pids {
            guard let first = history[pid]?.first, let ns = cpuNs(pid) else { continue }
            let span = now.timeIntervalSince(first.at)
            guard span >= minSpan else { return nil }
            total += Double(ns &- min(first.cpuNs, ns)) / 1e9 / span
        }
        return total
    }

    func forget(except live: Set<pid_t>) {
        history = history.filter { live.contains($0.key) }
    }
}

enum MemoryOptimizer {
    static let colima = ["/opt/homebrew/bin/colima", "/usr/local/bin/colima"].first {
        FileManager.default.isExecutableFile(atPath: $0)
    }
    static let toolPath = "/opt/homebrew/bin:/usr/local/bin"

    /// Background processes and apps smaller than these aren't worth offering.
    static let minProcessBytes: UInt64 = 200 << 20
    static let minAppBytes: UInt64 = 300 << 20
    /// Apps never pre-checked: losing them is surprising or unsafe.
    private static let keepApps = ["1password", "bitwarden", "vpn", "kaspersky", "terminal", "iterm", "xcode"]
    static let minServiceBytes: UInt64 = 200 << 20

    @MainActor
    static func candidates(models: [RunningModel], services: [LLMService], apps: [AppUsage],
                           tracker: IdleTracker) async -> [OptimizeCandidate] {
        let vms = await colimaVMs()
        let vmPIDs = virtualMachinePIDs()
        let background = await BackgroundProcesses.sample(excluding: Set(apps.map(\.id)))
            .filter { $0.kind == .own && $0.origin == .user && $0.bytes >= minProcessBytes }
            // Helpers inside an app bundle (browser renderers etc.) belong to that app; killing them breaks it.
            .filter { g in !g.pids.contains { executablePath(Int($0))?.contains(".app/") ?? true } }
        // The app you were in before opening this panel owns the menu bar; never touch it.
        let inUse: Set<pid_t> = Set([NSWorkspace.shared.frontmostApplication, NSWorkspace.shared.menuBarOwningApplication]
            .compactMap { $0?.processIdentifier })
        let bigApps = apps.filter { $0.footprint >= minAppBytes && !inUse.contains($0.id) }

        let llmPIDs = Set(models.flatMap(\.pids).map(pid_t.init) + services.flatMap(\.pids).map(pid_t.init))
        let appPIDs: [pid_t: [pid_t]] = Dictionary(uniqueKeysWithValues: bigApps.map { ($0.id, appProcessPIDs($0.app)) })
        let all = models.flatMap(\.pids).map(pid_t.init) + services.flatMap(\.pids).map(pid_t.init)
            + vmPIDs + background.flatMap(\.pids) + appPIDs.values.flatMap { $0 }

        // Without a baseline from earlier scans, take a short one now.
        tracker.record(all)
        if tracker.cpu(all, minSpan: 3) == nil {
            try? await Task.sleep(for: .seconds(3))
        }
        func idle(_ pids: [pid_t]) -> (Bool, String) {
            let cpu = tracker.cpu(pids, minSpan: 3) ?? 0
            let isIdle = cpu < IdleTracker.idleCPU * Double(max(1, min(pids.count, 4)))
            return (isIdle, isIdle ? tr("空闲", "idle") : tr("正在使用 CPU \(Int(cpu * 100))%", "busy, CPU \(Int(cpu * 100))%"))
        }

        var out: [OptimizeCandidate] = []
        for m in models {
            let (isIdle, state) = idle(m.pids.map(pid_t.init))
            let label = m.engine ?? m.runtime.rawValue
            out.append(OptimizeCandidate(
                id: "model|" + m.id, title: m.name,
                detail: tr("\(label) 加载的模型 · \(state)", "Model loaded by \(label) · \(state)"),
                memory: m.memory ?? m.fileSize ?? 0, action: .unloadModel(m),
                recommended: isIdle, automatic: isIdle))
        }
        let loadedRuntimes = Set(models.map(\.runtime))
        for s in services where !loadedRuntimes.contains(s.runtime) && s.memory >= minServiceBytes {
            let (isIdle, state) = idle(s.pids.map(pid_t.init))
            out.append(OptimizeCandidate(
                id: "service|" + s.id, title: s.name,
                detail: tr("模型服务，没有加载模型 · \(state)", "Model service with nothing loaded · \(state)"),
                memory: s.memory, action: .stopService(s), recommended: isIdle, automatic: isIdle))
        }
        let running = vms.filter { $0.running }
        for vm in running {
            let (isIdle, state) = idle(vmPIDs)
            // One VM process per running profile; with several we can't tell which is which.
            let memory = running.count == 1 ? vmPIDs.reduce(0) { $0 + (AppSampler.rusage($1)?.ri_phys_footprint ?? 0) } : vm.memory
            let containers = vm.containers.isEmpty ? "" : " · " + vm.containers.joined(separator: ", ")
            out.append(OptimizeCandidate(
                id: "colima|" + vm.name, title: tr("Colima 虚拟机（\(vm.name)）", "Colima VM (\(vm.name))"),
                detail: tr("Docker 容器 · \(state)", "Docker containers · \(state)") + containers,
                memory: memory, action: .stopColima(profile: vm.name), recommended: isIdle, automatic: isIdle))
        }
        for g in background where !g.pids.contains(where: llmPIDs.contains) && !g.pids.contains(where: vmPIDs.contains) {
            let (isIdle, state) = idle(g.pids)
            out.append(OptimizeCandidate(
                id: "proc|" + g.name, title: g.name,
                detail: tr("后台进程 · \(state)", "Background process · \(state)"),
                memory: g.bytes, action: .stopProcesses(g.pids), recommended: isIdle, automatic: false))
        }
        for a in bigApps {
            let (isIdle, state) = idle(appPIDs[a.id] ?? [a.id])
            let key = ((a.app.bundleIdentifier ?? "") + " " + a.name).lowercased()
            let keep = keepApps.contains(where: key.contains)
            out.append(OptimizeCandidate(
                id: "app|\(a.id)", title: a.name,
                detail: tr("应用，不在前台 · \(state) · 退出前请先保存", "App in background · \(state) · save your work first"),
                memory: a.footprint, action: .quitApp(a.app), recommended: isIdle && !keep, automatic: false))
        }
        tracker.forget(except: Set(all))
        return out.sorted { $0.memory > $1.memory }
    }

    @MainActor
    static func run(_ c: OptimizeCandidate) async -> Bool {
        switch c.action {
        case .unloadModel(let m): return await RunningModels.unload(m)
        case .stopService(let s): return await LLMServices.stop(s)
        case .stopColima(let profile):
            guard let colima else { return false }
            return await Shell.run(colima, ["stop", profile], path: toolPath)?.status == 0
        case .stopProcesses(let pids): return pids.allSatisfy { kill($0, SIGTERM) == 0 }
        case .quitApp(let app):
            await AppSampler.quit([app])
            return app.isTerminated
        }
    }

    // MARK: - Colima

    struct ColimaVM { let name: String; let running: Bool; let memory: UInt64; var containers: [String] }

    private struct ColimaListing: Decodable { let name: String; let status: String; let memory: UInt64? }

    static func colimaVMs() async -> [ColimaVM] {
        guard let colima, let out = await Shell.run(colima, ["list", "--json"], path: toolPath)?.output else { return [] }
        var vms: [ColimaVM] = []
        for line in out.split(separator: "\n") {
            guard let l = try? JSONDecoder().decode(ColimaListing.self, from: Data(line.utf8)) else { continue }
            var vm = ColimaVM(name: l.name, running: l.status == "Running", memory: l.memory ?? 0, containers: [])
            if vm.running { vm.containers = await containers(profile: l.name) }
            vms.append(vm)
        }
        return vms
    }

    private static func containers(profile: String) async -> [String] {
        guard let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return [] }
        let context = profile == "default" ? "colima" : "colima-" + profile
        guard let r = await Shell.run(docker, ["--context", context, "ps", "--format", "{{.Names}}"], path: toolPath),
              r.status == 0 else { return [] }
        return r.output.split(separator: "\n").map(String.init)
    }

    /// Apple Virtualization VM processes (Colima, Lima, Docker Desktop with VZ all run guests in these).
    static func virtualMachinePIDs() -> [pid_t] {
        AppSampler.allPIDs().filter { pid in
            pid > 0 && (executablePath(Int(pid))?.hasSuffix("com.apple.Virtualization.VirtualMachine") ?? false)
        }
    }

    // MARK: - Helpers

    private static func appProcessPIDs(_ app: NSRunningApplication) -> [pid_t] {
        guard let bundle = app.bundleURL?.path else { return [app.processIdentifier] }
        return AppSampler.allPIDs().filter { pid in
            pid > 0 && (executablePath(Int(pid))?.hasPrefix(bundle + "/") ?? false)
        }
    }
}
