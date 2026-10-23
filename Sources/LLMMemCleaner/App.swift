import AppKit
import ServiceManagement
import SwiftUI

@main
struct LLMMemCleanerApp: App {
    @State private var model = MonitorModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            Image(nsImage: model.menuImage)
        }
        .menuBarExtraStyle(.window)
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case memory, cpu, gpu, disk, network, startup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .memory: tr("内存", "Memory")
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .disk: tr("磁盘", "Disk")
        case .network: tr("网络", "Network")
        case .startup: tr("启动项", "Startup")
        }
    }
}

@MainActor @Observable
final class MonitorModel {
    var tab: Tab = .memory
    var showAbout = false
    var language = L10n.current {
        didSet {
            L10n.current = language
            UserDefaults.standard.set(language.rawValue, forKey: L10n.defaultsKey)
            // Scan results bake in group names, so drop them to rescan in the new language.
            cleanupItems = nil
        }
    }

    // Memory is sampled continuously for the menu bar icon; the rest only while the panel is open.
    var stats = MemoryStats.current()
    var cpu = CPUSampler.Snapshot()
    var gpu = GPUStats()
    var volume = VolumeInfo()
    var diskIO: (readPerSec: Double, writePerSec: Double) = (0, 0)
    var interfaces: [InterfaceRate] = []

    // Sampled only while the panel is open.
    var apps: [AppUsage] = []
    var background: [BackgroundProcess] = []
    /// Collapsed by default; the list is only sampled while expanded.
    var backgroundExpanded = false {
        didSet { if backgroundExpanded && !oldValue { Task { await refreshBackground() } } }
    }
    var processNetwork: [ProcessNetworkSampler.Row] = []
    var ollamaModels: [Ollama.LoadedModel]?
    var ollamaInstalled: [Ollama.LoadedModel]?
    var startupItems: [StartupItem]?
    var cleanupItems: [CleanupItem]?
    var scanning = false
    var wifi: WiFiInfo?
    var speedTesting = false
    var speedResult: SpeedTestResult?
    /// Result from before the last "optimize", for a before/after comparison.
    var speedBefore: SpeedTestResult?

    var selected: Set<pid_t> = []
    var busy = false
    var message: String?
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var loginItemError: String?

    private let cpuSampler = CPUSampler()
    private let diskSampler = DiskIOSampler()
    private let netSampler = NetworkSampler()
    private let appSampler = AppSampler()
    private let procNetSampler = ProcessNetworkSampler()
    private var timer: Timer?

    /// Menu bar icon: a memory chip with available GB printed on it. Stored (not computed) and
    /// only replaced when the visible number or color changes, so the menu bar doesn't redraw every tick.
    private(set) var menuImage = NSImage()
    private var menuImageKey = ""

    /// Set by the panel; while false only memory is sampled.
    var panelOpen = false {
        didSet { if panelOpen && !oldValue { sampleDetails() } }
    }

