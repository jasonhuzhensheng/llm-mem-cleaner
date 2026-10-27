import Darwin
import Foundation

/// A model currently loaded in memory by some local LLM runtime.
struct RunningModel: Identifiable {
    enum Runtime: String {
        case ollama = "Ollama"
        case lmStudio = "LM Studio"
        case mlxServe = "MLX-Serve"
        case llamaCpp = "llama.cpp"
        case mlxLM = "mlx-lm"
        case kapitsa = "Kapitsa"
        case other = "Other"

        /// Runtimes that can drop a model without stopping their server.
        var unloadsInPlace: Bool { self == .ollama || self == .lmStudio }
    }

    let runtime: Runtime
    /// Shown instead of the runtime name for engines found by the generic rule.
    var engine: String?
    let name: String
    /// Ollama model name or LM Studio identifier; empty for server processes.
    let unloadKey: String
    var contextLength: Int?
    var fileSize: UInt64?
    /// Summed phys_footprint of the serving processes (weights mapped from disk aren't included).
    var memory: UInt64?
    var pids: [Int] = []
    var port: Int?

    var id: String { "\(runtime.rawValue)|\(unloadKey.isEmpty ? pids.map(String.init).joined(separator: ",") : unloadKey)" }

    /// e.g. "qwen3.8|27b", used to spot the same model loaded by two runtimes.
    var familyKey: String? { RunningModels.familyKey(name) }
}

