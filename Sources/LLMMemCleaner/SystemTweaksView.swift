import SwiftUI

/// Collapsible "System optimization" list on the Memory tab.
struct SystemTweaksSection: View {
    @Bindable var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.systemExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .rotationEffect(.degrees(model.systemExpanded ? 90 : 0))
                    SectionTitle(text: tr("系统优化", "System optimization"))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.systemExpanded {
                if let t = model.systemTweaks {
                    rows(t)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private func rows(_ t: SystemTweaks) -> some View {
        // Spotlight on the model disk
        ForEach(t.modelVolumes) { v in
            row(icon: "magnifyingglass",
                title: tr("聚焦索引「\(v.name)」", "Spotlight indexing on “\(v.name)”"),
                detail: tr("模型所在磁盘，索引几百 GB 的权重文件会吃内存和 CPU。关闭后这个盘的文件搜不到。聚焦现在占 \(formatBytes(t.spotlightMemory))",
                           "Holds your models; indexing huge weight files costs memory and CPU. Turning it off hides this disk from Spotlight search. Spotlight uses \(formatBytes(t.spotlightMemory)) now")) {
                Toggle("", isOn: Binding(get: { v.indexing }, set: { on in
                    Task { await model.applyTweak(tr("未修改（已取消或无权限）", "Not changed (cancelled or not permitted)")) {
                        await SystemTweaksService.setIndexing(v.path, on: on)
                    } }
                })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
        }
        if !t.homeModelFolders.isEmpty {
            row(icon: "folder.badge.minus",
                title: tr("聚焦排除模型文件夹", "Exclude model folders from Spotlight"),
                detail: tr("系统盘上的模型文件夹（\(t.homeModelFolders.map(shortPath).joined(separator: "、"))）。打开设置后把 Finder 里选中的文件夹拖进「隐私」列表",
                           "Model folders on the startup disk (\(t.homeModelFolders.map(shortPath).joined(separator: ", "))). Drag the folders selected in Finder into the Privacy list")) {
                Button(tr("打开设置", "Open")) { SystemTweaksService.openSpotlightPrivacy(revealing: t.homeModelFolders) }
                    .controlSize(.small)
            }
        }

        // Photos / media analysis
        row(icon: "photo.on.rectangle",
            title: tr("照片和媒体分析", "Photos and media analysis"),
            detail: t.analysisPaused
                ? tr("已暂停。照片里的人物、物体识别会停止更新，需要时再打开", "Paused. People and object recognition in Photos stops updating until resumed")
                : tr("后台扫描照片和视频，现在占 \(formatBytes(t.analysisMemory))。关闭后会暂停", "Scans photos and videos in the background, using \(formatBytes(t.analysisMemory)) now. Turn off to pause")) {
            Toggle("", isOn: Binding(get: { !t.analysisPaused }, set: { on in
                Task { await model.applyTweak(tr("未能修改照片分析", "Couldn't change media analysis")) {
                    await SystemTweaksService.setAnalysisPaused(!on)
                } }
            })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }

        // Apple Intelligence
        row(icon: "sparkles",
            title: tr("Apple 智能与 Siri", "Apple Intelligence & Siri"),
            detail: tr("相关进程现在占 \(formatBytes(t.intelligenceMemory))，使用时还会加载本地模型。不用的话可在设置里关闭",
                       "Related processes use \(formatBytes(t.intelligenceMemory)) now, plus on-device models when used. Turn it off in Settings if you don't use it")) {
            Button(tr("打开设置", "Open")) { SystemTweaksService.openIntelligenceSettings() }.controlSize(.small)
        }

        // Reduce transparency
        row(icon: "square.on.square.dashed",
            title: tr("减少透明度", "Reduce transparency"),
            detail: tr("减少窗口模糊效果，降低 WindowServer 的内存和 GPU 占用（现在 \(formatBytes(t.windowServerMemory))）",
                       "Fewer blur effects, so WindowServer uses less memory and GPU (\(formatBytes(t.windowServerMemory)) now)")) {
            if let on = t.reduceTransparency {
                Toggle("", isOn: Binding(get: { on }, set: { new in
                    Task { await model.applyTweak(tr("系统不允许直接修改，已打开辅助功能设置", "macOS didn't allow the change; opened Accessibility settings")) {
                        await SystemTweaksService.setReduceTransparency(new)
                    } }
                })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            } else {
                Button(tr("打开设置", "Open")) { _ = Task { await SystemTweaksService.setReduceTransparency(true) } }
                    .controlSize(.small)
            }
        }

        // Antivirus
        if let av = t.antivirus {
            row(icon: "shield.lefthalf.filled",
                title: av.name,
                detail: tr("\(av.name.split(separator: " ").first.map(String.init) ?? av.name) 相关进程共占约 \(formatBytes(av.memory))，还会拖慢网络和磁盘。macOS 自带 XProtect 防护；不需要的话可在它的菜单里卸载",
                           "Its processes use ~\(formatBytes(av.memory)), and it slows network and disk. macOS has XProtect built in; uninstall it from its menu if you don't need it")) {
                Button(tr("打开", "Open")) { SystemTweaksService.open(av.app) }.controlSize(.small)
            }
        }

        // GPU driver pools
        if t.gpuHeld >= GB {
            row(icon: "memorychip",
                title: tr("GPU 驱动保留的内存", "GPU memory held by the driver"),
                detail: tr("跑完模型后驱动还留着 \(formatBytes(t.gpuHeld))，只有重启才会还给系统",
                           "\(formatBytes(t.gpuHeld)) kept by the driver after models ran; only a restart returns it")) {
                EmptyView()
            }
        }
    }

    /// "/Users/x/.ollama/models" → ".ollama/models"
    private func shortPath(_ p: String) -> String {
        p.split(separator: "/").suffix(2).joined(separator: "/")
    }

    private func row<Trailing: View>(icon: String, title: String, detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
        .disabled(model.busy)
    }
}