    init() {
        updateMenuImage()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.5  // lets macOS coalesce wake-ups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var selectedBytes: UInt64 {
        apps.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.footprint }
    }

    private func tick() {
        let s = MemoryStats.current()
        // Skip the assignment when nothing moved, so observers aren't notified.
        if s.used != stats.used || s.swapUsed != stats.swapUsed || s.pressureFreePercent != stats.pressureFreePercent {
            stats = s
            updateMenuImage()
        }
        if panelOpen { sampleDetails() }
    }

    private func updateMenuImage() {
        let usedFrac = stats.total > 0 ? Double(stats.used) / Double(stats.total) : 0
        let text = "\(stats.available / GB)"
        let key = "\(text)|\(usedFrac > 0.95)"
        guard key != menuImageKey else { return }
        menuImageKey = key
        menuImage = memoryChipImage(text: text, usedFraction: usedFrac)
    }

    private func sampleDetails() {
        cpu = cpuSampler.sample()
        gpu = GPUStats.current()
        volume = VolumeInfo.root()
        diskIO = diskSampler.sample()
        interfaces = netSampler.sample()
    }

    /// Per-panel refresh: app list always, plus whatever the current tab needs.
    func refreshPanel() async {
        apps = appSampler.sample()
        selected = selected.filter { pid in apps.contains { $0.id == pid } }
        ollamaModels = await Ollama.loadedModels()
        switch tab {
        case .memory where backgroundExpanded:
            await refreshBackground()
        case .network:
            processNetwork = await procNetSampler.sample()
            wifi = NetworkTools.wifiInfo()
        case .startup where startupItems == nil: await reloadStartupItems()
        case .disk where ollamaInstalled == nil: ollamaInstalled = await Ollama.installedModels()
        default: break
        }
    }

    func quitSelected() async {
        busy = true
        await AppSampler.quit(apps.filter { selected.contains($0.id) }.map(\.app))
        selected.removeAll()
        try? await Task.sleep(for: .seconds(1))  // let the kernel reclaim pages
        await refreshPanel()
        busy = false
    }

    func stopBackground(_ group: BackgroundProcess) async {
        busy = true
        let stopped = BackgroundProcesses.stop(group)
        if stopped < group.pids.count {
            message = tr("\(group.name)：结束了 \(stopped)/\(group.pids.count) 个进程",
                         "\(group.name): stopped \(stopped) of \(group.pids.count) processes")
        }
        try? await Task.sleep(for: .seconds(1))
        stats = MemoryStats.current()
        updateMenuImage()
        await refreshBackground()
        busy = false
    }

    func refreshBackground() async {
        background = await BackgroundProcesses.sample(excluding: appSampler.appPIDs)
    }

    func unload(_ name: String) async {
        busy = true
        await Ollama.unload(name)
        await refreshPanel()
        busy = false
    }

    // MARK: GPU

    func setGPULimit(fraction: Double?) async {
        await setGPULimit(mb: fraction.map { Int(Double(stats.total >> 20) * $0) } ?? 0)
    }

    /// 0 restores the macOS default.
    func setGPULimit(mb: Int) async {
        busy = true
        let r = await Shell.runAsAdmin("sysctl iogpu.wired_limit_mb=\(mb)")
        message = r?.status == 0 ? nil : tr("未修改（已取消或无权限）", "Not changed (cancelled or not permitted)")
        gpu = GPUStats.current()
        busy = false
    }

    // MARK: Disk

    func scanStorage() async {
        scanning = true
        async let items = StorageCleanup.scan()
        async let installed = Ollama.installedModels()
        (cleanupItems, ollamaInstalled) = await (items, installed)
        scanning = false
    }

    func trash(_ item: CleanupItem) {
        if let err = StorageCleanup.moveToTrash(item) {
            message = tr("移动失败：", "Couldn't move: ") + err
        } else {
            cleanupItems?.removeAll { $0.id == item.id }
        }
        volume = VolumeInfo.root()
    }

    var cacheBytes: UInt64 {
        (cleanupItems ?? []).filter(\.isCache).reduce(0) { $0 + $1.size }
    }

    func cleanCaches() async {
        guard let items = cleanupItems else { return }
        busy = true
        let (freed, failed) = await StorageCleanup.purgeCaches(items)
        message = tr("已释放 \(formatBytes(freed))", "Freed \(formatBytes(freed))")
            + (failed > 0 ? tr("，\(failed) 个文件正在使用或受保护已跳过", "; skipped \(failed) files in use or protected") : "")
        await scanStorage()
        busy = false
    }

    func deleteOllamaModel(_ name: String) async {
        busy = true
        await Ollama.delete(name)
        ollamaInstalled = await Ollama.installedModels()
        volume = VolumeInfo.root()
        busy = false
    }

    // MARK: Network

    func runSpeedTest() async {
        speedTesting = true
        speedBefore = nil
        speedResult = await NetworkTools.speedTest()
        if speedResult == nil { message = tr("测速失败，请检查网络连接", "Speed test failed; check your connection") }
        speedTesting = false
    }

    /// Flush DNS + renew DHCP, wait for the link to come back, then re-test for a before/after.
    func optimizeNetwork() async {
        guard let iface = await NetworkTools.defaultInterface() else {
            message = tr("未找到当前网络接口", "No active network interface")
            return
        }
        busy = true
        let before = speedResult
        guard await NetworkTools.optimize(interface: iface) else {
            message = tr("未执行（已取消或无权限）", "Not run (cancelled or not permitted)")
            busy = false
            return
        }
        try? await Task.sleep(for: .seconds(5))  // DHCP renew briefly drops the link
        busy = false
        await runSpeedTest()
        speedBefore = before
    }

    func terminateProcess(_ row: ProcessNetworkSampler.Row) {
        if !NetworkTools.terminate(pid: row.pid) {
            message = tr("无法结束 \(row.name)（系统进程或无权限）", "Couldn't stop \(row.name) (system process or no permission)")
        }
        processNetwork.removeAll { $0.pid == row.pid }
    }

    // MARK: Startup

    func reloadStartupItems() async {
        startupItems = await StartupItems.load()
    }

    func setStartup(_ item: StartupItem, enabled: Bool) async {
        busy = true
        message = await StartupItems.setEnabled(item, enabled)
        await reloadStartupItems()
        busy = false
    }

    /// Registers the app itself as a login item (shows up under System Settings → Login Items).
    func setLaunchAtLogin(_ on: Bool) {
        loginItemError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginItemError = error.localizedDescription
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            loginItemError = tr("需要在「系统设置 → 登录项」中允许", "Allow it in System Settings → Login Items")
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