enum RunningModels {
    static let lms = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".lmstudio/bin/lms").path

    static func scan() async -> [RunningModel] {
        let servers = serverProcesses()
        async let ollamaModels = Ollama.loadedModels()
        async let lmStudioModels = lmStudioLoaded()
        var result: [RunningModel] = []

        // Ollama: names and context from the API, memory from its runner processes.
        let ollamaProcs = servers.filter { $0.runtime == .ollama }
        if let models = await ollamaModels {
            for m in models {
                let procs = ollamaProcs.filter { $0.ollamaName == m.name }
                result.append(RunningModel(runtime: .ollama, name: m.name, unloadKey: m.name,
                                           contextLength: m.contextLength, fileSize: m.size,
                                           memory: sumMemory(procs), pids: procs.map(\.pid)))
            }
        }

        // LM Studio: what `lms ps` reports, with memory from the llama-server serving that file.
        let lmProcs = servers.filter { $0.runtime == .lmStudio }
        for m in await lmStudioModels {
            let procs = lmProcs.filter { p in p.modelPath.map { $0.hasSuffix(m.path) } ?? false }
            result.append(RunningModel(runtime: .lmStudio, name: m.displayName, unloadKey: m.identifier,
                                       contextLength: m.contextLength, fileSize: m.sizeBytes,
                                       memory: sumMemory(procs), pids: procs.map(\.pid)))
        }

        // Standalone servers (MLX-Serve, plain llama.cpp, mlx-lm): one row per process.
        let claimed = Set(result.flatMap(\.pids))
        for p in servers where !claimed.contains(p.pid) && p.runtime != .ollama && p.runtime != .lmStudio {
            let name = p.modelPath.map { prettyModelName($0) } ?? p.executable
            result.append(RunningModel(runtime: p.runtime, engine: p.runtime == .other ? p.executable : nil,
                                       name: name, unloadKey: "",
                                       contextLength: p.contextLength,
                                       fileSize: p.modelPath.flatMap(fileSize),
                                       memory: p.memory, pids: [p.pid], port: p.port))
        }
        return result.sorted { ($0.memory ?? $0.fileSize ?? 0) > ($1.memory ?? $1.fileSize ?? 0) }
    }

    /// Ollama and LM Studio unload the model and keep serving; standalone servers are stopped.
    static func unload(_ m: RunningModel) async -> Bool {
        switch m.runtime {
        case .ollama:
            await Ollama.unload(m.unloadKey)
            return await !(Ollama.loadedModels()?.contains { $0.name == m.unloadKey } ?? false)
        case .lmStudio:
            return await Shell.run(lms, ["unload", m.unloadKey])?.status == 0
        default:
            return m.pids.allSatisfy { kill(pid_t($0), SIGTERM) == 0 }
        }
    }

    // MARK: - Server processes

    struct ServerProcess {
        let pid: Int
        let executable: String
        let runtime: RunningModel.Runtime
        let modelPath: String?
        let contextLength: Int?
        let port: Int?
        let memory: UInt64?
        /// For Ollama runners: the model name resolved from the blob digest.
        var ollamaName: String?
    }

    private static let serverExecutables: Set<String> = ["llama-server", "mlx-serve", "llama-box", "koboldcpp", "kapitsa"]
    /// Unknown engines count when they use this much memory and look like a model server.
    private static let genericMinFootprint: UInt64 = 1 << 30

    static func serverProcesses() -> [ServerProcess] {
        var out: [ServerProcess] = []
        for pid in AppSampler.allPIDs() where pid > 0 {
            guard let path = executablePath(Int(pid)) else { continue }
            let exe = (path as NSString).lastPathComponent
            let isPython = exe.hasPrefix("python")
            let known = serverExecutables.contains(exe) || isPython
            let footprint = AppSampler.rusage(pid)?.ri_phys_footprint
            guard known || (footprint ?? 0) >= genericMinFootprint else { continue }
            guard let args = processArguments(Int(pid)) else { continue }
            if isPython && !args.contains(where: { $0.contains("mlx_lm") || $0.contains("vllm") }) { continue }
            if !known && !(flag(args, ["--model", "-m"]) != nil && (args.contains("serve") || flag(args, ["--port"]) != nil)) { continue }

            let runtime: RunningModel.Runtime =
                path.contains("Ollama.app") || path.contains("/ollama") ? .ollama
                : path.contains("/.lmstudio/") ? .lmStudio
                : path.contains("MLX-Serve") || exe == "mlx-serve" ? .mlxServe
                : isPython && args.contains(where: { $0.contains("mlx_lm") }) ? .mlxLM
                : exe == "llama-server" ? .llamaCpp
                : exe == "kapitsa" ? .kapitsa : .other
            let model = flag(args, ["--model", "-m"])
            var proc = ServerProcess(
                pid: Int(pid), executable: exe, runtime: runtime, modelPath: model,
                contextLength: flag(args, ["--ctx-size", "-c", "--context", "--max-kv-size", "--max-model-len"]).flatMap(tokenCount),
                port: flag(args, ["--port"]).flatMap { Int($0) },
                memory: footprint)
            if runtime == .ollama, let model { proc.ollamaName = ollamaName(forBlob: model) }
            out.append(proc)
        }
        return out
    }

    /// argv of a process we own (KERN_PROCARGS2: argc, exec path, padding, then argv strings).
    static func processArguments(_ pid: Int) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }   // exec path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// "32768", "32k" or "1m" → tokens.
    static func tokenCount(_ s: String) -> Int? {
        let l = s.lowercased()
        if let n = Int(l) { return n }
        guard let unit = l.last, let n = Double(l.dropLast()) else { return nil }
        switch unit {
        case "k": return Int(n * 1024)
        case "m": return Int(n * 1024 * 1024)
        default: return nil
        }
    }

    /// Value of `--name value` or `--name=value`.
    static func flag(_ args: [String], _ names: [String]) -> String? {
        for (i, a) in args.enumerated() {
            for n in names {
                if a == n, i + 1 < args.count { return args[i + 1] }
                if a.hasPrefix(n + "=") { return String(a.dropFirst(n.count + 1)) }
            }
        }
        return nil
    }

    // MARK: - Ollama blob → name

    /// Ollama runners get a blob path ("…/blobs/sha256-<hex>"); the sibling manifests
    /// directory maps that digest back to "family:tag".
    static func ollamaName(forBlob blob: String) -> String? {
        let file = (blob as NSString).lastPathComponent
        guard file.hasPrefix("sha256-") else { return nil }
        let digest = "sha256:" + file.dropFirst("sha256-".count)
        let root = ((blob as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let manifests = URL(fileURLWithPath: root).appending(path: "manifests")
        guard let e = FileManager.default.enumerator(at: manifests, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let layers = json["layers"] as? [[String: Any]],
                  layers.contains(where: { $0["digest"] as? String == digest }) else { continue }
            // manifests/<registry>/<namespace>/<model>/<tag>
            let parts = url.path.dropFirst(manifests.path.count + 1).split(separator: "/").map(String.init)
            guard parts.count >= 4 else { continue }
            let namespace = parts[1], model = parts[2], tag = parts[3]
            return (namespace == "library" ? "" : namespace + "/") + model + ":" + tag
        }
        return nil
    }

    // MARK: - LM Studio

    struct LMStudioModel: Decodable {
        let identifier: String
        let displayName: String
        let path: String
        let sizeBytes: UInt64?
        let contextLength: Int?
    }

    static func lmStudioLoaded() async -> [LMStudioModel] {
        guard FileManager.default.isExecutableFile(atPath: lms),
              let out = await Shell.run(lms, ["ps", "--json"])?.output,
              let start = out.firstIndex(of: "["),
              let data = out[start...].data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([LMStudioModel].self, from: data)) ?? []
    }

    // MARK: - Helpers

    private static func sumMemory(_ procs: [ServerProcess]) -> UInt64? {
        let values = procs.compactMap(\.memory)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    static func fileSize(_ path: String) -> UInt64? {
        // MLX models are directories of shards; GGUF is a single file.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? nil
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return files.reduce(0) { sum, f in
            sum + ((try? FileManager.default.attributesOfItem(atPath: path + "/" + f)[.size] as? UInt64) ?? 0)
        }
    }

    /// "…/Qwen3.8-Flash-Next-MLX-4.7bpw" or "…/model-Q4_K_M.gguf" → readable name.
    static func prettyModelName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.hasSuffix(".gguf") ? String(last.dropLast(5)) : last
    }

    static func familyKey(_ name: String) -> String? {
        let s = name.lowercased()
        let family = s.range(of: #"(qwen|llama|gemma|mistral|mixtral|phi|deepseek|glm|gpt-oss|yi|command-r|granite|olmo)[\d.]*"#,
                             options: .regularExpression).map { String(s[$0]) }
        let size = s.range(of: #"\d+(\.\d+)?b(?![a-z])"#, options: .regularExpression).map { String(s[$0]) }
        guard let family, let size else { return nil }
        return "\(family)|\(size)"
    }
}
