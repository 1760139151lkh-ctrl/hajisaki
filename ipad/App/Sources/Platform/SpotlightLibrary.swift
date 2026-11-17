import Foundation
import CoreSpotlight
import CryptoKit
import UniformTypeIdentifiers
import OSLog

/// An on-device search projection. The transcript and original files stay in LocalStore/CAS.
@MainActor
enum SpotlightLibrary {
    private static let writer = SpotlightIndexWriter()

    static func withdrawPrivateConversations(_ conversations: [Conversation], scope: String) {
        for conversation in conversations {
            let snapshot = SpotlightSnapshot(conversation: conversation, messages: [], artifacts: [], scopeDigest: SpotlightIdentity.digest(scope))
            if snapshot.isPrivate { index(conversation: conversation, messages: [], artifacts: [], scope: scope) }
        }
    }

    /// Call with the selected conversation's canonical messages and the current library scope.
    /// Private conversations must also be passed here when their group changes, to withdraw
    /// any earlier public search projection. No original record or file is deleted.
    static func index(conversation: Conversation, messages: [ChatMessage], artifacts: [Artifact], scope: String) {
        guard !scope.isEmpty, scope != "unpaired", SpotlightIdentity.validID(conversation.id) else { return }
        let snapshot = SpotlightSnapshot(conversation: conversation, messages: messages,
                                         artifacts: artifacts, scopeDigest: SpotlightIdentity.digest(scope))
        Task { await writer.enqueue(snapshot) }
    }

    static func conversationID(from activity: NSUserActivity, scope: String) -> String? {
        if activity.activityType == CSSearchableItemActionType,
           let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
           let url = URL(string: identifier) {
            return conversationID(from: url, scope: scope)
        }
        guard let url = activity.webpageURL else { return nil }
        return conversationID(from: url, scope: scope)
    }

    /// The scheme is registered by the app. Scope validation prevents a result from a
    /// previously paired host from being interpreted in a different host's library.
    static func conversationID(from url: URL, scope: String) -> String? {
        guard !scope.isEmpty, scope != "unpaired",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "hajisaki", components.host == "conversation",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil else { return nil }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 2, path[0].isEmpty, SpotlightIdentity.validID(String(path[1])) else { return nil }
        let query = components.queryItems ?? []
        guard query.count <= 2, query.allSatisfy({ $0.name == "scope" || $0.name == "item" }),
              query.filter({ $0.name == "scope" }).count == 1,
              query.filter({ $0.name == "item" }).count <= 1,
              query.first(where: { $0.name == "scope" })?.value == SpotlightIdentity.digest(scope) else { return nil }
        if let item = query.first(where: { $0.name == "item" })?.value, !SpotlightIdentity.validID(item, maxBytes: 160) { return nil }
        return String(path[1])
    }
}

private enum SpotlightIdentity {
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func validID(_ value: String, maxBytes: Int = 128) -> Bool {
        !value.isEmpty && value.utf8.count <= maxBytes && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func link(conversationID: String, scopeDigest: String, item: String) -> String {
        var components = URLComponents()
        components.scheme = "hajisaki"
        components.host = "conversation"
        components.path = "/" + conversationID
        components.queryItems = [URLQueryItem(name: "scope", value: scopeDigest), URLQueryItem(name: "item", value: item)]
        return components.string ?? ""
    }
}

private struct SpotlightSnapshot: Sendable {
    var conversation: Conversation
    var messages: [ChatMessage]
    var artifacts: [Artifact]
    var scopeDigest: String

    var domain: String { "app.hajisaki.theater.library." + scopeDigest + "." + SpotlightIdentity.digest(conversation.id) }
    var isPrivate: Bool {
        let group = conversation.group.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return ["私密", "隐私", "隱私", "保险箱", "保險箱", "private", "vault"].contains { group.contains($0) }
    }
}

private struct SpotlightRecord: Encodable {
    var identifier: String
    var title: String
    var summary: String
    var text: String
    var typeIdentifier: String
    var keywords: [String]

    func searchableItem(domain: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType(typeIdentifier) ?? .data)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = summary
        attributes.textContent = text
        attributes.keywords = keywords
        // contentURL is deliberately unset: it describes a file URL, not an app route.
        let item = CSSearchableItem(uniqueIdentifier: identifier, domainIdentifier: domain, attributeSet: attributes)
        item.expirationDate = .distantFuture
        return item
    }
}

