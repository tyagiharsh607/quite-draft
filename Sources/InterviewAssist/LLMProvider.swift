import Foundation

struct ChatMessage {
    enum Role: String { case system, user, assistant }
    let role: Role
    let content: String
}

/// Abstraction over the answering LLM so the backing provider/model can be
/// swapped via config without touching call sites.
protocol LLMProvider: AnyObject {
    /// Calls `onDelta` with the assembled answer so far as tokens arrive, then
    /// returns the complete text.
    func answer(
        history: [ChatMessage],
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

enum LLMError: Error, LocalizedError {
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let msg): return msg
        }
    }
}
