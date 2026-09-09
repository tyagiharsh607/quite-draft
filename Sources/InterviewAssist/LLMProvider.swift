import Foundation

struct ChatMessage: Identifiable {
    enum Role: String { case system, user, assistant }
    let id: UUID
    let role: Role
    var content: String

    init(role: Role, content: String, id: UUID = UUID()) {
        self.id = id
        self.role = role
        self.content = content
    }
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
