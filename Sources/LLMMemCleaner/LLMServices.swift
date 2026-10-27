import AppKit
import Darwin

/// An LLM runtime that is running, whether or not it has a model loaded: its app (foreground)
/// and/or its daemons (background, e.g. `ollama serve`, LM Studio's `llmster`).
struct LLMService: Identifiable {
    let name: String
    let runtime: RunningModel.Runtime
    var apps: [NSRunningApplication] = []
    /// Every process of the runtime, app included.
    var pids: [Int] = []
    /// Executable names of the processes that aren't the app itself.
    var daemons: [String] = []
    var memory: UInt64 = 0

    var id: String { name }
    var hasApp: Bool { !apps.isEmpty }
    var hasDaemon: Bool { !daemons.isEmpty }
}

enum LLMServices {
    /// (name, runtime, app bundle names, daemon executables, path markers)
    private static let known: [(String, RunningModel.Runtime, [String], Set<String>, [String])] = [
        ("Ollama", .ollama, ["Ollama.app"], ["ollama"], ["/Ollama.app/"]),
        ("LM Studio", .lmStudio, ["LM Studio.app"], ["llmster"], ["/LM Studio.app/", "/.lmstudio/"]),
        ("MLX-Serve", .mlxServe, ["MLX-Serve.app"], ["mlx-serve"], ["/MLX-Serve.app/"]),
        ("Jan", .other, ["Jan.app"], [], ["/Jan.app/"]),
        ("Msty", .other, ["Msty.app"], [], ["/Msty.app/"]),
        ("GPT4All", .other, ["GPT4All.app", "gpt4all.app"], [], ["/GPT4All.app/", "/gpt4all.app/"]),
    ]

    static func scan() -> [LLMService] {
        var services: [String: LLMService] = [:]
        let apps = NSWorkspace.shared.runningApplications
        for pid in AppSampler.allPIDs() where pid > 0 {
            guard let path = executablePath(Int(pid)) else { continue }
            let exe = (path as NSString).lastPathComponent
            guard let k = known.first(where: { k in k.3.contains(exe) || k.4.contains { path.contains($0) } }) else { continue }
            var s = services[k.0] ?? LLMService(name: k.0, runtime: k.1)
            s.pids.append(Int(pid))
            s.memory += AppSampler.rusage(pid)?.ri_phys_footprint ?? 0
            if let app = apps.first(where: { $0.processIdentifier == pid }),
               let bundle = app.bundleURL?.lastPathComponent, k.2.contains(bundle) {
                s.apps.append(app)
            } else if !path.contains(".app/Contents/Frameworks/") {  // app helpers aren't daemons
                if !s.daemons.contains(exe) { s.daemons.append(exe) }
            }
            services[k.0] = s
        }
        return services.values.sorted { $0.memory > $1.memory }
    }

    /// Quits the app and shuts down the daemons. LM Studio's daemon has its own shutdown command;
    /// anything still alive afterwards gets SIGTERM.
    static func stop(_ s: LLMService) async -> Bool {
        if s.runtime == .lmStudio, FileManager.default.isExecutableFile(atPath: RunningModels.lms) {
            _ = await Shell.run(RunningModels.lms, ["daemon", "down"])
        }
        if s.hasApp { await AppSampler.quit(s.apps) }
        try? await Task.sleep(for: .seconds(1))
        for pid in s.pids where kill(pid_t(pid), 0) == 0 { kill(pid_t(pid), SIGTERM) }
        try? await Task.sleep(for: .seconds(1))
        return s.pids.allSatisfy { kill(pid_t($0), 0) != 0 }
    }
}
