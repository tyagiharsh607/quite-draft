import Foundation

final class OpenAIProvider: LLMProvider {
    private let apiKey: String
    private let model: String
    private let reasoningEffort: String
    private let session = URLSession(configuration: .default)

    init(apiKey: String, model: String, reasoningEffort: String = "minimal") {
        self.apiKey = apiKey
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    func answer(
        history: [ChatMessage],
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw LLMError.badResponse("Missing OPENAI_API_KEY (set it in .env)")
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": history.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": true
        ]
        if !reasoningEffort.isEmpty {
            body["reasoning_effort"] = reasoningEffort
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        debugLog("[llm] stream start, model=\(model) effort=\(reasoningEffort) historyCount=\(history.count) bodyBytes=\(request.httpBody?.count ?? 0)")
        let t0 = Date()

        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.badResponse("Invalid response from OpenAI")
        }
        guard (200..<300).contains(http.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw LLMError.badResponse("OpenAI request failed: \(errorBody.isEmpty ? "HTTP \(http.statusCode)" : errorBody)")
        }

        struct StreamChunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta
            }
            let choices: [Choice]
        }

        var assembled = ""
        var sawFirstToken = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let piece = chunk.choices.first?.delta.content,
                  !piece.isEmpty
            else { continue }

            if !sawFirstToken {
                sawFirstToken = true
                debugLog("[llm] first token after \(Date().timeIntervalSince(t0))s")
            }
            assembled += piece
            onDelta(assembled)
        }

        debugLog("[llm] stream finished after \(Date().timeIntervalSince(t0))s, chars=\(assembled.count)")
        guard !assembled.isEmpty else {
            throw LLMError.badResponse("Empty response from OpenAI")
        }
        return assembled
    }
}
