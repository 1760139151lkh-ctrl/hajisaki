import Foundation

enum ContextPinKind: String, Codable, CaseIterable, Sendable {
    case message, artifact, text
}

struct ContextPin: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var conversationID: String
    var kind: ContextPinKind
    var targetID: String?
    var content: String
    var createdAt: String
    var source: ContextPinSource?
    /// Client-owned scope, never submitted as part of the host API body.
    var clientContextID: String?

    var displayText: String {
        switch kind {
        case .message: return source?.content ?? content
        case .artifact: return source?.name ?? content
        case .text: return content
        }
    }
    enum CodingKeys: String, CodingKey {
        case id, kind, content, source
        case conversationID = "conversation_id", targetID = "target_id", createdAt = "created_at"
        case clientContextID = "client_context_id"
    }
}

/// GET pins includes message {role,content} or artifact metadata as `source`.
/// POST pins returns the saved anchor without this optional expansion.
struct ContextPinSource: Codable, Equatable, Sendable {
    var role: String?
    var content: String?
    var id: String?
    var name: String?
    var size: Int64?
    var mime: String?
    var sha256: String?
    var excerptOnly: Bool?

    var artifact: Artifact? {
        guard let id, let name, let size, let mime, let sha256 else { return nil }
        return Artifact(id: id, name: name, size: size, mime: mime, sha256: sha256, url: "/api/artifacts/\(id)/content")
    }
    enum CodingKeys: String, CodingKey {
        case role, content, id, name, size, mime, sha256
        case excerptOnly = "excerpt_only"
    }
}

struct ContextPinEnvelope: Codable, Sendable { var pins: [ContextPin] }

struct MessageTaskItem: Identifiable, Codable, Equatable, Sendable {
    var index: Int
    var text: String
    var initialChecked: Bool
    var sourceStartLine: Int?
    var sourceEndLine: Int?
    var id: Int { index }
    enum CodingKeys: String, CodingKey {
        case index, text
        case initialChecked = "initial_checked", sourceStartLine = "source_start_line", sourceEndLine = "source_end_line"
    }
}

struct MessageTaskState: Codable, Equatable, Sendable {
    var tasks: [String: Bool]
    var items: [MessageTaskItem]
    var editable: Bool
    /// Local ownership metadata filled by the caller after decoding the host response.
    var messageID: String?
    var conversationID: String?
    var clientContextID: String?

    func checked(_ item: MessageTaskItem) -> Bool { tasks[String(item.index)] ?? item.initialChecked }
    enum CodingKeys: String, CodingKey {
        case tasks, items, editable
        case messageID = "client_message_id", conversationID = "client_conversation_id"
        case clientContextID = "client_context_id"
    }
}
