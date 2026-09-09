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

    func answer(history: [ChatMessage]) async throws -> String {
        guard !apiKey.isEmpty else {
            throw LLMError.badResponse("Missing OPENAI_API_KEY (set it in .env)")
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": history.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        if !reasoningEffort.isEmpty {
            body["reasoning_effort"] = reasoningEffort
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        debugLog("[llm] request start, model=\(model) effort=\(reasoningEffort) historyCount=\(history.count) bodyBytes=\(request.httpBody?.count ?? 0)")
        let t0 = Date()

        let (data, response) = try await session.data(for: request)
        debugLog("[llm] request finished after \(Date().timeIntervalSince(t0))s")

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "unknown error"
            throw LLMError.badResponse("OpenAI request failed: \(text)")
        }

        struct Choice: Decodable { let message: MessageBody }
        struct MessageBody: Decodable { let content: String }
        struct ChatResponse: Decodable { let choices: [Choice] }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content else {
            throw LLMError.badResponse("Empty response from OpenAI")
        }
        return text
    }
}
