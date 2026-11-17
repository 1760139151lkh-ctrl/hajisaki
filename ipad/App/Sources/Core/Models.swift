import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    var intValue: Int? { if case .number(let v) = self, v.isFinite, v >= Double(Int.min), v < Double(Int.max) { return Int(v) }; return nil }
}

struct Conversation: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var group: String
    var pinned: Bool
    var archived: Bool
    var updatedAt: String
    var preview: String?
    enum CodingKeys: String, CodingKey { case id, title, group, pinned, archived, preview; case updatedAt = "updated_at" }
}

struct Artifact: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var size: Int64
    var mime: String
    var sha256: String
    var url: String
}

enum ArtifactReference: Codable, Equatable, Sendable {
    case id(String), artifact(Artifact)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(String.self) { self = .id(value) }
        else { self = .artifact(try c.decode(Artifact.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .id(let v): try c.encode(v); case .artifact(let v): try c.encode(v) }
    }
    var id: String { switch self { case .id(let v): return v; case .artifact(let v): return v.id } }
    var artifact: Artifact? { if case .artifact(let v) = self { return v }; return nil }
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var conversationID: String
    var role: String
    var content: String
    var status: String
    var createdAt: String
    var attachments: [ArtifactReference]
    var isUser: Bool { role == "user" }
    var artifactIDs: [String] { attachments.map(\.id) }
    enum CodingKeys: String, CodingKey {
        case id, role, content, status, attachments
        case conversationID = "conversation_id", createdAt = "created_at"
    }
}

struct GatewayModel: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var efforts: [String]
}

struct MemoryEntry: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var content: String
    var createdAt: String
    var updatedAt: String
    enum CodingKeys: String, CodingKey { case id, content; case createdAt = "created_at", updatedAt = "updated_at" }
}

struct StreamEvent: Identifiable, Codable, Equatable, Sendable {
    var seq: Int64
    var conversationID: String
    var runID: String
    var layer: String
    var kind: String
    var payload: [String: JSONValue]
    var createdAt: String
    var id: Int64 { seq }
    var text: String { payload["text"]?.stringValue ?? payload["message"]?.stringValue ?? payload["name"]?.stringValue ?? "" }
    var messageID: String? { payload["message_id"]?.stringValue }
    enum CodingKeys: String, CodingKey {
        case seq, layer, kind, payload
        case conversationID = "conversation_id", runID = "run_id", createdAt = "created_at"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int64.self, forKey: .seq)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        runID = try c.decodeIfPresent(String.self, forKey: .runID) ?? ""
        layer = try c.decode(String.self, forKey: .layer)
        kind = try c.decode(String.self, forKey: .kind)
        payload = try c.decode([String: JSONValue].self, forKey: .payload)
        createdAt = try c.decode(String.self, forKey: .createdAt)
    }
}

struct Personality: Codable, Equatable, Sendable {
    var formality: Int = 65
    var detail: Int = 50
    var teasing: Int = 25
}

struct TheaterSettings: Codable, Equatable, Sendable {
    var theme: String = "auto"
    var transparency: String = "balanced"
    var personality: Personality = Personality()
    var sound: Bool = false
}

enum ConnectionState: String, Codable, Sendable { case offline, connecting, connected, failed }

struct ActiveRun: Codable, Equatable, Sendable {
    var id: String
    var status: String
    var assistantMessageID: String
    enum CodingKeys: String, CodingKey { case id, status; case assistantMessageID = "assistant_message_id" }
}

struct MessageSnapshot: Codable, Sendable {
    var messages: [ChatMessage]
    var activeRun: ActiveRun?
    var cursor: Int64
    enum CodingKeys: String, CodingKey { case messages, cursor; case activeRun = "active_run" }
}

struct OutboxEntry: Codable, Identifiable, Sendable {
    var clientID: String
    var conversationID: String
    var content: String
    var model: String
    var effort: String
    var attachments: [String]
    var createdAt: String
    var id: String { clientID }
    var optimisticMessage: ChatMessage {
        ChatMessage(id: "pending-" + clientID, conversationID: conversationID, role: "user", content: content,
                    status: "pending", createdAt: createdAt, attachments: attachments.map(ArtifactReference.id))
    }
}

struct GatewayCredentials: Codable, Sendable {
    var address: String
    var deviceID: String
    var token: String
}

struct HostStatus: Decodable, Sendable {
    struct Provider: Decodable, Sendable {
        var name: String
        var available: Bool
        var authenticated: Bool?
        var simulated: Bool?
        var detail: String?
    }
    var provider: Provider
    var capabilities: [String: JSONValue]
}

struct ConversationEnvelope: Decodable { var conversations: [Conversation] }
struct ModelEnvelope: Decodable { var models: [GatewayModel] }
struct MemoryEnvelope: Decodable { var memories: [MemoryEntry] }
struct ArtifactEnvelope: Decodable { var artifacts: [Artifact] }
struct EventEnvelope: Decodable {
    var events: [StreamEvent]
    var cursor: Int64
    var hasMore: Bool
    enum CodingKeys: String, CodingKey { case events, cursor; case hasMore = "has_more" }
}
struct SendReceipt: Decodable {
    var message: ChatMessage
    var runID: String
    var assistantMessageID: String?
    enum CodingKeys: String, CodingKey { case message; case runID = "run_id", assistantMessageID = "assistant_message_id" }
}

enum TheaterError: LocalizedError {
    case address, pairing, server(Int, String?), invalidResponse, storage, integrity, disconnected
    var errorDescription: String? {
        switch self {
        case .address: return "请填写琴房的 HTTPS 地址，或加密内网中的主机地址。"
        case .pairing: return "还没有认出这台设备，请检查配对信息。"
        case .server(let code, let detail):
            if let detail, detail.count < 300, detail.range(of: #"[\u4e00-\u9fff]"#, options: .regularExpression) != nil,
               !detail.contains(":\\"), !detail.contains("Traceback") { return detail }
            return code == 409 ? "这一段还在写，请等她写完或先停下。" : "这一页暂时没有接好，已写下的内容还在。"
        case .invalidResponse: return "主机送来的这一页不完整，请稍后重新接续。"
        case .storage: return "这一页暂时没能保存到本机，请检查剩余空间后重试。"
        case .integrity: return "文件指纹没有对上，请重新传送原件。"
        case .disconnected: return "琴房暂时没有接通，草稿会留在这里。"
        }
    }
}
