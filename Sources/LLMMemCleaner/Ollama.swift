import Foundation

/// Minimal client for the local Ollama server (http://localhost:11434).
enum Ollama {
    struct LoadedModel: Decodable, Identifiable {
        let name: String
        let size: UInt64
        var id: String { name }
    }

    private struct PSResponse: Decodable { let models: [LoadedModel] }

    static let base = URL(string: "http://localhost:11434")!

    /// nil when Ollama isn't running.
    static func loadedModels() async -> [LoadedModel]? {
        var req = URLRequest(url: base.appending(path: "api/ps"))
        req.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let ps = try? JSONDecoder().decode(PSResponse.self, from: data) else { return nil }
        return ps.models
    }

    private struct TagsResponse: Decodable { let models: [LoadedModel] }

    /// Models downloaded to disk (nil when Ollama isn't running).
    static func installedModels() async -> [LoadedModel]? {
        var req = URLRequest(url: base.appending(path: "api/tags"))
        req.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let tags = try? JSONDecoder().decode(TagsResponse.self, from: data) else { return nil }
        return tags.models.sorted { $0.size > $1.size }
    }

    /// Deletes a model's weights from disk (same as `ollama rm`).
    static func delete(_ model: String) async {
        var req = URLRequest(url: base.appending(path: "api/delete"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// keep_alive: 0 tells Ollama to evict the model from memory immediately.
    static func unload(_ model: String) async {
        var req = URLRequest(url: base.appending(path: "api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        _ = try? await URLSession.shared.data(for: req)
    }
}
