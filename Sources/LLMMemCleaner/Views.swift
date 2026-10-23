import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: Binding(
                get: { model.tab },
                set: { model.tab = $0; model.showAbout = false })) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                Group {
                    if model.showAbout {
                        AboutView(model: model)
                    } else {
                        switch model.tab {
                        case .memory: MemoryTab(model: model)
                        case .cpu: CPUTab(model: model)
                        case .gpu: GPUTab(model: model)
                        case .disk: DiskTab(model: model)
                        case .network: NetworkTab(model: model)
                        case .startup: StartupTab(model: model)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 520)

            if let msg = model.message {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(msg).font(.caption).lineLimit(2)
                    Spacer()
                    Button(tr("关闭", "Dismiss")) { model.message = nil }.buttonStyle(.link).font(.caption)
                }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 440)
        // tr() isn't observable, so rebuild the whole panel when the language changes.
        .id(model.language)
        .onAppear { model.panelOpen = true }
        .onDisappear { model.panelOpen = false }
        .task(id: model.tab) {
            // Refresh while the panel is open; SwiftUI cancels this when it closes or the tab changes.
            while !Task.isCancelled {
                await model.refreshPanel()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle(tr("开机自启", "Launch at login"), isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .help(model.loginItemError ?? tr("登录 macOS 时自动启动", "Start automatically when you log in"))
            if let err = model.loginItemError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(err)
            }
            if model.busy { ProgressView().controlSize(.small) }
            Spacer()
            Picker("", selection: $model.language) {
                ForEach(Language.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help(tr("界面语言", "Language"))
            Button(tr("活动监视器", "Activity Monitor")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Button {
                model.showAbout.toggle()
            } label: {
                Image(systemName: model.showAbout ? "info.circle.fill" : "info.circle")
            }
            .buttonStyle(.borderless)
            .help(tr("关于", "About"))
            Button(tr("退出", "Quit")) { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

// MARK: - About

struct AboutView: View {
    @Bindable var model: MonitorModel

    static let xURL = URL(string: "https://x.com/HUZHENSHENG")!
    static let repoURL = URL(string: "https://github.com/jasonhuzhensheng/llm-mem-cleaner")!

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: memoryChipImage(text: "AI", usedFraction: 0))
                    .resizable().interpolation(.high)
                    .frame(width: 44, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LLM Mem Cleaner").font(.title2.bold())
                    Text(tr("版本 \(version)", "Version \(version)")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(tr("在本地运行大模型前，查看并一键释放内存、GPU 显存、磁盘和网络资源。",
                    "See and free up memory, GPU memory, disk and network before running local LLMs."))
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            SectionTitle(text: tr("作者", "Author"))
            Link(destination: Self.xURL) {
                Label("@HUZHENSHENG", systemImage: "at")
            }
            .help(Self.xURL.absoluteString)
            Text(tr("在 X 上关注，获取更新和反馈问题。", "Follow on X for updates and feedback."))
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            SectionTitle(text: tr("源代码", "Source code"))
            Link(destination: Self.repoURL) {
                Label("github.com/jasonhuzhensheng/llm-mem-cleaner", systemImage: "chevron.left.forwardslash.chevron.right")
            }

            Button(tr("返回", "Back")) { model.showAbout = false }
                .controlSize(.small)
        }
    }
}

// MARK: - Shared pieces

struct SectionTitle: View {
    let text: String
    var body: some View { Text(text).font(.subheadline.bold()) }
}

struct BigNumber: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

/// Green below 60%, yellow up to 85%, red above.
func usageColor(_ fraction: Double) -> Color {
    fraction > 0.85 ? .red : fraction > 0.6 ? .yellow : .green
}

/// Selectable app list with a one-click quit button, sorted by whatever the tab cares about.
struct AppListView: View {
    @Bindable var model: MonitorModel
    let title: String
    let sortKey: (AppUsage) -> Double
    let value: (AppUsage) -> String

    var body: some View {
        let sorted = model.apps.sorted { sortKey($0) > sortKey($1) }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: title)
                Spacer()
                Button(tr("选中前 5", "Select top 5")) { model.selected = Set(sorted.prefix(5).map(\.id)) }
                    .buttonStyle(.link).font(.caption)
                Button(tr("清空", "Clear")) { model.selected.removeAll() }
                    .buttonStyle(.link).font(.caption)
            }
            VStack(spacing: 2) {
                ForEach(sorted.prefix(15)) { usage in
                    AppRow(usage: usage, value: value(usage), isOn: Binding(
                        get: { model.selected.contains(usage.id) },
                        set: { on in
                            if on { model.selected.insert(usage.id) } else { model.selected.remove(usage.id) }
                        }))
                }
            }
            Button {
                Task { await model.quitSelected() }
            } label: {
                Text(model.selected.isEmpty
                     ? tr("选择要退出的应用", "Select apps to quit")
                     : tr("一键退出 \(model.selected.count) 个应用 · 释放约 \(formatBytes(model.selectedBytes)) 内存",
                          "Quit \(model.selected.count) apps · free ~\(formatBytes(model.selectedBytes))"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selected.isEmpty || model.busy)
            Text(tr("先正常退出，5 秒后仍未退出则强制结束。未保存的内容可能丢失。",
                    "Quits normally, then force-quits after 5 s. Unsaved work may be lost."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct AppRow: View {
    let usage: AppUsage
    let value: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.checkbox)
            if let icon = usage.app.icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Text(usage.name).lineLimit(1)
            if usage.processCount > 1 {
                Text("×\(usage.processCount)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).font(.callout.monospacedDigit())
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}

struct OllamaLoadedSection: View {
    @Bindable var model: MonitorModel

    var body: some View {
        if let models = model.ollamaModels {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(text: tr("Ollama 已加载模型", "Ollama loaded models"))
                if models.isEmpty {
                    Text(tr("无", "None")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(models) { m in
                    HStack {
                        Text(m.name).font(.callout)
                        Spacer()
                        Text(formatBytes(m.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button(tr("卸载", "Unload")) { Task { await model.unload(m.name) } }
                            .controlSize(.small)
                            .disabled(model.busy)
                    }
                }
            }
        }
    }
}

// MARK: - Memory

struct MemoryTab: View {
    @Bindable var model: MonitorModel

    private var pressureColor: Color {
        switch model.stats.pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    var body: some View {
        let s = model.stats
        let usedFrac = s.total > 0 ? Double(s.used) / Double(s.total) : 0
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tr("可用内存", "Available memory")).font(.headline)
                    Spacer()
                    Circle().fill(pressureColor).frame(width: 8, height: 8)
                    Text(tr("压力余量 \(s.pressureFreePercent)%", "Pressure headroom \(s.pressureFreePercent)%"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("\(formatBytes(s.available)) / \(formatBytes(s.total))")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(tr("已用 \(Int(usedFrac * 100))%", "\(Int(usedFrac * 100))% used"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(usageColor(usedFrac))
                }
                ProgressView(value: usedFrac).tint(usageColor(usedFrac))
                Text(tr("联动 \(formatBytes(s.wired)) · 压缩 \(formatBytes(s.compressed)) · Swap \(formatBytes(s.swapUsed))",
                        "Wired \(formatBytes(s.wired)) · Compressed \(formatBytes(s.compressed)) · Swap \(formatBytes(s.swapUsed))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            tiers
            Divider()
            AppListView(model: model, title: tr("应用内存占用", "Memory by app"),
                        sortKey: { Double($0.footprint) }, value: { formatBytes($0.footprint) })
            Divider()
            BackgroundSection(model: model)
            OllamaLoadedSection(model: model)
        }
    }

    private var tiers: some View {
        let now = model.stats.available
        let after = now + model.selectedBytes
        let gpuLimit = model.gpu.wiredLimit
        return VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: tr("能跑的模型（Q4 量化估算）", "Models that fit (Q4 estimate)"))
            HStack(spacing: 6) {
                ForEach(ModelTier.all) { tier in
                    let need = tier.requiredBytes + systemReserve
                    let overGPU = tier.requiredBytes > gpuLimit
                    let fitsNow = !overGPU && now >= need
                    let fitsAfter = !overGPU && !fitsNow && after >= need && model.selectedBytes > 0
                    Text(tier.name)
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(fitsNow ? Color.green.opacity(0.25)
                                      : fitsAfter ? Color.blue.opacity(0.25)
                                      : Color.secondary.opacity(0.12)))
                        .foregroundStyle(fitsNow || fitsAfter ? .primary : .secondary)
                        .strikethrough(overGPU)
                        .help(overGPU
                              ? tr("超过 GPU 显存上限 \(formatBytes(gpuLimit))，可在 GPU 页调高",
                                   "Exceeds the GPU memory limit of \(formatBytes(gpuLimit)); raise it on the GPU tab")
                              : tr("需要约 \(formatBytes(need))（含 \(formatBytes(systemReserve)) 系统预留）",
                                   "Needs ~\(formatBytes(need)) (incl. \(formatBytes(systemReserve)) reserved for macOS)"))
                }
            }
            if model.selectedBytes > 0 {
                Text(tr("蓝色：退出选中应用后可运行", "Blue: fits after quitting the selected apps"))
                    .font(.caption2).foregroundStyle(.blue)
            }
        }
    }
}

/// Daemons, agents and helpers that aren't Dock apps, with what (if anything) can be done about each.
struct BackgroundSection: View {
    @Bindable var model: MonitorModel
    @State private var pending: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.backgroundExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .rotationEffect(.degrees(model.backgroundExpanded ? 90 : 0))
                    SectionTitle(text: tr("后台进程", "Background processes"))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.backgroundExpanded {
                Text(tr("不在 Dock 中的服务和辅助进程（≥ 50 MB）。≈ 表示估算值。",
                        "Services and helpers not in the Dock (≥ 50 MB). ≈ means estimated."))
                    .font(.caption2).foregroundStyle(.secondary)
                if model.background.isEmpty {
                    ProgressView().controlSize(.small)
                }
                ForEach(model.background.prefix(15)) { p in row(p) }
            }
        }
    }

    private func row(_ p: BackgroundProcess) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(p.name).lineLimit(1).truncationMode(.middle)
                if p.pids.count > 1 {
                    Text("×\(p.pids.count)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text((p.approximate ? "≈ " : "") + formatBytes(p.bytes)).font(.callout.monospacedDigit())
                action(p)
            }
            if let hint = hint(p.kind) {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
        .controlSize(.small)
    }

    @ViewBuilder private func action(_ p: BackgroundProcess) -> some View {
        switch p.kind {
        case .own, .respawns:
            if pending == p.id {
                Button(tr("确认", "Confirm")) {
                    pending = nil
                    Task { await model.stopBackground(p) }
                }
                .tint(.red)
                Button(tr("取消", "Cancel")) { pending = nil }
            } else {
                Button(tr("结束", "Stop")) { pending = p.id }.disabled(model.busy)
            }
        case .spotlight:
            Button(tr("设置", "Settings")) { BackgroundProcesses.openSpotlightPrivacy() }
        case .antivirus, .system:
            EmptyView()
        }
    }

    private func hint(_ kind: BackgroundProcess.Kind) -> String? {
        switch kind {
        case .own: nil
        case .respawns: tr("系统服务，结束后过一会儿会自动重启", "System service; restarts on its own after a while")
        case .spotlight: tr("Spotlight 索引：在「搜索隐私」里排除模型磁盘可减少占用",
                            "Spotlight indexing: exclude your model disk under Search Privacy")
        case .antivirus: tr("杀毒软件受保护，只能在它自己的界面里暂停", "Protected antivirus; pause it from its own app")
        case .system: tr("系统进程，无法结束", "System process; can't be stopped")
        }
    }
}

// MARK: - CPU

struct CPUTab: View {
    @Bindable var model: MonitorModel

    var body: some View {
        let c = model.cpu
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                BigNumber(title: tr("CPU 使用率", "CPU usage"), value: "\(Int(c.total * 100))%")
                BigNumber(title: tr("1 分钟负载", "Load (1 min)"), value: String(format: "%.2f", c.load1))
                BigNumber(title: tr("核心数", "Cores"), value: "\(c.perCore.count)")
            }
            ProgressView(value: c.total).tint(usageColor(c.total))

            SectionTitle(text: tr("各核心", "Per core"))
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(c.perCore.enumerated()), id: \.offset) { _, v in
                    VStack {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(usageColor(v))
                            .frame(height: max(2, 40 * v))
                    }
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.1)))
                }
            }
            .frame(height: 40)

            Divider()
            AppListView(model: model, title: tr("应用 CPU 占用（100% = 1 核）", "CPU by app (100% = 1 core)"),
                        sortKey: { $0.cpu }, value: { String(format: "%.0f%%", $0.cpu * 100) })
        }
    }
}

// MARK: - GPU

struct GPUTab: View {
    @Bindable var model: MonitorModel
    @State private var customGB: Double = 84

    private var totalGB: Double { Double(model.stats.total) / Double(GB) }

    /// Free-form limit in GB, with a live readout of what's left for macOS.
    private var customLimit: some View {
        let left = totalGB - customGB
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tr("自定义", "Custom"))
                TextField("GB", value: $customGB, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Text("GB").foregroundStyle(.secondary)
                Stepper("", value: $customGB, in: 8...max(8, totalGB - 4), step: 1).labelsHidden()
                Text(String(format: "%.1f%%", customGB / totalGB * 100)).foregroundStyle(.secondary)
                Spacer()
                Button(tr("应用", "Apply")) {
                    Task { await model.setGPULimit(mb: Int(customGB * 1024)) }
                }
                .disabled(customGB < 8 || left < 4)
            }
            Text(String(format: tr("留给系统 %.1f GB", "%.1f GB left for macOS"), left))
                .font(.caption2)
                .foregroundStyle(left < 8 ? .red : left < 12 ? .orange : .secondary)
        }
    }

    @State private var pendingStop: Int?

    private var gpuClientsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: tr("正在使用 GPU 的进程", "Processes using the GPU"))
            if model.gpuClients.isEmpty {
                Text(tr("采样中…或当前没有进程在使用 GPU", "Sampling… or nothing is using the GPU"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.gpuClients.prefix(10)) { c in
                HStack(spacing: 6) {
                    Text(c.name).lineLimit(1).truncationMode(.middle)
                    Text("\(c.pid)").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let fp = c.footprint {
                        Text(formatBytes(fp)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .help(tr("进程内存（含 GPU 缓冲区）", "Process memory (incl. GPU buffers)"))
                    }
                    Text(String(format: "%.1f%%", c.gpu * 100))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(usageColor(c.gpu))
                        .frame(width: 52, alignment: .trailing)
                    if c.canStop {
                        if pendingStop == c.pid {
                            Button(tr("确认", "Confirm")) { pendingStop = nil; model.stopGPUClient(c) }.tint(.red)
                            Button(tr("取消", "Cancel")) { pendingStop = nil }
                        } else {
                            Button(tr("结束", "Stop")) { pendingStop = c.pid }
                        }
                    }
                }
                .controlSize(.mini)
            }
            Text(tr("GPU % = 该进程占用 GPU 的时间比例，与活动监视器的「GPU %」算法相同。",
                    "GPU % = share of GPU time, same as Activity Monitor's GPU %."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var neuralEngineSection: some View {
        let ane = model.neuralEngine
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: tr("神经网络引擎（ANE）", "Neural Engine (ANE)"))
                Spacer()
                Circle().fill(ane.inUse ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(ane.inUse ? tr("使用中", "In use") : tr("空闲", "Idle"))
                    .font(.caption).foregroundStyle(ane.inUse ? .primary : .secondary)
            }
            if ane.cores > 0 {
                Text(tr("\(ane.cores) 核 · 架构 \(ane.architecture)", "\(ane.cores) cores · \(ane.architecture)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if ane.clients.isEmpty {
                Text(tr("当前没有进程在使用 ANE", "No process is using the ANE"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ane.clients) { c in
                HStack {
                    Text(c.name).lineLimit(1).truncationMode(.middle)
                    Text("\(c.pid)").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(tr("\(c.connections) 个连接", "\(c.connections) connections"))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(tr("macOS 不向普通应用开放 ANE 使用率和功耗，这里显示的是正在连接 ANE 运行模型的进程。",
                    "macOS doesn't expose ANE utilization or power to regular apps; this lists processes connected to the ANE to run models."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        let g = model.gpu
        let util = Double(g.utilization) / 100
        let memFrac = g.wiredLimit > 0 ? Double(g.inUseMemory) / Double(g.wiredLimit) : 0
        let defaultPercent = Int(Double(g.wiredLimit) / Double(model.stats.total) * 100)
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("\(g.model) · \(g.cores) 核 GPU", "\(g.model) · \(g.cores)-core GPU")).font(.headline)
            HStack(spacing: 24) {
                BigNumber(title: tr("GPU 使用率", "GPU usage"), value: "\(g.utilization)%")
                BigNumber(title: tr("GPU 占用内存", "GPU memory in use"), value: formatBytes(g.inUseMemory))
                BigNumber(title: tr("显存上限", "Memory limit"), value: formatBytes(g.wiredLimit))
            }
            ProgressView(value: util) { Text(tr("使用率", "Utilization")).font(.caption) }.tint(usageColor(util))
            ProgressView(value: min(memFrac, 1)) {
                Text(tr("显存：", "Memory: ") + "\(formatBytes(g.inUseMemory)) / \(formatBytes(g.wiredLimit))").font(.caption)
            }
            .tint(usageColor(memFrac))

            Divider()
            gpuClientsSection
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: tr("GPU 显存上限（统一内存）", "GPU memory limit (unified memory)"))
                Text(g.wiredLimitIsDefault
                     ? tr("当前为系统默认（约 \(defaultPercent)% 内存）。大模型被这个上限卡住时可以调高；重启后恢复默认。",
                          "Using the macOS default (~\(defaultPercent)% of RAM). Raise it if a large model won't fit; it resets on reboot.")
                     : tr("已手动设置为 \(formatBytes(g.wiredLimit))，重启后恢复默认。",
                          "Manually set to \(formatBytes(g.wiredLimit)); resets to default on reboot."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    ForEach([0.85, 0.875, 0.90], id: \.self) { f in
                        Button(String(format: f == 0.875 ? "%.1f%%" : "%.0f%%", f * 100)) {
                            Task { await model.setGPULimit(fraction: f) }
                        }
                        .help("≈ \(formatBytes(UInt64(Double(model.stats.total) * f)))")
                    }
                    Button(tr("恢复默认", "Reset to default")) { Task { await model.setGPULimit(fraction: nil) } }
                        .disabled(g.wiredLimitIsDefault)
                }
                .controlSize(.small)
                .disabled(model.busy)

                customLimit
                    .controlSize(.small)
                    .disabled(model.busy)
                Text(tr("需要管理员密码。留给系统的内存太少可能导致卡顿。",
                        "Requires an admin password. Leaving too little for macOS can cause stutter."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            neuralEngineSection
            OllamaLoadedSection(model: model)
        }
    }
}

// MARK: - Disk

struct DiskTab: View {
    @Bindable var model: MonitorModel
    @State private var pendingDelete: String?

    var body: some View {
        let v = model.volume
        let used = v.total > v.available ? v.total - v.available : 0
        let frac = v.total > 0 ? Double(used) / Double(v.total) : 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                BigNumber(title: tr("可用空间", "Free space"), value: formatBytes(v.available))
                BigNumber(title: tr("读取", "Read"), value: formatRate(model.diskIO.readPerSec))
                BigNumber(title: tr("写入", "Write"), value: formatRate(model.diskIO.writePerSec))
            }
            ProgressView(value: frac) {
                Text(tr("已用 ", "Used ") + "\(formatBytes(used)) / \(formatBytes(v.total))").font(.caption)
            }
            .tint(usageColor(frac))

            Divider()
            topDiskApps
            Divider()
            cleanup
        }
    }

    private var topDiskApps: some View {
        let busy = model.apps.filter { $0.diskPerSec > 1024 }.sorted { $0.diskPerSec > $1.diskPerSec }
        return VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: tr("正在读写磁盘的应用", "Apps using the disk"))
            if busy.isEmpty {
                Text(tr("暂无明显磁盘活动", "No significant disk activity")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(busy.prefix(6)) { a in
                HStack {
                    if let icon = a.app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                    Text(a.name).lineLimit(1)
                    Spacer()
                    Text(formatRate(a.diskPerSec)).font(.callout.monospacedDigit())
                }
            }
        }
    }

    private var cleanup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: tr("空间清理", "Free up space"))
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button(model.cleanupItems == nil ? tr("扫描", "Scan") : tr("重新扫描", "Rescan")) {
                    Task { await model.scanStorage() }
                }
                .controlSize(.small)
                .disabled(model.scanning)
            }

            if model.cleanupItems != nil, model.cacheBytes > 0 {
                cleanCachesButton
            }

            if let installed = model.ollamaInstalled, !installed.isEmpty {
                Text(tr("Ollama 模型", "Ollama models")).font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(installed) { m in
                    cleanupRow(name: m.name, size: m.size, id: "ollama|\(m.name)", deleteLabel: tr("删除", "Delete"),
                               onDelete: { Task { await model.deleteOllamaModel(m.name) } }, onReveal: nil)
                }
            }

            if let items = model.cleanupItems {
                if items.isEmpty {
                    Text(tr("没有找到大于 100 MB 的可清理目录", "No cleanable folders over 100 MB found"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                let groups = Dictionary(grouping: items, by: \.group)
                ForEach(groups.keys.sorted(), id: \.self) { group in
                    Text(group).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(groups[group] ?? []) { item in
                        cleanupRow(name: item.name, size: item.size, id: item.id,
                                   deleteLabel: tr("移到废纸篓", "Move to Trash"),
                                   onDelete: item.revealOnly ? nil : { model.trash(item) },
                                   onReveal: { StorageCleanup.reveal(item) })
                    }
                }
                Text(tr("移到废纸篓后，需要清倒废纸篓才会真正释放空间。",
                        "Space is only reclaimed after you empty the Trash."))
                    .font(.caption2).foregroundStyle(.secondary)
            } else if !model.scanning {
                Text(tr("扫描 Hugging Face / LM Studio 模型、Xcode 缓存、应用缓存和废纸篓。",
                        "Scans Hugging Face / LM Studio models, Xcode caches, app caches and the Trash."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// One click arms it and shows what will happen; the second click cleans.
    @ViewBuilder private var cleanCachesButton: some View {
        let size = formatBytes(model.cacheBytes)
        if pendingDelete == "caches" {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("将永久删除应用缓存和开发缓存（不进废纸篓，不含模型和 Apple 系统缓存）。建议先退出相关应用。",
                        "Permanently deletes app and developer caches (not via Trash; models and Apple caches are kept). Quit those apps first if you can."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(tr("确认清理 \(size)", "Clean \(size)")) {
                        pendingDelete = nil
                        Task { await model.cleanCaches() }
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    Button(tr("取消", "Cancel")) { pendingDelete = nil }
                }
            }
        } else {
            Button {
                pendingDelete = "caches"
            } label: {
                Label(tr("一键清理缓存 · \(size)", "Clean all caches · \(size)"), systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy)
        }
    }

    /// Delete needs two clicks: the first arms it, the second confirms.
    private func cleanupRow(name: String, size: UInt64, id: String, deleteLabel: String,
                            onDelete: (() -> Void)?, onReveal: (() -> Void)?) -> some View {
        HStack {
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(formatBytes(size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let onReveal {
                Button { onReveal() } label: { Image(systemName: "magnifyingglass") }
                    .help(tr("在 Finder 中显示", "Show in Finder"))
            }
            if let onDelete {
                if pendingDelete == id {
                    Button(tr("确认", "Confirm")) { pendingDelete = nil; onDelete() }.tint(.red)
                    Button(tr("取消", "Cancel")) { pendingDelete = nil }
                } else {
                    Button(deleteLabel) { pendingDelete = id }
                }
            }
        }
        .controlSize(.small)
        .disabled(model.busy)
    }
}

// MARK: - Network

struct NetworkTab: View {
    @Bindable var model: MonitorModel
    @State private var pendingKill: Int?
    @State private var confirmOptimize = false

    private var speedTest: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: tr("网速测试", "Speed test"))
                Spacer()
                if model.speedTesting {
                    ProgressView().controlSize(.small)
                    Text(tr("测速中…约 30 秒", "Testing… ~30 s")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(tr("一键测速", "Run speed test")) { Task { await model.runSpeedTest() } }
                        .controlSize(.small)
                        .disabled(model.busy)
                }
            }

            if let r = model.speedResult {
                HStack(spacing: 20) {
                    BigNumber(title: tr("↓ 下载", "↓ Download"), value: formatMbps(r.downloadBps))
                    BigNumber(title: tr("↑ 上传", "↑ Upload"), value: formatMbps(r.uploadBps))
                    BigNumber(title: tr("延迟", "Latency"), value: String(format: "%.0f ms", r.idleRTTms))
                }
                HStack(spacing: 4) {
                    Text(tr("响应性", "Responsiveness")).foregroundStyle(.secondary)
                    Text(String(format: "%.0f RPM", r.rpm)).monospacedDigit()
                    Text(responsivenessLabel(r.responsiveness))
                        .foregroundStyle(r.responsiveness == .high ? .green : r.responsiveness == .medium ? .orange : .red)
                    Spacer()
                    Text(r.interface).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .font(.caption)
                if let b = model.speedBefore {
                    Text(tr("优化前：↓ \(formatMbps(b.downloadBps))  ↑ \(formatMbps(b.uploadBps))  延迟 \(Int(b.idleRTTms)) ms",
                            "Before: ↓ \(formatMbps(b.downloadBps))  ↑ \(formatMbps(b.uploadBps))  latency \(Int(b.idleRTTms)) ms"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !model.speedTesting {
                Text(tr("使用 macOS 自带的 networkQuality，连接 Apple 服务器测试。",
                        "Uses macOS's built-in networkQuality against Apple's servers."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            optimize
        }
    }

    @ViewBuilder private var optimize: some View {
        if confirmOptimize {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("将刷新 DNS 缓存并重新获取 IP 地址（需要管理员密码，网络会断开几秒），完成后自动重新测速对比。带宽上限由网络本身决定，这一步只能修复 DNS 慢、IP 异常等问题。",
                        "Flushes the DNS cache and renews the IP lease (admin password; the connection drops for a few seconds), then re-tests to compare. It can't raise your plan's bandwidth — it fixes slow DNS or a stale lease."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(tr("开始优化", "Optimize")) {
                        confirmOptimize = false
                        Task { await model.optimizeNetwork() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button(tr("取消", "Cancel")) { confirmOptimize = false }
                }
                .controlSize(.small)
            }
        } else {
            Button {
                confirmOptimize = true
            } label: {
                Label(tr("一键优化网速", "Optimize network"), systemImage: "bolt.horizontal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || model.speedTesting)
        }
    }

    @ViewBuilder private var wifiSection: some View {
        if let w = model.wifi {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionTitle(text: "Wi-Fi")
                    Text(wifiQualityLabel(w.quality))
                        .font(.caption.bold())
                        .foregroundStyle(w.quality == .excellent || w.quality == .good ? .green
                                         : w.quality == .fair ? .orange : .red)
                    Spacer()
                    Text("\(w.band) · \(tr("信道", "ch")) \(w.channel)").font(.caption).foregroundStyle(.secondary)
                }
                Text(tr("信号 \(w.rssi) dBm · 信噪比 \(w.snr) dB · 连接速率 \(Int(w.txRateMbps)) Mbps",
                        "Signal \(w.rssi) dBm · SNR \(w.snr) dB · Link rate \(Int(w.txRateMbps)) Mbps"))
                    .font(.caption.monospacedDigit())
                if let tip = wifiTip(w) {
                    Text(tip).font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func responsivenessLabel(_ r: SpeedTestResult.Rating) -> String {
        switch r {
        case .high: tr("好", "High")
        case .medium: tr("中", "Medium")
        case .low: tr("差", "Low")
        }
    }

    private func wifiQualityLabel(_ q: WiFiInfo.Quality) -> String {
        switch q {
        case .excellent: tr("信号极好", "Excellent")
        case .good: tr("信号良好", "Good")
        case .fair: tr("信号一般", "Fair")
        case .poor: tr("信号差", "Poor")
        }
    }

    private func wifiTip(_ w: WiFiInfo) -> String? {
        if w.quality == .poor || w.quality == .fair {
            return tr("信号偏弱：靠近路由器或减少遮挡，会比任何软件优化都有效。",
                      "Weak signal: moving closer to the router beats any software tweak.")
        }
        if w.band == "2.4 GHz" {
            return tr("当前在 2.4 GHz 频段，若路由器支持，切换到 5 GHz / 6 GHz 通常更快。",
                      "On 2.4 GHz — switching to 5 / 6 GHz is usually much faster if your router supports it.")
        }
        return nil
    }

    var body: some View {
        // Some network extensions (VPN / antivirus) hide link-level counters, so fall back to per-process totals.
        let totalIn = max(model.interfaces.reduce(0) { $0 + $1.inPerSec },
                          model.processNetwork.reduce(0) { $0 + $1.inPerSec })
        let totalOut = max(model.interfaces.reduce(0) { $0 + $1.outPerSec },
                           model.processNetwork.reduce(0) { $0 + $1.outPerSec })
        VStack(alignment: .leading, spacing: 12) {
            speedTest
            if model.wifi != nil {
                Divider()
                wifiSection
            }
            Divider()
            SectionTitle(text: tr("实时流量", "Live traffic"))
            HStack(spacing: 24) {
                BigNumber(title: tr("↓ 下载", "↓ Download"), value: formatRate(totalIn))
                BigNumber(title: tr("↑ 上传", "↑ Upload"), value: formatRate(totalOut))
            }

            SectionTitle(text: tr("网络接口", "Interfaces"))
            let active = model.interfaces.filter { $0.inPerSec + $0.outPerSec > 0 }
            if active.isEmpty {
                Text(tr("暂无流量", "No traffic")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(active.prefix(6)) { i in
                HStack {
                    Text(i.name).font(.callout.monospaced())
                    Spacer()
                    Text("↓ \(formatRate(i.inPerSec))  ↑ \(formatRate(i.outPerSec))").font(.caption.monospacedDigit())
                }
            }

            Divider()
            SectionTitle(text: tr("进程流量", "Traffic by process"))
            if model.processNetwork.isEmpty {
                Text(tr("采样中…（需要两次采样才能算出速率）", "Sampling… (rates need two samples)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.processNetwork.prefix(15)) { p in
                HStack {
                    Text(p.name).lineLimit(1)
                    Text("\(p.pid)").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("↓ \(formatRate(p.inPerSec))  ↑ \(formatRate(p.outPerSec))").font(.caption.monospacedDigit())
                    // Two clicks to stop a process: arm, then confirm.
                    if pendingKill == p.pid {
                        Button(tr("确认", "Confirm")) { pendingKill = nil; model.terminateProcess(p) }.tint(.red)
                        Button(tr("取消", "Cancel")) { pendingKill = nil }
                    } else {
                        Button(tr("结束", "Stop")) { pendingKill = p.pid }
                    }
                }
                .controlSize(.mini)
            }
        }
    }
}

// MARK: - Startup

struct StartupTab: View {
    @Bindable var model: MonitorModel
    @State private var hideDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(tr("只看已启用", "Enabled only"), isOn: $hideDisabled).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button(tr("系统登录项设置", "Login Items settings")) { SMAppServiceSettings.open() }
                Button(tr("刷新", "Refresh")) { Task { await model.reloadStartupItems() } }
            }
            .controlSize(.small)

            if let items = model.startupItems {
                ForEach(StartupItem.Kind.allCases, id: \.self) { kind in
                    let list = items.filter { $0.kind == kind && (!hideDisabled || $0.enabled) }
                    if !list.isEmpty {
                        HStack {
                            Text(kind.title).font(.caption.bold()).foregroundStyle(.secondary)
                            if kind.needsAdmin {
                                Text(tr("修改需要管理员密码", "Changes need an admin password"))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                        ForEach(list) { item in row(item) }
                    }
                }
                Text(tr("关闭 = 停止运行并禁止开机启动，plist 文件保留，可随时重新打开。",
                        "Off = stopped and blocked from starting at login. The plist is kept, so you can turn it back on."))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ProgressView(tr("读取启动项…", "Loading startup items…")).controlSize(.small)
            }
        }
    }

    private func row(_ item: StartupItem) -> some View {
        HStack(spacing: 6) {
            Circle().fill(item.running ? Color.green : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                .help(item.running ? tr("正在运行", "Running") : tr("未运行", "Not running"))
            VStack(alignment: .leading, spacing: 0) {
                Text(item.label).lineLimit(1).truncationMode(.middle)
                if let p = item.program ?? item.path {
                    Text(p).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { item.enabled },
                set: { on in Task { await model.setStartup(item, enabled: on) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(model.busy || (item.kind == .loginItem && !item.enabled))
        }
    }
}

enum SMAppServiceSettings {
    static func open() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}
