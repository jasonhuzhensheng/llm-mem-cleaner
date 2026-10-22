import AppKit
import Foundation

/// A directory that can be moved to the Trash to reclaim disk space.
struct CleanupItem: Identifiable {
    let group: String
    let name: String
    let url: URL
    var size: UInt64 = 0
    /// Only shown, never offered for deletion (e.g. the Trash itself).
    var revealOnly = false
    /// Regenerable cache, included in one-click cleaning.
    var isCache = false
    var id: String { url.path }
}

enum StorageCleanup {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    /// Folders smaller than this aren't worth listing.
    static let minSize: UInt64 = 100 << 20

    static func scan() async -> [CleanupItem] {
        await Task.detached(priority: .utility) {
            var items: [CleanupItem] = []

            // Hugging Face hub cache: one folder per model / dataset.
            let hf = home.appending(path: ".cache/huggingface/hub")
            for dir in subdirectories(of: hf) where dir.lastPathComponent.contains("--") {
                let name = dir.lastPathComponent.split(separator: "--").dropFirst().joined(separator: "/")
                items.append(CleanupItem(group: "Hugging Face", name: name, url: dir))
            }

            // LM Studio keeps models as <publisher>/<model>.
            for root in [".lmstudio/models", ".cache/lm-studio/models"] {
                for publisher in subdirectories(of: home.appending(path: root)) {
                    for model in subdirectories(of: publisher) {
                        items.append(CleanupItem(group: "LM Studio",
                                                 name: "\(publisher.lastPathComponent)/\(model.lastPathComponent)",
                                                 url: model))
                    }
                }
            }

            for (name, path) in devCaches {
                let dir = home.appending(path: path)
                guard FileManager.default.fileExists(atPath: dir.path) else { continue }
                items.append(CleanupItem(group: tr("开发缓存", "Developer caches"), name: name, url: dir,
                                         isCache: true))
            }

            for dir in subdirectories(of: home.appending(path: "Library/Caches")) {
                let name = dir.lastPathComponent
                items.append(CleanupItem(group: tr("应用缓存", "App caches"), name: name, url: dir,
                                         isCache: !name.hasPrefix("com.apple.")))
            }

            let trash = home.appending(path: ".Trash")
            items.append(CleanupItem(group: tr("废纸篓", "Trash"), name: tr("废纸篓（需在 Finder 中清倒）", "Trash (empty it in Finder)"), url: trash,
                                     revealOnly: true))

            // Sizing is the slow part (walking every file), and folders are independent: do them in parallel.
            items.withUnsafeMutableBufferPointer { buffer in
                // Each iteration writes only its own index, so concurrent access is safe.
                nonisolated(unsafe) let buf = buffer
                DispatchQueue.concurrentPerform(iterations: buf.count) { i in
                    buf[i].size = allocatedSize(buf[i].url)
                }
            }
            return items.filter { $0.size >= minSize }.sorted { $0.size > $1.size }
        }.value
    }

    /// Tool caches outside ~/Library/Caches that rebuild themselves on demand.
    static let devCaches: [(name: String, path: String)] = [
        ("Xcode DerivedData", "Library/Developer/Xcode/DerivedData"),
        ("npm", ".npm/_cacache"),
        ("pip", ".cache/pip"),
        ("uv", ".cache/uv"),
        ("Gradle", ".gradle/caches"),
    ]

    /// Permanently deletes the *contents* of each cache folder (the folder itself stays, so apps
    /// that expect it keep working). Items that can't be removed (in use / protected) are skipped.
    static func purgeCaches(_ items: [CleanupItem]) async -> (freed: UInt64, failed: Int) {
        await Task.detached(priority: .utility) {
            var freed: UInt64 = 0, failed = 0
            let fm = FileManager.default
            for item in items where item.isCache && !item.revealOnly {
                let children = (try? fm.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil)) ?? []
                for child in children {
                    do { try fm.removeItem(at: child) } catch { failed += 1 }
                }
                let after = allocatedSize(item.url)
                freed += item.size > after ? item.size - after : 0
            }
            return (freed, failed)
        }.value
    }

    static func subdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return contents.filter {
            let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return v?.isDirectory == true && v?.isSymbolicLink != true
        }
    }

    /// On-disk size; symlinks aren't followed, so HF snapshot links don't double-count blobs.
    static func allocatedSize(_ url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                      options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in e {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += UInt64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Moves to the Trash (recoverable); space is reclaimed once the Trash is emptied.
    static func moveToTrash(_ item: CleanupItem) -> String? {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func reveal(_ item: CleanupItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}
