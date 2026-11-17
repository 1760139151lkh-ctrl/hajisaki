import Foundation
import SQLite3

/// One serial owner for the offline library. A snapshot and its replay cursor
/// are committed together, so a restart can neither skip nor append twice.
actor LocalStore {
    private let database: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw LocalStoreError.storageUnavailable
        }
        database = try SQLiteDatabase(url: url)
        try database.executeScript("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=FULL;
            PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                group_name TEXT NOT NULL,
                pinned INTEGER NOT NULL,
                archived INTEGER NOT NULL,
                updated_at TEXT NOT NULL,
                payload TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS snapshots (
                conversation_id TEXT PRIMARY KEY NOT NULL,
                cursor INTEGER NOT NULL,
                payload TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL,
                content TEXT NOT NULL,
                active INTEGER NOT NULL DEFAULT 1,
                payload TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS messages_conversation ON messages(conversation_id, active);
            CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(content, content='messages', content_rowid='rowid');
            CREATE TRIGGER IF NOT EXISTS messages_search_insert AFTER INSERT ON messages BEGIN
                INSERT INTO message_search(rowid, content) VALUES(new.rowid, new.content);
            END;
            CREATE TRIGGER IF NOT EXISTS messages_search_update AFTER UPDATE OF content ON messages
            WHEN old.content IS NOT new.content BEGIN
                INSERT INTO message_search(message_search, rowid, content) VALUES('delete', old.rowid, old.content);
                INSERT INTO message_search(rowid, content) VALUES(new.rowid, new.content);
            END;
            CREATE TABLE IF NOT EXISTS events (
                conversation_id TEXT NOT NULL,
                seq INTEGER NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY(conversation_id, seq)
            );
            CREATE TABLE IF NOT EXISTS drafts (
                conversation_id TEXT PRIMARY KEY NOT NULL,
                content TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS outbox (
                client_id TEXT PRIMARY KEY NOT NULL,
                created_at TEXT NOT NULL,
                delivered INTEGER NOT NULL DEFAULT 0,
                payload TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS objects (
                key TEXT PRIMARY KEY NOT NULL,
                payload TEXT NOT NULL
            );
            PRAGMA user_version=1;
            """)
    }

    func loadConversations(query: String = "", group: String = "") throws -> [Conversation] {
        var sql = "SELECT c.payload FROM conversations c WHERE c.archived=0"
        var parameters: [SQLParameter] = []
        if !group.isEmpty && group != "全部" {
            sql += " AND c.group_name=?"
            parameters.append(.text(group))
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            // LIKE also finds CJK substrings inside a unicode61 token.
            let pattern = "%" + term.replacingOccurrences(of: "!", with: "!!")
                .replacingOccurrences(of: "%", with: "!%")
                .replacingOccurrences(of: "_", with: "!_") + "%"
            let phrase = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            sql += """
                 AND (c.title LIKE ? ESCAPE '!' OR EXISTS(
                    SELECT 1 FROM messages m WHERE m.conversation_id=c.id AND m.active=1
                    AND (m.content LIKE ? ESCAPE '!' OR m.rowid IN (
                        SELECT rowid FROM message_search WHERE message_search MATCH ?
                    ))
                ))
                """
            parameters += [.text(pattern), .text(pattern), .text(phrase)]
        }
        sql += " ORDER BY c.pinned DESC, c.updated_at DESC, c.id"
        return try database.query(sql, parameters).map { try decode(Conversation.self, from: $0[0]) }
    }

    func saveConversations(_ values: [Conversation]) throws {
        try database.transaction {
            for value in values { try upsertConversation(value) }
        }
    }

    /// Only call with a successful, complete, unfiltered server conversation list.
    /// Absent conversations are hidden locally; their messages and drafts remain.
    func reconcileConversations(_ values: [Conversation]) throws {
        try database.transaction {
            let incomingIDs = Set(values.map(\.id))
            let cached = try database.query("SELECT payload FROM conversations WHERE archived=0")
                .map { try decode(Conversation.self, from: $0[0]) }
            for var value in cached where !incomingIDs.contains(value.id) {
                value.archived = true
                try upsertConversation(value)
            }
            for value in values { try upsertConversation(value) }
        }
    }

    func loadSnapshot(conversationID: String) throws -> MessageSnapshot? {
        guard let row = try database.query("SELECT payload FROM snapshots WHERE conversation_id=?", [.text(conversationID)]).first else {
            return nil
        }
        return try decode(MessageSnapshot.self, from: row[0])
    }

    func saveSnapshot(conversationID: String, snapshot: MessageSnapshot, events: [StreamEvent] = []) throws {
        guard snapshot.cursor >= 0,
              snapshot.messages.allSatisfy({ $0.conversationID == conversationID }),
              events.allSatisfy({ $0.conversationID == conversationID && $0.seq <= snapshot.cursor }) else {
            throw LocalStoreError.inconsistentSnapshot
        }
        try database.transaction {
            let previous = try database.query("SELECT cursor FROM snapshots WHERE conversation_id=?", [.text(conversationID)]).first
            if let previous, let text = previous[0], let oldCursor = Int64(text), oldCursor > snapshot.cursor {
                throw LocalStoreError.staleSnapshot
            }
            try database.execute("""
                INSERT INTO snapshots(conversation_id,cursor,payload) VALUES(?,?,?)
                ON CONFLICT(conversation_id) DO UPDATE SET cursor=excluded.cursor,payload=excluded.payload
                """, [.text(conversationID), .integer(snapshot.cursor), .text(try encode(snapshot))])
            var existing: [String: (payload: String, active: Bool)] = [:]
            for row in try database.query("SELECT id,payload,active FROM messages WHERE conversation_id=?", [.text(conversationID)]) {
                guard let id = row[0], let payload = row[1] else { throw LocalStoreError.unreadableRecord }
                existing[id] = (payload, row[2] == "1")
            }
            let currentIDs = Set(snapshot.messages.map(\.id))
            // Preserve superseded rows, while avoiding writes and FTS rebuilds for
            // hundreds of unchanged messages on every incoming reply fragment.
            for (id, record) in existing where record.active && !currentIDs.contains(id) {
                try database.execute("UPDATE messages SET active=0 WHERE id=?", [.text(id)])
            }
            for value in snapshot.messages {
                let payload = try encode(value)
                if let record = existing[value.id], record.active && record.payload == payload { continue }
                try database.execute("""
                    INSERT INTO messages(id,conversation_id,content,active,payload) VALUES(?,?,?,1,?)
                    ON CONFLICT(id) DO UPDATE SET conversation_id=excluded.conversation_id,
                    content=excluded.content,active=1,payload=excluded.payload
                    """, [.text(value.id), .text(conversationID), .text(value.content), .text(payload)])
            }
            for event in events {
                try database.execute("""
                    INSERT INTO events(conversation_id,seq,payload) VALUES(?,?,?)
                    ON CONFLICT(conversation_id,seq) DO NOTHING
                    """, [.text(conversationID), .integer(event.seq), .text(try encode(event))])
            }
        }
    }

    func loadEvents(conversationID: String) throws -> [StreamEvent] {
        try database.query("SELECT payload FROM events WHERE conversation_id=? ORDER BY seq", [.text(conversationID)])
            .map { try decode(StreamEvent.self, from: $0[0]) }
    }

    func draft(conversationID: String) throws -> String {
        try database.query("SELECT content FROM drafts WHERE conversation_id=?", [.text(conversationID)]).first?[0] ?? ""
    }

    func saveDraft(conversationID: String, text: String) throws {
        try database.execute("""
            INSERT INTO drafts(conversation_id,content) VALUES(?,?)
            ON CONFLICT(conversation_id) DO UPDATE SET content=excluded.content
            """, [.text(conversationID), .text(text)])
    }

    func moveDraft(from source: String, to target: String, text: String, attachments: [Artifact]) throws {
        try database.transaction {
            try saveDraft(conversationID: target, text: text)
            try saveObject(key: "attachments-" + target, value: attachments)
            try saveDraft(conversationID: source, text: "")
            try saveObject(key: "attachments-" + source, value: [Artifact]())
        }
    }

    func upsertMemory(_ memory: MemoryEntry) throws -> [MemoryEntry] {
        var values = try loadObject(key: "memories", as: [MemoryEntry].self) ?? []
        if let index = values.firstIndex(where: { $0.id == memory.id }) { values[index] = memory }
        else { values.insert(memory, at: 0) }
        try saveObject(key: "memories", value: values)
        return values
    }

    func forgetMemory(id: String) throws -> [MemoryEntry] {
        var values = try loadObject(key: "memories", as: [MemoryEntry].self) ?? []
        values.removeAll { $0.id == id }
        try saveObject(key: "memories", value: values)
        return values
    }

    func rememberArtifact(_ artifact: Artifact) throws -> [Artifact] {
        var values = try loadObject(key: "artifacts", as: [Artifact].self) ?? []
        if !values.contains(where: { $0.id == artifact.id }) { values.insert(artifact, at: 0) }
        try saveObject(key: "artifacts", value: values)
        return values
    }

    func saveSpeechJob(_ job: SpeechJob) throws -> SpeechJob {
        try database.transaction {
            let key = "speech-job-" + job.id
            var merged = job
            if let existing = try loadObject(key: key, as: SpeechJob.self) {
                if existing.isTerminal && !job.isTerminal {
                    merged.status = existing.status
                    merged.detail = existing.detail
                }
                if existing.progress.segments > job.progress.segments {
                    // A late stop/poll response may contain fewer flushed segments.
                    // Keep the terminal state while retaining all previously read audio text.
                    merged.originalText = existing.originalText
                    merged.text = existing.text
                    merged.segments = existing.segments
                    merged.uncertainSpans = existing.uncertainSpans
                    merged.dictionarySuggestions = existing.dictionarySuggestions
                    merged.progress = existing.progress
                    merged.cleanup = existing.cleanup
                }
            }
            try saveObject(key: key, value: merged)
            var ids = try loadObject(key: "speech-job-index", as: [String].self) ?? []
            if !ids.contains(job.id) { ids.insert(job.id, at: 0) }
            try saveObject(key: "speech-job-index", value: ids)
            return merged
        }
    }

    func loadSpeechJobs() throws -> [SpeechJob] {
        let ids = try loadObject(key: "speech-job-index", as: [String].self) ?? []
        return try ids.compactMap { try loadObject(key: "speech-job-" + $0, as: SpeechJob.self) }
    }

    func appendDraft(conversationID: String, text: String) throws {
        let original = try draft(conversationID: conversationID)
        try saveDraft(conversationID: conversationID, text: original + (original.isEmpty ? "" : "\n\n") + text)
    }

    func loadOutbox() throws -> [OutboxEntry] {
        try database.query("SELECT payload FROM outbox WHERE delivered=0 ORDER BY created_at,client_id")
            .map { try decode(OutboxEntry.self, from: $0[0]) }
    }

    func enqueue(_ entry: OutboxEntry) throws {
        let payload = try encode(entry)
        try database.transaction {
            if let existing = try database.query("SELECT payload FROM outbox WHERE client_id=?", [.text(entry.clientID)]).first {
                let original = try decode(OutboxEntry.self, from: existing[0])
                // A client ID must always identify the same message, including after delivery.
                guard original.conversationID == entry.conversationID,
                      original.content == entry.content,
                      original.model == entry.model,
                      original.effort == entry.effort,
                      original.attachments == entry.attachments else {
                    throw LocalStoreError.reusedClientID
                }
                return
            }
            try database.execute("INSERT INTO outbox(client_id,created_at,delivered,payload) VALUES(?,?,0,?)",
                                 [.text(entry.clientID), .text(entry.createdAt), .text(payload)])
        }
    }

    func markDelivered(clientID: String) throws {
        try database.execute("UPDATE outbox SET delivered=1 WHERE client_id=?", [.text(clientID)])
    }

    func saveObject<T: Encodable>(key: String, value: T) throws {
        try database.execute("""
            INSERT INTO objects(key,payload) VALUES(?,?)
            ON CONFLICT(key) DO UPDATE SET payload=excluded.payload
            """, [.text(key), .text(try encode(value))])
    }

    func loadObject<T: Decodable>(key: String, as type: T.Type) throws -> T? {
        guard let row = try database.query("SELECT payload FROM objects WHERE key=?", [.text(key)]).first else { return nil }
        return try decode(type, from: row[0])
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        do {
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        } catch {
            throw LocalStoreError.encodingFailed
        }
    }

    private func upsertConversation(_ value: Conversation) throws {
        try database.execute("""
            INSERT INTO conversations(id,title,group_name,pinned,archived,updated_at,payload)
            VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            title=excluded.title,group_name=excluded.group_name,pinned=excluded.pinned,
            archived=excluded.archived,updated_at=excluded.updated_at,payload=excluded.payload
            """, [.text(value.id), .text(value.title), .text(value.group),
                   .integer(value.pinned ? 1 : 0), .integer(value.archived ? 1 : 0),
                   .text(value.updatedAt), .text(try encode(value))])
    }

    private func decode<T: Decodable>(_ type: T.Type, from string: String?) throws -> T {
        guard let string else { throw LocalStoreError.unreadableRecord }
        do {
            return try decoder.decode(type, from: Data(string.utf8))
        } catch {
            throw LocalStoreError.unreadableRecord
        }
    }
}

enum LocalStoreError: LocalizedError {
    case storageUnavailable
    case database(Int32)
    case encodingFailed
    case unreadableRecord
    case inconsistentSnapshot
    case staleSnapshot
    case reusedClientID

    var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "本地琴房暂时无法打开，请检查设备剩余空间。"
        case .database: return "这一页还没有保存妥当，请保留当前内容后重试。"
        case .encodingFailed: return "这一页暂时无法整理成记录，原稿仍留在这里。"
        case .unreadableRecord: return "有一份本地记录暂时读不出来，请重新连接主机接续。"
        case .inconsistentSnapshot: return "这份记录的页码没有对齐，请重新打开对话。"
        case .staleSnapshot: return "这一页已有更新，请重新打开对话接续。"
        case .reusedClientID: return "这封信的编号已经使用过，请重新发送。"
        }
    }
}

private enum SQLParameter {
    case text(String)
    case integer(Int64)
}

/// Access is confined to LocalStore. FULLMUTEX also protects SQLite finalization.
private final class SQLiteDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let connection else {
            if let connection { sqlite3_close_v2(connection) }
            throw LocalStoreError.database(result)
        }
        handle = connection
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close_v2(handle) }

    func executeScript(_ sql: String) throws {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw LocalStoreError.database(result) }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try executeScript("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try executeScript("COMMIT")
            return value
        } catch {
            // ROLLBACK is best-effort only after an earlier failure; never replace its cause.
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    func execute(_ sql: String, _ parameters: [SQLParameter] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw LocalStoreError.database(result) }
    }

    func query(_ sql: String, _ parameters: [SQLParameter] = []) throws -> [[String?]] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw LocalStoreError.database(result) }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                      let bytes = sqlite3_column_text(statement, column) else { return nil }
                let count = Int(sqlite3_column_bytes(statement, column))
                return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
            })
        }
    }

    private func prepare(_ sql: String, _ parameters: [SQLParameter]) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard result == SQLITE_OK, let prepared else {
            if let prepared { sqlite3_finalize(prepared) }
            throw LocalStoreError.database(result)
        }
        do {
            guard sqlite3_bind_parameter_count(prepared) == Int32(parameters.count) else {
                throw LocalStoreError.database(SQLITE_MISUSE)
            }
            for (index, parameter) in parameters.enumerated() {
                let code: Int32
                switch parameter {
                case .text(let value):
                    code = value.withCString { pointer in
                        sqlite3_bind_text(prepared, Int32(index + 1), pointer, Int32(value.utf8.count), transient)
                    }
                case .integer(let value):
                    code = sqlite3_bind_int64(prepared, Int32(index + 1), value)
                }
                guard code == SQLITE_OK else { throw LocalStoreError.database(code) }
            }
            return prepared
        } catch {
            sqlite3_finalize(prepared)
            throw error
        }
    }
}