/// All metadata preparation and Core Spotlight submissions happen away from MainActor.
/// Only one replacement is in flight, including across suspension points, so a newer
/// private-group withdrawal cannot be overtaken by an older public submission.
private actor SpotlightIndexWriter {
    private let searchableIndex = CSSearchableIndex(name: "HajiSakiLibrary", protectionClass: .complete)
    private let logger = Logger(subsystem: "app.hajisaki.theater.ipad", category: "Spotlight")
    private var pending: [String: SpotlightSnapshot] = [:]
    private var fingerprints: [String: String] = [:]
    private var scheduled: Task<Void, Never>?
    private var draining = false
    private var retryDelay: UInt64 = 2

    func enqueue(_ snapshot: SpotlightSnapshot) {
        pending[snapshot.domain] = snapshot
        guard !draining else { return }
        schedule(after: snapshot.isPrivate ? 0 : 500_000_000)
    }

    private func schedule(after delay: UInt64) {
        scheduled?.cancel()
        scheduled = Task {
            do { if delay > 0 { try await Task.sleep(nanoseconds: delay) } }
            catch { return }
            guard !Task.isCancelled else { return }
            await drain()
        }
    }

    private func drain() async {
        guard !draining else { return }
        scheduled = nil
        draining = true
        var retry = false
        while let domain = pending.keys.first, let snapshot = pending.removeValue(forKey: domain) {
            let records = makeRecords(snapshot)
            let fingerprint: String
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                fingerprint = SHA256.hash(data: try encoder.encode(records)).map { String(format: "%02x", $0) }.joined()
            } catch {
                logger.error("系统搜索资料暂时无法整理；原始记录保持不变。")
                continue
            }
            if fingerprints[domain] == fingerprint { continue }
            do {
                // Replace only this conversation's derived index. This also withdraws
                // old public items if the conversation has moved into a private group.
                // A superseding snapshot may equal the previously indexed version;
                // once replacement starts that old fingerprint no longer proves the
                // index still contains it, even if submission is interrupted.
                fingerprints[domain] = nil
                try await searchableIndex.deleteSearchableItems(withDomainIdentifiers: [domain])
                if pending[domain] != nil { continue }
                for offset in stride(from: 0, to: records.count, by: 64) {
                    if pending[domain] != nil { break }
                    let batch = records[offset..<min(offset + 64, records.count)].map { $0.searchableItem(domain: domain) }
                    try await searchableIndex.indexSearchableItems(batch)
                }
                if pending[domain] == nil { fingerprints[domain] = fingerprint }
                retryDelay = 2
            } catch {
                if pending[domain] == nil { pending[domain] = snapshot }
                logger.error("系统搜索索引尚未写入，将稍后接续；原始记录保持不变。")
                retry = true
                break
            }
        }
        draining = false
        if !pending.isEmpty {
            let delay = retry ? retryDelay * 1_000_000_000 : 0
            if retry { retryDelay = min(retryDelay * 2, 30) }
            schedule(after: delay)
        }
    }

    private func makeRecords(_ snapshot: SpotlightSnapshot) -> [SpotlightRecord] {
        guard !snapshot.isPrivate else { return [] }
        let conversation = snapshot.conversation
        let messages = snapshot.messages.filter { $0.conversationID == conversation.id }
        let keywords = ["哈基祥", conversation.group]
        let link: (String) -> String = { SpotlightIdentity.link(conversationID: conversation.id, scopeDigest: snapshot.scopeDigest, item: $0) }
        var records = [SpotlightRecord(identifier: link("conversation"), title: conversation.title,
                                       summary: conversation.group, text: conversation.title,
                                       typeIdentifier: UTType.text.identifier, keywords: keywords)]
        var indexedMessages = Set<String>()
        for message in messages where message.role == "assistant" && message.status == "completed" {
            guard SpotlightIdentity.validID(message.id), indexedMessages.insert(message.id).inserted,
                  !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let preview = String(message.content.prefix(360)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            records.append(SpotlightRecord(identifier: link("message-" + message.id), title: conversation.title,
                                            summary: preview, text: message.content,
                                            typeIdentifier: UTType.text.identifier, keywords: keywords))
        }
        let referencedIDs = Set(messages.flatMap(\.artifactIDs))
        var attached: [String: Artifact] = [:]
        for artifact in snapshot.artifacts where referencedIDs.contains(artifact.id) { attached[artifact.id] = artifact }
        for artifact in messages.flatMap(\.attachments).compactMap(\.artifact) { attached[artifact.id] = artifact }
        for artifact in attached.values.sorted(by: { $0.id < $1.id }) {
            guard SpotlightIdentity.validID(artifact.id) else { continue }
            let type = artifact.mime == "application/pdf" ? UTType.pdf : (UTType(mimeType: artifact.mime) ?? .data)
            records.append(SpotlightRecord(identifier: link("file-" + artifact.id), title: artifact.name,
                                            summary: conversation.title, text: artifact.name,
                                            typeIdentifier: type.identifier, keywords: keywords + ["文件"]))
        }
        return records
    }
}
