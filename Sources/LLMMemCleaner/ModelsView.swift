import SwiftUI

/// LLMs currently loaded by Ollama, LM Studio, MLX-Serve, llama.cpp or mlx-lm, with unload buttons.
struct ModelsTab: View {
    @Bindable var model: MonitorModel
    @State private var pending: String?

    var body: some View {
        let models = model.runningModels ?? []
        let total = models.reduce(UInt64(0)) { $0 + ($1.memory ?? 0) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                BigNumber(title: tr("正在运行的大模型", "Running models"), value: "\(models.count)")
                Spacer()
                if total > 0 {
                    BigNumber(title: tr("合计内存", "Total memory"), value: formatBytes(total))
                }
            }

            if let dup = duplicates(models) {
                warning(dup)
            }

            if model.runningModels == nil {
                ProgressView(tr("正在检测…", "Detecting…")).controlSize(.small)
            } else if models.isEmpty {
                Text(model.llmServices.isEmpty
                     ? tr("当前没有大模型在运行。", "No models are loaded right now.")
                     : tr("当前没有加载模型，但下面的服务仍在运行、占用内存。", "No models are loaded, but the services below are still running and using memory."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                unloadAllButton(models)
                ForEach(models) { m in
                    Divider()
                    row(m)
                }
            }

            if !model.llmServices.isEmpty {
                servicesSection
            }

            Divider()
            Text(tr("支持 Ollama、LM Studio、MLX-Serve、llama.cpp、mlx-lm、Kapitsa，以及其他带 --model 参数、占用 1GB 以上的模型服务。Ollama 和 LM Studio 卸载后服务继续运行；其他是独立服务，卸载即停止该服务。内存为进程实际占用，按需从磁盘映射的权重不计入。",
                    "Detects Ollama, LM Studio, MLX-Serve, llama.cpp, mlx-lm, Kapitsa, and other servers started with --model that use over 1 GB. Ollama and LM Studio keep serving after an unload; the others are standalone servers, so unloading stops them. Memory is the process footprint; weights memory-mapped from disk aren't counted."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Rows

    private func row(_ m: RunningModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(m.engine ?? m.runtime.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(color(m.runtime).opacity(0.2)))
                    .foregroundStyle(color(m.runtime))
                Text(m.name).font(.callout.bold()).lineLimit(1).truncationMode(.middle)
                Spacer()
                action(m)
            }
            Text(details(m)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let ctx = m.contextLength, ctx >= 131_072 {
                Text(tr("上下文 \(contextLabel(ctx)) 会占用大量内存，日常 32K 通常够用，可在 \(m.engine ?? m.runtime.rawValue) 里调小。",
                        "A \(contextLabel(ctx)) context uses a lot of memory; 32K is usually enough — lower it in \(m.engine ?? m.runtime.rawValue)."))
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func action(_ m: RunningModel) -> some View {
        let label = m.runtime.unloadsInPlace ? tr("卸载", "Unload") : tr("停止服务", "Stop server")
        if model.unloading.contains(m.id) {
            ProgressView().controlSize(.small)
        } else if pending == m.id {
            Button(tr("确认", "Confirm")) {
                pending = nil
                Task { await model.unloadModels([m]) }
            }
            .tint(.red)
            .controlSize(.small)
            Button(tr("取消", "Cancel")) { pending = nil }.controlSize(.small)
        } else {
            Button(label) { pending = m.id }.controlSize(.small)
        }
    }

    @ViewBuilder private func unloadAllButton(_ models: [RunningModel]) -> some View {
        let total = models.reduce(UInt64(0)) { $0 + ($1.memory ?? $1.fileSize ?? 0) }
        if pending == "all" {
            HStack {
                Button(tr("确认全部卸载", "Unload all")) {
                    pending = nil
                    Task { await model.unloadModels(models) }
                }
                .buttonStyle(.borderedProminent).tint(.red)
                Button(tr("取消", "Cancel")) { pending = nil }
            }
        } else {
            Button {
                pending = "all"
            } label: {
                Label(tr("一键全部卸载 · 约 \(formatBytes(total))", "Unload all · ~\(formatBytes(total))"),
                      systemImage: "eject")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.unloading.isEmpty)
        }
    }

    // MARK: Services

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: tr("运行中的服务（前台 + 后台）", "Running services (foreground + background)"))
            ForEach(model.llmServices) { s in
                HStack(spacing: 8) {
                    Text(s.name)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(color(s.runtime).opacity(0.2)))
                        .foregroundStyle(color(s.runtime))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(placement(s)).font(.callout)
                        Text(serviceDetails(s)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                    serviceAction(s)
                }
            }
            Text(tr("停止服务会退出应用并关闭后台进程，已加载的模型一并释放。通过 brew services 或登录项启动的服务可能会被自动重启，可在「启动项」里关闭。",
                    "Stopping quits the app and shuts down its background processes, releasing any loaded models. Services started by brew services or login items may restart; turn them off under Startup."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func placement(_ s: LLMService) -> String {
        switch (s.hasApp, s.hasDaemon) {
        case (true, true): tr("前台应用 + 后台服务", "App + background service")
        case (true, false): tr("前台应用", "App")
        default: tr("后台服务（无窗口）", "Background service (no window)")
        }
    }

    private func serviceDetails(_ s: LLMService) -> String {
        let loaded = (model.runningModels ?? []).filter { $0.runtime == s.runtime }.count
        var parts = [tr("内存 ", "Memory ") + formatBytes(s.memory),
                     tr("\(s.pids.count) 个进程", "\(s.pids.count) processes"),
                     tr("已加载 \(loaded) 个模型", "\(loaded) loaded")]
        if s.hasDaemon { parts.append(s.daemons.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func serviceAction(_ s: LLMService) -> some View {
        let key = "service|" + s.id
        if model.unloading.contains(s.id) {
            ProgressView().controlSize(.small)
        } else if pending == key {
            Button(tr("确认", "Confirm")) {
                pending = nil
                Task { await model.stopService(s) }
            }
            .tint(.red)
            .controlSize(.small)
            Button(tr("取消", "Cancel")) { pending = nil }.controlSize(.small)
        } else {
            Button(tr("停止", "Stop")) { pending = key }.controlSize(.small)
        }
    }

    // MARK: Duplicates

    /// Same family + size loaded more than once (e.g. by both Ollama and LM Studio).
    private func duplicates(_ models: [RunningModel]) -> [RunningModel]? {
        let groups = Dictionary(grouping: models.filter { $0.familyKey != nil }, by: { $0.familyKey! })
        return groups.values.first { $0.count > 1 }
    }

    private func warning(_ dup: [RunningModel]) -> some View {
        let runtimes = dup.map(\.runtime.rawValue).joined(separator: tr("、", ", "))
        let extra = dup.dropFirst().reduce(UInt64(0)) { $0 + ($1.memory ?? $1.fileSize ?? 0) }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(tr("同一个模型被加载了 \(dup.count) 份（\(runtimes)）。只保留一份可再释放约 \(formatBytes(extra))。",
                    "The same model is loaded \(dup.count) times (\(runtimes)). Keeping one frees ~\(formatBytes(extra))."))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    // MARK: Formatting

    private func details(_ m: RunningModel) -> String {
        var parts: [String] = []
        if let mem = m.memory { parts.append(tr("内存 ", "Memory ") + formatBytes(mem)) }
        if let size = m.fileSize { parts.append(tr("文件 ", "File ") + formatBytes(size)) }
        if let ctx = m.contextLength { parts.append(tr("上下文 ", "Context ") + contextLabel(ctx)) }
        if let port = m.port { parts.append(tr("端口 ", "Port ") + String(port)) }
        if let s = model.llmServices.first(where: { $0.runtime == m.runtime && $0.runtime != .other }) {
            parts.append(s.hasApp ? tr("前台", "Foreground") : tr("后台", "Background"))
        } else if !m.runtime.unloadsInPlace {
            parts.append(tr("后台进程", "Background process"))
        }
        return parts.joined(separator: " · ")
    }

    private func contextLabel(_ tokens: Int) -> String {
        tokens >= 1024 ? "\(tokens / 1024)K" : "\(tokens)"
    }

    private func color(_ r: RunningModel.Runtime) -> Color {
        switch r {
        case .ollama: .blue
        case .lmStudio: .purple
        case .mlxServe: .green
        case .llamaCpp: .orange
        case .mlxLM: .teal
        case .kapitsa: .pink
        case .other: .gray
        }
    }
}
