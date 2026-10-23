import AppKit
import SwiftUI

/// `LLMMemCleaner --screenshots <dir> [light|dark] [zh|en]` renders every tab of the panel
/// into PNGs (for the README) and quits. Draws the app's own window, so no screen-recording
/// permission is needed.
@MainActor
enum Screenshots {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        let dark = args.contains("dark")
        if args.contains("en") { L10n.current = .en } else if args.contains("zh") { L10n.current = .zh }

        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            await capture(to: dir, dark: dark)
            exit(0)
        }
    }

    private static func capture(to dir: URL, dark: Bool) async {
        let model = MonitorModel()
        model.language = L10n.current
        let hosting = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 440, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.orderFrontRegardless()

        await model.scanStorage()
        await model.runSpeedTest()

        for tab in Tab.allCases {
            model.tab = tab
            // Two refreshes so rate-based numbers (CPU, GPU %, network) have a baseline.
            await model.refreshPanel()
            try? await Task.sleep(for: .seconds(2))
            await model.refreshPanel()
            try? await Task.sleep(for: .milliseconds(500))
            save(hosting, to: dir.appending(path: "\(tab.rawValue).png"))
        }
        model.showAbout = true
        try? await Task.sleep(for: .milliseconds(500))
        save(hosting, to: dir.appending(path: "about.png"))
    }

    private static func save(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.setFrameSize(NSSize(width: 440, height: max(size.height, 200)))
        view.window?.setContentSize(view.frame.size)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
