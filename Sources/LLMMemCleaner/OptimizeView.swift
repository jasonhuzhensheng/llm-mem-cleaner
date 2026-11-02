import SwiftUI

/// "Crazy optimize": finds big idle models, model services, VMs, background processes and apps,
/// pre-checks the safe ones, and frees them in one click. Optional auto mode when memory is tight.
struct OptimizeSection: View {
    @Bindable var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let candidates = model.optimizeCandidates {
                list(candidates)
            } else {
                Button {
                    Task { await model.scanOptimize() }
                } label: {
                    Label(model.optimizeScanning ? tr("正在分析空闲的大内存占用…", "Looking for big idle memory users…")
                                                 : tr("疯狂优化内存", "Crazy optimize"),
                          systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.orange)
                .disabled(model.optimizeScanning || model.optimizing)
            }
            Toggle(isOn: $model.autoOptimize) {
                Text(tr("内存超过 \(Int(MonitorModel.autoOptimizeThreshold * 100))% 时自动优化（只处理空闲的模型、模型服务和虚拟机）",
                        "Auto-optimize above \(Int(MonitorModel.autoOptimizeThreshold * 100))% used (idle models, model services and VMs only)"))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch).controlSize(.mini)
        }
    }

    @ViewBuilder private func list(_ candidates: [OptimizeCandidate]) -> some View {
        SectionTitle(text: tr("疯狂优化：能清理的都已勾选", "Crazy optimize: everything clearable is checked"))
        if candidates.isEmpty {
            Text(tr("没有发现空闲的大内存占用，内存都在被正常使用。", "Nothing big and idle found; memory is in active use."))
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(candidates) { c in
            HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { model.optimizeSelection.contains(c.id) },
                    set: { on in if on { model.optimizeSelection.insert(c.id) } else { model.optimizeSelection.remove(c.id) } }))
                    .labelsHidden().toggleStyle(.checkbox)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text(c.detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(formatBytes(c.memory)).font(.callout.monospacedDigit())
            }
        }
        HStack {
            Button {
                Task { await model.runOptimize() }
            } label: {
                if model.optimizing {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Text(tr("一键优化 · 约 \(formatBytes(model.optimizeSelectedBytes))", "Optimize · ~\(formatBytes(model.optimizeSelectedBytes))"))
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.optimizeSelection.isEmpty || model.optimizing)
            Button(tr("取消", "Cancel")) { model.optimizeCandidates = nil }
                .disabled(model.optimizing)
        }
        Text(tr("所有空闲的都已勾选，包括后台应用：模型卸载、服务和虚拟机正常停止，应用正常退出（5 秒后强制）。你正在用的应用和正在忙的项目不勾选。退出前请先保存。",
                "Everything idle is checked, apps included: models unload, services and VMs shut down cleanly, apps quit (forced after 5 s). The app you're using and busy items stay unchecked. Save your work first."))
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
