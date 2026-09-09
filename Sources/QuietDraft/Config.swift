import Foundation

enum Config {
    static let openAIAPIKey: String = value(for: "OPENAI_API_KEY") ?? ""
    static let openAIModel: String = value(for: "OPENAI_MODEL") ?? "gpt-5"
    // Reasoning models (gpt-5 family) can take 1-2 minutes at default effort;
    // "minimal" is the lowest this model allows (it rejects "none").
    static let reasoningEffort: String = value(for: "OPENAI_REASONING_EFFORT") ?? "minimal"
    static let whisperModelPath: String = value(for: "WHISPER_MODEL_PATH")
        ?? (NSHomeDirectory() + "/.cache/hyperframes/whisper/models/ggml-small.en.bin")
    static let resumeOrJDContext: String? = value(for: "RESUME_OR_JD_CONTEXT")

    private static let dotEnv: [String: String] = {
        for path in envFileCandidates() {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                debugLog("[config] loaded env from \(path)")
                return parse(contents)
            }
        }
        debugLog("[config] no .env found; cwd=\(FileManager.default.currentDirectoryPath) bundle=\(Bundle.main.bundlePath)")
        return [:]
    }()

    /// Finder / `open` / /Applications do not keep the project directory as cwd,
    /// so walk up from the binary and also check ~/.config/quietdraft/.env.
    private static func envFileCandidates() -> [String] {
        var paths: [String] = [
            FileManager.default.currentDirectoryPath + "/.env",
            NSHomeDirectory() + "/.config/quietdraft/.env",
        ]
        var dirs: [URL] = []
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            dirs.append(exeDir)
        }
        dirs.append(URL(fileURLWithPath: Bundle.main.bundlePath, isDirectory: true))
        for start in dirs {
            var dir = start
            for _ in 0..<8 {
                paths.append(dir.appendingPathComponent(".env").path)
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in contents.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            result[key] = val
        }
        return result
    }

    private static func value(for key: String) -> String? {
        if let env = ProcessInfo.processInfo.environment[key], !env.isEmpty {
            return env
        }
        return dotEnv[key]
    }
}
