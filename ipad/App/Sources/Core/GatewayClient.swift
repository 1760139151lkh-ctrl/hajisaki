import Foundation
import CryptoKit
import Security
import UniformTypeIdentifiers
import OSLog

enum CredentialVault {
    private static let service = "app.hajisaki.theater.gateway"
    private static let logger = Logger(subsystem: "app.hajisaki.theater.ipad", category: "CredentialVault")
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "paired-host"]
    }
    static func load() throws -> GatewayCredentials? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            logger.error("Keychain read failed; OSStatus=\(status, privacy: .public)")
            throw TheaterError.pairing
        }
        return try JSONDecoder().decode(GatewayCredentials.self, from: data)
    }
    static func save(_ value: GatewayCredentials) throws {
        let data = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else {
                logger.error("Keychain add failed; OSStatus=\(added, privacy: .public)")
                throw TheaterError.pairing
            }
        } else if status != errSecSuccess {
            logger.error("Keychain update failed; OSStatus=\(status, privacy: .public)")
            throw TheaterError.pairing
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Credentials never follow a gateway redirect to a different origin.
        completionHandler(nil)
    }
}

actor GatewayClient {
    private let credentials: GatewayCredentials
    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(credentials: GatewayCredentials) throws {
        guard let url = URL(string: credentials.address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, components.path.isEmpty || components.path == "/",
              components.scheme == "https" || (components.scheme == "http" && Self.isPrivateHost(host)) else {
            throw TheaterError.address
        }
        guard !credentials.token.isEmpty, !credentials.deviceID.isEmpty,
              credentials.token.rangeOfCharacter(from: .controlCharacters) == nil,
              credentials.deviceID.rangeOfCharacter(from: .controlCharacters) == nil else { throw TheaterError.pairing }
        self.credentials = credentials
        self.baseURL = url
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    private static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        let parts = labels.compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ 0...255 ~= $0 }) else { return false }
        guard zip(labels, parts).allSatisfy({ String($0.1) == String($0.0) }) else { return false }
        return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && 16...31 ~= parts[1]) || (parts[0] == 100 && 64...127 ~= parts[1])
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         query: [URLQueryItem] = [], contentType: String = "application/json") throws -> URLRequest {
        guard path.hasPrefix("/api/"), !path.contains(".."), !path.contains("?") else { throw TheaterError.address }
        guard var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw TheaterError.address }
        c.path = path
        c.queryItems = query.isEmpty ? nil : query
        guard let url = c.url else { throw TheaterError.address }
        var result = URLRequest(url: url)
        result.setValue("artifact-links-v1,native-cards-v1", forHTTPHeaderField: "X-Haji-Features")
        result.setValue("ipados", forHTTPHeaderField: "X-Haji-Platform")
        result.httpMethod = method
        result.httpBody = body
        result.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
        result.setValue(credentials.deviceID, forHTTPHeaderField: "X-Haji-Device")
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { result.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return result
    }

    private func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw TheaterError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 401 || http.statusCode == 403 { throw TheaterError.pairing }
            var detail: String?
            if let data, let value = try? decoder.decode([String: JSONValue].self, from: data) { detail = value["detail"]?.stringValue }
            throw TheaterError.server(http.statusCode, detail)
        }
    }

    func value<T: Decodable>(_ type: T.Type, path: String, method: String = "GET",
                             body: [String: JSONValue]? = nil, query: [URLQueryItem] = []) async throws -> T {
        let req = try request(path, method: method, body: body.map { try encoder.encode($0) }, query: query)
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data)
        do { return try decoder.decode(type, from: data) }
        catch { throw TheaterError.invalidResponse }
    }

    func status() async throws -> HostStatus { try await value(HostStatus.self, path: "/api/status") }
    func models() async throws -> [GatewayModel] { try await value(ModelEnvelope.self, path: "/api/models").models }
    func conversations(query: String = "", group: String = "") async throws -> [Conversation] {
        try await value(ConversationEnvelope.self, path: "/api/conversations", query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "group", value: group)]).conversations
    }
    func snapshot(_ conversationID: String) async throws -> MessageSnapshot {
        try await value(MessageSnapshot.self, path: "/api/conversations/\(conversationID)/messages")
    }
    func events(_ conversationID: String, after cursor: Int64) async throws -> EventEnvelope {
        try await value(EventEnvelope.self, path: "/api/conversations/\(conversationID)/events",
                        query: [URLQueryItem(name: "after", value: String(cursor))])
    }
    func send(_ entry: OutboxEntry) async throws -> SendReceipt {
        try await value(SendReceipt.self, path: "/api/conversations/\(entry.conversationID)/messages", method: "POST", body: [
            "content": .string(entry.content), "client_id": .string(entry.clientID), "model": .string(entry.model),
            "effort": .string(entry.effort), "attachments": .array(entry.attachments.map(JSONValue.string))
        ])
    }

    func stream(_ conversationID: String, after cursor: Int64,
                onReady: @escaping @Sendable () async -> Void = {}) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try self.request("/api/conversations/\(conversationID)/stream",
                                               query: [URLQueryItem(name: "after", value: String(cursor))])
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.setValue(String(cursor), forHTTPHeaderField: "Last-Event-ID")
                    req.timeoutInterval = 70
                    let (bytes, response) = try await self.session.bytes(for: req)
                    try self.validate(response)
                    guard response.mimeType?.lowercased() == "text/event-stream" else { throw TheaterError.invalidResponse }
                    await onReady()
                    // SSE uses empty physical lines as message boundaries. Read
                    // the bytes directly so Foundation's text-line adaptation
                    // cannot normalize away a protocol delimiter.
                    var framing = GatewayEventFraming()
                    var announcedFirstEvent = false
                    for try await byte in bytes {
                        if let payload = try framing.append(byte) {
                            try Task.checkCancellation()
                            let event = try self.decoder.decode(StreamEvent.self, from: payload)
                            if !announcedFirstEvent {
                                Logger(subsystem: "app.hajisaki.theater.ipad", category: "GatewayStream")
                                    .info("First framed event seq=\(event.seq, privacy: .public)")
                                announcedFirstEvent = true
                            }
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func upload(fileURL: URL, progress: @escaping @Sendable (Double) async -> Void) async throws -> Artifact {
        let secured = fileURL.startAccessingSecurityScopedResource()
        defer { if secured { fileURL.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else { throw TheaterError.invalidResponse }
        let digest = try await Self.backgroundDigest(fileURL)
        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        struct UploadState: Decodable { var id: String?; var offset: Int64; var complete: Bool?; var artifact: Artifact? }
        let begin = try await value(UploadState.self, path: "/api/uploads", method: "POST", body: [
            "name": .string(fileURL.lastPathComponent), "size": .number(Double(size)),
            "sha256": .string(digest), "mime": .string(mime)
        ])
        if let artifact = begin.artifact { await progress(1); return artifact }
        guard let ident = begin.id, begin.offset >= 0, begin.offset <= size else { throw TheaterError.invalidResponse }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var offset = begin.offset
        try handle.seek(toOffset: UInt64(offset))
        while offset < size {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { throw TheaterError.invalidResponse }
            let req = try request("/api/uploads/\(ident)", method: "PUT", body: chunk,
                                  query: [URLQueryItem(name: "offset", value: String(offset))], contentType: "application/octet-stream")
            let (data, response) = try await session.data(for: req)
            try validate(response, data: data)
            struct Offset: Decodable { var offset: Int64 }
            let next = try decoder.decode(Offset.self, from: data).offset
            guard next == offset + Int64(chunk.count) else { throw TheaterError.integrity }
            offset = next
            await progress(size > 0 ? Double(offset) / Double(size) : 1)
        }
        let artifact = try await value(Artifact.self, path: "/api/uploads/\(ident)/complete", method: "POST")
        guard artifact.sha256 == digest, artifact.size == size else { throw TheaterError.integrity }
        return artifact
    }

    func download(_ artifact: Artifact, to directory: URL) async throws -> URL {
        let destination = directory.appendingPathComponent(artifact.id + "-" + Self.safeName(artifact.name))
        if FileManager.default.fileExists(atPath: destination.path), try await Self.backgroundDigest(destination) == artifact.sha256 { return destination }
        let (temporary, response) = try await session.download(for: request("/api/artifacts/\(artifact.id)/content"))
        try validate(response)
        guard try await Self.backgroundDigest(temporary) == artifact.sha256 else { throw TheaterError.integrity }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Never overwrite a different local original or permanently remove it.
        let output = FileManager.default.fileExists(atPath: destination.path)
            ? directory.appendingPathComponent(UUID().uuidString + "-" + Self.safeName(artifact.name)) : destination
        try FileManager.default.moveItem(at: temporary, to: output)
        return output
    }

    func exportLibrary(to directory: URL) async throws -> URL {
        let (temporary, response) = try await session.download(for: request("/api/export"))
        try validate(response)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("琴房档案-" + String(UUID().uuidString.prefix(8)) + ".zip")
        try FileManager.default.moveItem(at: temporary, to: output)
        return output
    }

    static func safeName(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "/", with: "_")
            .components(separatedBy: .controlCharacters).joined()
        return String(cleaned.prefix(160)).isEmpty ? "未命名文件" : String(cleaned.prefix(160))
    }
    private static func digest(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func backgroundDigest(_ url: URL) async throws -> String {
        let work = Task.detached(priority: .utility) { try Self.digest(url) }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
}

/// Bounded SSE framing, independent of network packet boundaries. CR, LF and
/// CRLF are accepted; an unfinished final event is replayed after reconnect.
private struct GatewayEventFraming {
    private var line = Data()
    private var eventName = ""
    private var payload = Data()
    private var hasData = false
    private var previousWasCR = false
    private var isFirstLine = true
    private let maximum = 4 * 1024 * 1024

    mutating func append(_ byte: UInt8) throws -> Data? {
        if byte == 10 {
            if previousWasCR { previousWasCR = false; return nil }
            return try finishLine()
        }
        if byte == 13 {
            previousWasCR = true
            return try finishLine()
        }
        previousWasCR = false
        guard line.count < maximum else { throw TheaterError.invalidResponse }
        line.append(byte)
        return nil
    }

    private mutating func finishLine() throws -> Data? {
        try Task.checkCancellation()
        guard var text = String(data: line, encoding: .utf8) else { throw TheaterError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if text.first == "\u{FEFF}" { text.removeFirst() }
        }
        if text.isEmpty {
            let result = eventName == "haji" && hasData ? payload : nil
            eventName = ""; payload = Data(); hasData = false
            return result
        }
        if text.hasPrefix(":") { return nil }
        let separator = text.firstIndex(of: ":")
        let field = separator.map { String(text[..<$0]) } ?? text
        var value = separator.map { String(text[text.index(after: $0)...]) } ?? ""
        if value.first == " " { value.removeFirst() }
        if field == "event" { eventName = value }
        if field == "data" {
            let data = Data(value.utf8)
            guard payload.count + data.count + (hasData ? 1 : 0) <= maximum else { throw TheaterError.invalidResponse }
            if hasData { payload.append(10) }
            payload.append(data); hasData = true
        }
        return nil
    }
}
