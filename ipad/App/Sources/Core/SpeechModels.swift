import Foundation

/// Host ASR results. Scores are provider probabilities, not calibrated accuracy.
/// The original recording and original text remain distinct from an edited draft.
struct SpeechJob: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var status: String
    var artifactID: String
    var originalText: String
    var text: String
    var segments: [SpeechSegment]
    var uncertainSpans: [SpeechUncertainSpan]
    var dictionarySuggestions: [SpeechDictionarySuggestion]
    var originalAudio: SpeechOriginalAudio
    var progress: SpeechProgress
    var detail: String?
    var provider: String?
    var language: String?
    var languageProbability: Double?
    var durationSeconds: Double?
    var createdAt: String?
    var cleanup: SpeechCleanup?
    var capabilities: [String: JSONValue]?
    // Filled by the client and persisted only in this host's local database.
    // Never supplied as a request parameter to the host.
    var clientContextID: String?
    var clientConversationID: String?

    var isTerminal: Bool {
        ["completed", "cancelled", "failed", "interrupted", "unconfigured", "dependency_missing"].contains(status)
    }
    var isCompleted: Bool { status == "completed" }
    enum CodingKeys: String, CodingKey {
        case id, status, text, segments, progress, detail, provider, language, cleanup, capabilities
        case artifactID = "artifact_id", originalText = "original_text", uncertainSpans = "uncertain_spans"
        case dictionarySuggestions = "dictionary_suggestions", originalAudio = "original_audio"
        case languageProbability = "language_probability", durationSeconds = "duration_seconds", createdAt = "created_at"
        case clientContextID = "client_context_id"
        case clientConversationID = "client_conversation_id"
    }
}

struct SpeechOriginalAudio: Codable, Equatable, Sendable {
    var name: String
    var size: Int64
    var sha256: String
    var url: String
}

struct SpeechProgress: Codable, Equatable, Sendable {
    var segments: Int
    var throughSeconds: Double?
    enum CodingKeys: String, CodingKey { case segments; case throughSeconds = "through_seconds" }
}

struct SpeechSegment: Identifiable, Codable, Equatable, Sendable {
    var index: Int
    var start: Double?
    var end: Double?
    var text: String
    var avgLogprob: Double?
    var noSpeechProbability: Double?
    var words: [SpeechWord]
    var id: Int { index }
    enum CodingKeys: String, CodingKey {
        case index, start, end, text, words
        case avgLogprob = "avg_logprob", noSpeechProbability = "no_speech_probability"
    }
}

struct SpeechWord: Codable, Equatable, Sendable {
    var start: Double?
    var end: Double?
    var text: String
    var probability: Double?
}

struct SpeechUncertainSpan: Identifiable, Codable, Equatable, Sendable {
    var segmentIndex: Int
    var startSeconds: Double?
    var endSeconds: Double?
    var text: String
    var probability: Double?
    var charStart: Int?
    var charEnd: Int?
    var offsetBasis: String
    var candidates: [JSONValue]
    var id: String { "\(segmentIndex):\(charStart ?? -1):\(charEnd ?? -1):\(startSeconds ?? -1):\(text)" }
    func utf16Range(in originalText: String) -> NSRange? {
        guard offsetBasis == "original_text_unicode_codepoints", let start = charStart, let end = charEnd else { return nil }
        return SpeechTextOffsets.utf16Range(start: start, end: end, in: originalText)
    }
    enum CodingKeys: String, CodingKey {
        case text, probability, candidates
        case segmentIndex = "segment_index", startSeconds = "start_seconds", endSeconds = "end_seconds"
        case charStart = "char_start", charEnd = "char_end", offsetBasis = "offset_basis"
    }
}

struct SpeechDictionarySuggestion: Identifiable, Codable, Equatable, Sendable {
    var start: Int
    var end: Int
    var text: String
    var replacement: String
    var source: String
    var offsetBasis: String
    var acousticProbability: Double?
    var id: String { "\(start):\(end):\(replacement)" }
    func utf16Range(in originalText: String) -> NSRange? {
        guard offsetBasis == "original_text_unicode_codepoints" else { return nil }
        return SpeechTextOffsets.utf16Range(start: start, end: end, in: originalText)
    }
    enum CodingKeys: String, CodingKey {
        case start, end, text, replacement, source
        case offsetBasis = "offset_basis", acousticProbability = "acoustic_probability"
    }
}

struct SpeechHotword: Identifiable, Codable, Equatable, Sendable {
    var term: String
    var aliases: [String]
    var id: String { term }
    init(term: String, aliases: [String] = []) { self.term = term; self.aliases = aliases }
}

struct SpeechCleanup: Codable, Equatable, Sendable {
    struct Edit: Codable, Equatable, Sendable {
        var start: Int
        var end: Int
        var original: String
        var replacement: String
    }
    var original: String
    var text: String
    var edits: [Edit]
    var method: String
}

struct SpeechHotwordEnvelope: Codable, Sendable { var hotwords: [SpeechHotword] }

enum SpeechTextOffsets {
    /// Python indexes Unicode scalar values; UIKit ranges index UTF-16 units.
    /// Swift's Character count cannot safely convert ASR ranges containing emoji.
    static func utf16Range(start: Int, end: Int, in text: String) -> NSRange? {
        guard start >= 0, end >= start, end <= text.unicodeScalars.count else { return nil }
        var scalarOffset = 0, utf16Offset = 0, lower = 0, upper = 0
        for scalar in text.unicodeScalars {
            if scalarOffset == start { lower = utf16Offset }
            if scalarOffset == end { upper = utf16Offset; break }
            utf16Offset += scalar.value > 0xFFFF ? 2 : 1
            scalarOffset += 1
        }
        if scalarOffset == start { lower = utf16Offset }
        if scalarOffset == end { upper = utf16Offset }
        return NSRange(location: lower, length: upper - lower)
    }
}
