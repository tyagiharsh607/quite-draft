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
        let candidates = [
            FileManager.default.currentDirectoryPath + "/.env",
            Bundle.main.bundlePath + "/../.env",
            NSHomeDirectory() + "/.config/interview-assist/.env"
        ]
        for path in candidates {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                return parse(contents)
            }
        }
        return [:]
    }()

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
