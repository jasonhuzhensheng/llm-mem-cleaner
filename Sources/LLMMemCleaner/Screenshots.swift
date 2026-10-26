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
        let hosting = NSHostingView(rootView: ContentView(model: model, fullHeight: true))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 460, height: 640),
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
        // Size the window to the tab's natural height so nothing is cut off or padded.
        view.layoutSubtreeIfNeeded()
        let height = max(view.fittingSize.height, 200)
        view.window?.setContentSize(NSSize(width: 460, height: height))
        view.setFrameSize(NSSize(width: 460, height: height))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? opaque(rep, appearance: view.window?.appearance)?.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The hosting view draws no background, so the capture is transparent and turns black on
    /// dark-themed pages. Flatten it onto the window background color.
    private static func opaque(_ rep: NSBitmapImageRep, appearance: NSAppearance?) -> NSBitmapImageRep? {
        guard let image = rep.cgImage,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        var background = NSColor.windowBackgroundColor.cgColor
        (appearance ?? NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(background)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        guard let flat = ctx.makeImage() else { return nil }
        let out = NSBitmapImageRep(cgImage: flat)
        out.size = rep.size  // keep 2x density metadata
        return out
    }
}
