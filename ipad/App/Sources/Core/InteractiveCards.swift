import Foundation

struct InteractiveCardDefinition: Codable, Equatable, Sendable {
    struct Face: Codable, Equatable, Sendable {
        var front: String
        var back: String
    }
    var version: Int
    var kind: String
    var title: String
    var cards: [Face]
    var question: String
    var options: [String]
}

struct InteractiveCardSnapshot: Codable, Equatable, Sendable {
    var artifactID: String
    var conversationID: String
    var definition: InteractiveCardDefinition
    var selectedOption: Int?
    var counts: [Int]
    var clientContextID: String? = nil
    enum CodingKeys: String, CodingKey {
        case artifactID = "artifact_id", conversationID = "conversation_id"
        case definition, counts
        case selectedOption = "selected_option"
    }
    var key: String { conversationID + "|" + artifactID }
}

struct InteractiveCardReading: Codable, Equatable, Sendable {
    var index = 0
    var revealed: Set<Int> = []
}

extension Artifact {
    var isNativeCard: Bool { name.lowercased().hasSuffix(".hajicard.json") && size <= 128 * 1024 }
}
