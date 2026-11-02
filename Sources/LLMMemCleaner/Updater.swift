import AppKit

/// Updates from the GitHub repo's latest release: compares versions, downloads the .zip asset,
/// swaps the installed bundle and relaunches.
enum Updater {
    static let latestURL = URL(string: "https://api.github.com/repos/jasonhuzhensheng/llm-mem-cleaner/releases/latest")!

    struct Release {
        let version: String
        let notes: String
        let zip: URL
    }

    private struct Response: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let body: String?
        let assets: [Asset]
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The latest release if it's newer than this build; nil when up to date. Throws on network errors.
    static func check() async throws -> Release? {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        // 404 = no release published yet.
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        let r = try JSONDecoder().decode(Response.self, from: data)
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        guard isNewer(version, than: currentVersion),
              let asset = r.assets.first(where: { $0.name.hasSuffix(".zip") }),
              asset.browser_download_url.host?.hasSuffix("github.com") == true else { return nil }
        return Release(version: version, notes: r.body ?? "", zip: asset.browser_download_url)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Downloads and installs the release over the running app, then relaunches it.
    /// Returns an error message, or never returns on success (the app quits).
    @MainActor
    static func install(_ release: Release) async -> String? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "llm-mem-cleaner-update-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, _) = try await URLSession.shared.download(from: release.zip)
            let zip = work.appending(path: "update.zip")
            try fm.moveItem(at: downloaded, to: zip)
            guard await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])?.status == 0 else {
                return tr("解压失败", "Couldn't unpack the update")
            }
            guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }),
                  Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                return tr("更新包内容不对", "The update package isn't this app")
            }
            let target = Bundle.main.bundleURL
            _ = try fm.replaceItemAt(target, withItemAt: newApp)
            // Relaunch once this process has exited.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", target.path]
            try p.run()
            NSApp.terminate(nil)
            return nil
        } catch {
            return tr("更新失败：", "Update failed: ") + error.localizedDescription
        }
    }
}
