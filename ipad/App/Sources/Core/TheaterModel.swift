import Foundation
import Combine
import CryptoKit
import OSLog

@MainActor
final class TheaterModel: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: String?
    @Published var messages: [ChatMessage] = []
    @Published var events: [StreamEvent] = []
    @Published var models: [GatewayModel] = []
    @Published var memories: [MemoryEntry] = []
    @Published var artifacts: [Artifact] = []
    @Published var settings = TheaterSettings() {
        didSet { UserDefaults.standard.set(settings.theme, forKey: "hajisaki.lastTheme") }
    }
    @Published var connection: ConnectionState = .offline
    @Published var notice: String? { didSet { noticeRevision += 1 } }
    @Published var activeRunID: String?
    @Published var isBusy = false
    @Published var pendingCount = 0
    @Published var transferProgress: Double?
    @Published var pendingAttachments: [Artifact] = []
    @Published var draft = "" {
        didSet {
            if !restoringDraft { draftEditRevision += 1 }
            scheduleDraftSave()
        }
    }
    @Published var searchText = ""
    @Published var selectedGroup = ""
    @Published var selectedModelID = "default" {
        didSet {
            if !availableEfforts.contains(selectedEffort) { selectedEffort = availableEfforts.first ?? "medium" }
        }
    }
    @Published var selectedEffort = "medium"
    @Published var hostAddress = "https://"
    @Published var deviceID = ""
    @Published var capabilities: [String: JSONValue] = [:]
    @Published var providerAuthenticated: Bool?
    @Published var providerSimulated = false
    @Published private(set) var providerName = ""
    @Published private(set) var isReadyForNavigation = false
    @Published private(set) var contextPins: [ContextPin] = []
    @Published private(set) var messageTasks: [String: MessageTaskState] = [:]
    @Published private(set) var pinMutationPending = false
    @Published private(set) var updatingTaskIDs: Set<String> = []
    @Published private(set) var interactiveCards: [String: InteractiveCardSnapshot] = [:]
    @Published private(set) var interactiveCardReading: [String: InteractiveCardReading] = [:]
    @Published private(set) var updatingCardIDs: Set<String> = []
    /// When you last looked at each letter on this iPad; a reply that arrived later shows a rose dot.
    @Published private(set) var seenLetters: [String: Date] = [:]
    /// The reply that was just finished, for a small sealed moment under her name.
    @Published private(set) var justSealedMessageID: String?
    /// When the reply on its way was first seen here, for "想得有点久".
    @Published private(set) var replyStartedAt: Date?
    /// A short line from her after something was kept (a memory, a pinned passage); shown briefly, then gone.
    @Published private(set) var keepsakeLine: String?
    /// Her lines you put a heart on, kept on this iPad, gathered in the memory panel.
    struct HeartedLine: Codable, Equatable, Sendable {
        var conversationID: String
        var title: String
        var excerpt: String
        var at: Date
    }
    @Published private(set) var heartedLines: [String: HeartedLine] = {
        guard let data = UserDefaults.standard.data(forKey: "hajisaki.heartedLines"),
              let saved = try? JSONDecoder().decode([String: HeartedLine].self, from: data) else { return [:] }
        return saved
    }()
    var heartedMessages: Set<String> { Set(heartedLines.keys) }
    func toggleHeart(_ message: ChatMessage) {
        if heartedLines[message.id] != nil { heartedLines[message.id] = nil }
        else {
            let plain = message.content.replacingOccurrences(of: #"[*_`#>|~\[\]]"#, with: "", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            heartedLines[message.id] = HeartedLine(conversationID: message.conversationID,
                                                   title: selectedConversation?.title ?? "", excerpt: String(plain.prefix(90)), at: Date())
            say(CompanionMood.heartLine(settings))
        }
        if let data = try? JSONEncoder().encode(heartedLines) { UserDefaults.standard.set(data, forKey: "hajisaki.heartedLines") }
    }
    /// The sticker she holds up with that line, if any (an asset name such as "sticker_praise").
    @Published private(set) var keepsakeSticker: String?
    private var keepsakeTask: Task<Void, Never>?
    func say(_ line: String, sticker: String? = nil) {
        keepsakeLine = line
        keepsakeSticker = sticker
        keepsakeTask?.cancel()
        keepsakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            self?.keepsakeLine = nil
        }
    }

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
            ?? (selectedConversationValue?.id == selectedConversationID ? selectedConversationValue : nil)
    }
    var isConnected: Bool { connection == .connected }
    var libraryScope: String { namespace }
    var isGenerating: Bool { activeRunID != nil }
    var availableEfforts: [String] { models.first { $0.id == selectedModelID }?.efforts ?? ["medium"] }
    var connectionLabel: String {
        switch connection {
        case .offline: return "离线琴房"
        case .connecting: return "正在接续"
        case .connected: return providerSimulated ? "本地演练 · 非 AI" : "琴房已连接"
        case .failed: return "等待重新接续"
        }
    }

    private var store: LocalStore?
    private var gateway: GatewayClient?
    private let libraryURL: URL
    private var namespace = "unpaired"
    private var conversationNamespace: String?
    private var cursor: Int64 = 0
    private var currentRun: ActiveRun?
    private var selectedConversationValue: Conversation?
    private var canonicalMessages: [ChatMessage] = []
    private var eventTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var settingsRevision = UUID()
    private var selectionRevision = UUID()
    private var busySelectionRevision: UUID?
    private var connectionRevision = UUID()
    private var searchRevision = UUID()
    private var restoringDraft = false
    private var draftEditRevision: UInt64 = 0
    private var draftOwnerID = "unsent"
    private var draftIsReady = true
    private var sending = false
    private var didStart = false
    private var startInProgress = false
    private var contextQueues: [String: Task<Void, Never>] = [:]
    private var contextQueueTokens: [String: UUID] = [:]
    private var pinMutationKeys: Set<String> = []
    private var taskMutationKeys: Set<String> = []
    private var cardMutationKeys: Set<String> = []
    private var noticeRevision: UInt64 = 0
    private var transientConnectionNoticeRevision: UInt64?
    private static let logger = Logger(subsystem: "app.hajisaki.theater.ipad", category: "TheaterModel")
    private var applicationActive = true
    private var leftWhileWriting: String?
    private var userDisconnected = UserDefaults.standard.bool(forKey: "hajisaki.connection.disconnected")
    private var authorizationNeedsReview = false
    private var connectionIntent = UUID()
    private var connectionAttemptTask: Task<ConnectionAttemptOutcome, Never>?
    private var connectionAttemptID: UUID?
    private var connectionAttemptIntent: UUID?
    private var connectionRecoveryTask: Task<Void, Never>?
    private var connectionRecoveryID = UUID()
    private var recoveryCredentials: GatewayCredentials?

    private enum ConnectionAttemptOutcome { case connected, transientFailure, authorizationFailure, failed, cancelled }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        libraryURL = base.appendingPathComponent("HajiSaki", isDirectory: true)
        if let theme = UserDefaults.standard.string(forKey: "hajisaki.lastTheme"), ["auto", "night", "day"].contains(theme) {
            settings.theme = theme
        }
        do {
            try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            store = try LocalStore(url: libraryURL.appendingPathComponent("unpaired.sqlite3"))
        } catch { notice = "本机的记忆本暂时打不开，请检查剩余空间。" }
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        startInProgress = true
        isReadyForNavigation = false
        defer {
            startInProgress = false
            settleNavigationReadiness()
        }
        do {
            if let saved = try CredentialVault.load() {
                hostAddress = saved.address; deviceID = saved.deviceID
                draftIsReady = false
                try openStore(for: saved)
                try await loadCachedLibrary()
                recoveryCredentials = saved
                if !userDisconnected, applicationActive {
                    _ = await runConnectionAttempt(saved, intent: connectionIntent)
                }
            } else { try await loadCachedLibrary() }
        } catch { show(error) }
    }

    func connect(token: String) async {
        let credentials = GatewayCredentials(address: hostAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                                             deviceID: deviceID.trimmingCharacters(in: .whitespacesAndNewlines), token: token)
        beginExplicitConnectionIntent()
        // Only an already saved pairing is eligible for automatic retry. A new
        // pairing remains an explicit user attempt until it has succeeded once.
        if let saved = try? CredentialVault.load(), Self.samePairing(saved, credentials) { recoveryCredentials = saved }
        else { recoveryCredentials = nil }
        let intent = connectionIntent
        _ = await runConnectionAttempt(credentials, intent: intent, userInitiated: true)
        if connectionIntent == intent, recoveryCredentials == nil { authorizationNeedsReview = true }
    }

    private func connectOnce(_ credentials: GatewayCredentials, clearNotice: Bool) async -> ConnectionAttemptOutcome {
        let revision = UUID()
        connectionRevision = revision
        isReadyForNavigation = false
        defer { if connectionRevision == revision { settleNavigationReadiness() } }
        selectionRevision = UUID()
        if busySelectionRevision != nil { busySelectionRevision = nil; isBusy = !draftIsReady }
        eventTask?.cancel()
        cancelContextHydration()
        connection = .connecting
        if clearNotice { notice = nil }
        do {
            let client = try GatewayClient(credentials: credentials)
            async let status = client.status()
            async let catalog = client.models()
            let (host, discovered) = try await (status, catalog)
            guard connectionRevision == revision, !Task.isCancelled else { return .cancelled }
            await flushDraft()
            guard connectionRevision == revision, !Task.isCancelled else { return .cancelled }
            try CredentialVault.save(credentials)
            recoveryCredentials = credentials
            let nextNamespace = Self.namespace(for: credentials)
            if namespace != nextNamespace {
                let unsent = namespace == "unpaired" && selectedConversationID == nil ? draft : ""
                draftIsReady = false
                try openStore(for: credentials)
                selectedConversationID = nil; selectedConversationValue = nil; canonicalMessages = []; messages = []; events = []
                contextPins = []; messageTasks = [:]; interactiveCards = [:]; interactiveCardReading = [:]; refreshContextBusyState()
                activeRunID = nil; currentRun = nil; cursor = 0; pendingAttachments = []
                try await loadCachedLibrary()
                guard connectionRevision == revision, !Task.isCancelled else { return .cancelled }
                if selectedConversationID == nil {
                    if !unsent.isEmpty && draft.isEmpty { draft = unsent }
                }
            }
            gateway = client
            applyStatus(host)
            models = discovered
            normalizeModel()
            connection = .connected
            if let hydrationError = await refreshLibrary() {
                guard connectionRevision == revision, !Task.isCancelled else { return .cancelled }
                connection = .failed
                if Self.isTransientConnectionError(hydrationError) { transientConnectionNoticeRevision = noticeRevision }
                if Self.isAuthorizationError(hydrationError) { return .authorizationFailure }
                return Self.isTransientConnectionError(hydrationError) ? .transientFailure : .failed
            }
            guard connectionRevision == revision, !Task.isCancelled else { return .cancelled }
            recoveryCredentials = credentials
            if isConnected { clearRecoveredTransportNotice() }
            return .connected
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return .cancelled }
            connection = .failed
            show(error, stage: "connect")
            if Self.isTransientConnectionError(error) { transientConnectionNoticeRevision = noticeRevision }
            if !draftIsReady, let selected = selectedConversation {
                await selectConversation(selected)
            }
            if Self.isAuthorizationError(error) { return .authorizationFailure }
            return Self.isTransientConnectionError(error) ? .transientFailure : .failed
        }
    }

    func reconnect() async {
        beginExplicitConnectionIntent()
        do {
            guard let saved = try CredentialVault.load() else { recoveryCredentials = nil; connection = .offline; return }
            hostAddress = saved.address; deviceID = saved.deviceID
            recoveryCredentials = saved
            _ = await runConnectionAttempt(saved, intent: connectionIntent, userInitiated: true)
        } catch { connection = .failed; authorizationNeedsReview = true; show(error, stage: "reconnect") }
    }

    func disconnect() {
        userDisconnected = true
        UserDefaults.standard.set(true, forKey: "hajisaki.connection.disconnected")
        connectionIntent = UUID()
        cancelConnectionRecovery()
        connectionAttemptTask?.cancel()
        connectionRevision = UUID()
        eventTask?.cancel(); eventTask = nil
        cancelContextHydration()
        gateway = nil; connection = .offline
        settleNavigationReadiness()
    }

    /// Scene lifecycle only controls connection work. It does not stop host jobs,
    /// remove the offline library, or authorize microphone/location access.
    func setApplicationActive(_ active: Bool) async {
        applicationActive = active
        if !active {
            // If she is writing when you leave, she will say so when you come back to a finished reply.
            leftWhileWriting = isGenerating ? selectedConversationID : nil
            cancelConnectionRecovery()
            connectionAttemptTask?.cancel()
            eventTask?.cancel(); eventTask = nil
            cancelContextHydration()
            connectionRevision = UUID()
            if connection == .connecting { connection = .offline }
            settleNavigationReadiness()
            return
        }
        await resumeConnectionIfNeeded()
        if let letter = leftWhileWriting, letter == selectedConversationID, !isGenerating {
            say(CompanionMood.openLine(draft: false, settings: settings))
        }
        leftWhileWriting = nil
    }

    func resumeConnectionIfNeeded() async {
        guard applicationActive, didStart, !startInProgress, !userDisconnected, !authorizationNeedsReview,
              connectionAttemptTask == nil, connectionRecoveryTask == nil else { return }
        if isConnected, gateway != nil, eventTask != nil { return }
        do {
            let available: GatewayCredentials?
            if let cached = recoveryCredentials { available = cached }
            else { available = try CredentialVault.load() }
            guard let saved = available else { return }
            recoveryCredentials = saved
            _ = await runConnectionAttempt(saved, intent: connectionIntent)
        } catch { authorizationNeedsReview = true; show(error, stage: "foreground-reconnect") }
    }

    private func beginExplicitConnectionIntent() {
        userDisconnected = false
        UserDefaults.standard.set(false, forKey: "hajisaki.connection.disconnected")
        authorizationNeedsReview = false
        connectionIntent = UUID()
        cancelConnectionRecovery()
        connectionAttemptTask?.cancel()
    }

    private func runConnectionAttempt(_ credentials: GatewayCredentials, intent: UUID,
                                      userInitiated: Bool = false, scheduleRecovery: Bool = true) async -> ConnectionAttemptOutcome {
        if let prior = connectionAttemptTask {
            let priorIntent = connectionAttemptIntent
            let outcome = await prior.value
            if priorIntent == intent, connectionIntent == intent { return outcome }
        }
        guard connectionIntent == intent, applicationActive, !userDisconnected, !authorizationNeedsReview,
              !Task.isCancelled else { return .cancelled }
        let attemptID = UUID()
        let task = Task { await self.connectOnce(credentials, clearNotice: userInitiated) }
        connectionAttemptTask = task; connectionAttemptID = attemptID; connectionAttemptIntent = intent
        let outcome = await task.value
        if connectionAttemptID == attemptID { connectionAttemptTask = nil; connectionAttemptID = nil; connectionAttemptIntent = nil }
        guard connectionIntent == intent, applicationActive, !userDisconnected else { return .cancelled }
        if case .authorizationFailure = outcome {
            authorizationNeedsReview = true
            cancelConnectionRecovery()
        } else if case .transientFailure = outcome, scheduleRecovery {
            scheduleConnectionRecovery(intent: intent)
        } else if case .cancelled = outcome, scheduleRecovery {
            // A foreground transition can arrive while the cancelled background
            // attempt is still unwinding. Preserve the saved pairing's retry intent.
            scheduleConnectionRecovery(intent: intent)
        }
        return outcome
    }

    private func scheduleConnectionRecovery(intent: UUID) {
        guard connectionRecoveryTask == nil, recoveryCredentials != nil, applicationActive,
              !userDisconnected, !authorizationNeedsReview, connectionIntent == intent else { return }
        let recoveryID = UUID(); connectionRecoveryID = recoveryID
        connectionRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connectionRecoveryID == recoveryID { self.connectionRecoveryTask = nil }
            }
            var delay: UInt64 = 2
            while !Task.isCancelled, self.applicationActive, !self.userDisconnected,
                  !self.authorizationNeedsReview, self.connectionIntent == intent {
                Self.logger.info("Connection retry delaySeconds=\(delay, privacy: .public)")
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
                guard !Task.isCancelled, self.applicationActive, self.connectionIntent == intent,
                      let saved = self.recoveryCredentials else { return }
                let outcome = await self.runConnectionAttempt(saved, intent: intent, scheduleRecovery: false)
                switch outcome {
                case .transientFailure: delay = min(delay * 2, 30)
                case .connected, .authorizationFailure, .failed, .cancelled: return
                }
            }
        }
    }

    private func cancelConnectionRecovery() {
        connectionRecoveryID = UUID()
        connectionRecoveryTask?.cancel(); connectionRecoveryTask = nil
    }

    private static func samePairing(_ lhs: GatewayCredentials, _ rhs: GatewayCredentials) -> Bool {
        lhs.address == rhs.address && lhs.deviceID == rhs.deviceID && lhs.token == rhs.token
    }

    func refresh() async {
        let revision = connectionRevision
        if let error = await refreshLibrary(), revision == connectionRevision { recoverAfterHydrationFailure(error) }
    }

    /// Conversation list and selected transcript are required for a successful
    /// reconnect. Memories, file catalogue and preferences refresh independently.
    private func refreshLibrary() async -> Error? {
        guard let client = gateway else { await search(); return nil }
        guard let destinationStore = store else { show(TheaterError.storage); return TheaterError.storage }
        let revision = connectionRevision
        do {
            let all = try await client.conversations()
            guard connectionRevision == revision else { return CancellationError() }
            try await destinationStore.reconcileConversations(all)
            guard connectionRevision == revision else { return CancellationError() }
            connection = .connected
            await search()
            guard connectionRevision == revision else { return CancellationError() }
            if let selected = all.first(where: { $0.id == selectedConversationID }) {
                if let error = await loadConversation(selected) { return error }
            } else if selectedConversationID == nil, draft.isEmpty, pendingAttachments.isEmpty, let first = all.first {
                if let error = await loadConversation(first) { return error }
            }
            try await refreshPending()
        } catch {
            guard connectionRevision == revision else { return CancellationError() }
            show(error, stage: "library-transcript")
            return error
        }
        guard connectionRevision == revision else { return CancellationError() }
        do {
            async let fetchedMemories = client.value(MemoryEnvelope.self, path: "/api/memories")
            async let fetchedArtifacts = client.value(ArtifactEnvelope.self, path: "/api/artifacts")
            async let fetchedSettings = client.value(TheaterSettings.self, path: "/api/settings")
            let (memory, files, preferences) = try await (fetchedMemories, fetchedArtifacts, fetchedSettings)
            guard connectionRevision == revision else { return CancellationError() }
            try await destinationStore.saveObject(key: "memories", value: memory.memories)
            try await destinationStore.saveObject(key: "artifacts", value: files.artifacts)
            try await destinationStore.saveObject(key: "settings", value: preferences)
            guard connectionRevision == revision else { return CancellationError() }
            memories = memory.memories; artifacts = files.artifacts; settings = preferences
        } catch {
            if connectionRevision == revision { show(error, stage: "library-metadata") }
        }
        return nil
    }

    func search() async {
        let revision = UUID(); searchRevision = revision
        let hostRevision = connectionRevision, destinationStore = store
        let query = searchText, group = selectedGroup
        do {
            if let client = gateway, isConnected {
                let found = try await client.conversations(query: query, group: group)
                guard revision == searchRevision, hostRevision == connectionRevision else { return }
                try await destinationStore?.saveConversations(found)
                guard revision == searchRevision, hostRevision == connectionRevision else { return }
                conversations = found
                watchWriting()
            } else {
                let found = try await destinationStore?.loadConversations(query: query, group: group) ?? []
                guard revision == searchRevision, hostRevision == connectionRevision else { return }
                conversations = found
            }
        } catch {
            if revision == searchRevision, hostRevision == connectionRevision {
                let cached = try? await destinationStore?.loadConversations(query: query, group: group)
                guard revision == searchRevision, hostRevision == connectionRevision else { return }
                conversations = cached ?? conversations
                show(error)
            }
        }
    }

    func selectConversation(_ conversation: Conversation) async {
        let revision = connectionRevision
        if let error = await loadConversation(conversation), revision == connectionRevision { recoverAfterHydrationFailure(error) }
    }

    private func loadConversation(_ conversation: Conversation) async -> Error? {
        let revision = UUID(); selectionRevision = revision
        let hostRevision = connectionRevision
        busySelectionRevision = revision
        isBusy = true
        defer {
            if busySelectionRevision == revision { busySelectionRevision = nil; isBusy = false }
            if selectionRevision == revision { settleNavigationReadiness() }
        }
        await flushDraft()
        guard selectionRevision == revision else { return CancellationError() }
        eventTask?.cancel()
        if let leaving = selectedConversationID {
            markSeen(leaving, at: [events.last?.createdAt, messages.last?.createdAt, selectedConversation?.updatedAt]
                .compactMap { $0 }.max { (Self.letterDate($0) ?? .distantPast) < (Self.letterDate($1) ?? .distantPast) })
        }
        let waiting = isUnread(conversation) && selectedConversationID != conversation.id
        markSeen(conversation.id, at: conversation.updatedAt)
        let retainingCurrent = selectedConversationID == conversation.id && conversationNamespace == namespace
            && draftOwnerID == conversation.id && draftIsReady
        selectedConversationID = conversation.id
        selectedConversationValue = conversation
        conversationNamespace = namespace
        if !retainingCurrent {
            contextPins = []; messageTasks = [:]; interactiveCards = [:]; interactiveCardReading = [:]; refreshContextBusyState()
            draftIsReady = false
            pendingAttachments = []
            restoreDraft("")
            canonicalMessages = []; messages = []; events = []; currentRun = nil; activeRunID = nil; cursor = 0
        }
        let initialDraftRevision = draftEditRevision
        do {
            guard let store else { throw TheaterError.storage }
            try await store.saveObject(key: "selection", value: conversation.id)
            if !retainingCurrent {
                let cached = try await store.loadSnapshot(conversationID: conversation.id)
                guard selectionRevision == revision else { return CancellationError() }
                if let cached { applySnapshot(cached) }
                let cachedEvents = try await store.loadEvents(conversationID: conversation.id)
                let cachedPins = try await store.loadObject(key: "context-pins-" + conversation.id, as: [ContextPin].self) ?? []
                let savedDraft = try await store.draft(conversationID: conversation.id)
                let savedAttachments = try await store.loadObject(key: "attachments-" + conversation.id, as: [Artifact].self) ?? []
                guard selectionRevision == revision else { return CancellationError() }
                events = cachedEvents
                contextPins = cachedPins.filter { $0.clientContextID == namespace }
                pendingAttachments = savedAttachments + pendingAttachments.filter { extra in !savedAttachments.contains(where: { $0.id == extra.id }) }
                draftOwnerID = conversation.id; draftIsReady = true
                if draftEditRevision == initialDraftRevision { restoreDraft(savedDraft) }
                // She notices why you came back: your unfinished draft, or her reply waiting for you.
                if !savedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { say(CompanionMood.openLine(draft: true, settings: settings)) }
                else if waiting { say(CompanionMood.openLine(draft: false, settings: settings)) }
                else if !savedDraft.isEmpty { draft = savedDraft + "\n" + draft }
            }
            try await refreshPending()
            if let client = gateway, isConnected, hostRevision == connectionRevision {
                try await syncSnapshot(conversation.id, client: client, revision: revision)
                guard selectionRevision == revision, hostRevision == connectionRevision, isConnected else { return CancellationError() }
                startStream(conversation.id, client: client, revision: revision)
            }
            return nil
        } catch {
            guard selectionRevision == revision, hostRevision == connectionRevision else { return CancellationError() }
            show(error, stage: "conversation-hydration")
            return error
        }
    }

    private func recoverAfterHydrationFailure(_ error: Error) {
        if Self.isAuthorizationError(error) {
            authorizationNeedsReview = true; connection = .failed
            cancelConnectionRecovery()
        } else if Self.isTransientConnectionError(error) {
            connection = .failed
            transientConnectionNoticeRevision = noticeRevision
            scheduleConnectionRecovery(intent: connectionIntent)
        }
    }

    func createConversation(title: String = "新的乐章", group: String = "专属日常") async {
        guard let client = gateway, isConnected else { notice = "先把想说的话写下来。接通琴房后，再为它翻开新的一页。"; return }
        guard let destinationStore = store else { show(TheaterError.storage); return }
        let hostRevision = connectionRevision
        isBusy = true
        defer { isBusy = false }
        do {
            let conversation = try await client.value(Conversation.self, path: "/api/conversations", method: "POST",
                                                      body: ["title": .string(title), "group": .string(group)])
            try await destinationStore.saveConversations([conversation])
            guard hostRevision == connectionRevision else { return }
            if selectedConversationID == nil, draftIsReady {
                try await destinationStore.moveDraft(from: "unsent", to: conversation.id, text: draft, attachments: pendingAttachments)
                guard hostRevision == connectionRevision else { return }
                draftIsReady = false
                draftTask?.cancel()
            }
            searchText = ""; selectedGroup = ""
            await search()
            guard hostRevision == connectionRevision else { return }
            await selectConversation(conversation)
        } catch { show(error) }
    }

    func send() async {
        guard !sending else { return }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty else { return }
        guard !isGenerating else { notice = "这一段还在写。可以先停下，再接着补充。"; return }
        sending = true
        defer { sending = false }
        if selectedConversationID == nil {
            await createConversation()
            guard selectedConversationID != nil else { await flushDraft(); return }
        }
        guard draftIsReady, let id = selectedConversationID, id == draftOwnerID, let store else { return }
        let submittedRevision = draftEditRevision
        let submittedNamespace = namespace
        let entry = OutboxEntry(clientID: UUID().uuidString, conversationID: id, content: draft,
                                model: selectedModelID, effort: selectedEffort,
                                attachments: pendingAttachments.map(\.id), createdAt: Self.timestamp())
        do {
            try await store.enqueue(entry)
            if namespace == submittedNamespace, draftOwnerID == id, draftIsReady,
               draftEditRevision == submittedRevision, draft == entry.content,
               pendingAttachments.map(\.id) == entry.attachments {
                draft = ""; pendingAttachments = []
                await flushDraft()
            }
            try await refreshPending()
            guard namespace == submittedNamespace else { return }
            guard let client = gateway, isConnected else { notice = "这封信已留在本机，接通后可继续递送。"; return }
            try await deliver(entry, client: client)
        } catch { show(error) }
    }

    func retryPending() async {
        guard !sending, let client = gateway, isConnected, let store else { return }
        let hostRevision = connectionRevision
        sending = true
        defer { sending = false }
        do {
            let queued = try await store.loadOutbox()
            var sentConversations = Set<String>()
            for entry in queued {
                guard hostRevision == connectionRevision else { return }
                if sentConversations.contains(entry.conversationID) { continue }
                try await deliver(entry, client: client)
                sentConversations.insert(entry.conversationID)
            }
        } catch { show(error) }
    }

    func stop() async {
        guard let run = activeRunID, let client = gateway else { return }
        let hostRevision = connectionRevision, selectedRevision = selectionRevision, conversationID = selectedConversationID
        do {
            _ = try await client.value([String: JSONValue].self, path: "/api/runs/\(run)/stop", method: "POST")
            guard hostRevision == connectionRevision, selectedRevision == selectionRevision else { return }
            say(settings.personality.teasing >= 60 ? "……好吧，先停在这里。" : "好，先停在这里。")
            if activeRunID == run { activeRunID = nil; currentRun = nil }
            if let id = conversationID {
                eventTask?.cancel()
                let revision = UUID(); selectionRevision = revision
                try await syncSnapshot(id, client: client, revision: revision)
                if selectionRevision == revision { startStream(id, client: client, revision: revision) }
            }
        } catch { show(error) }
    }

    func togglePin(_ conversation: Conversation) async {
        guard let client = gateway else { show(TheaterError.disconnected); return }
        let destinationStore = store, hostRevision = connectionRevision
        do {
            let changed = try await client.value(Conversation.self, path: "/api/conversations/\(conversation.id)", method: "PATCH",
                                                body: ["pinned": .bool(!conversation.pinned)])
            try await destinationStore?.saveConversations([changed])
            // Pinning touches the letter's time; that is not a new reply.
            if seenLetters[changed.id] != nil { markSeen(changed.id, at: changed.updatedAt) }
            say(changed.pinned ? "放在心上了。最上面那封，就是它。" : "嗯，先把它放回原处。")
            if hostRevision == connectionRevision { await search() }
        } catch { show(error) }
    }

    func fork(from message: ChatMessage) async {
        guard let client = gateway, !message.id.hasPrefix("pending-") else { show(TheaterError.disconnected); return }
        let destinationStore = store, hostRevision = connectionRevision
        do {
            let created = try await client.value(Conversation.self, path: "/api/conversations/\(message.conversationID)/fork", method: "POST",
                                                body: ["message_id": .string(message.id)])
            try await destinationStore?.saveConversations([created])
            guard hostRevision == connectionRevision else { return }
            searchText = ""; selectedGroup = ""
            await search()
            guard hostRevision == connectionRevision else { return }
            await selectConversation(created)
            say("从这里另起一页。原来那一页，我也好好留着。")
        } catch { show(error) }
    }

    func quote(_ message: ChatMessage) {
        let quoted = message.content.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        draft += (draft.isEmpty ? "" : "\n\n") + quoted + "\n\n"
    }

    func renameConversation(_ conversation: Conversation, title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let client = gateway, isConnected, let destinationStore = store else { return }
        let origin = namespace, revision = connectionRevision
        do {
            let updated = try await client.value(Conversation.self, path: "/api/conversations/\(conversation.id)", method: "PATCH", body: ["title": .string(title)])
            try await destinationStore.saveConversations([updated])
            guard namespace == origin, connectionRevision == revision else { return }
            if seenLetters[updated.id] != nil { markSeen(updated.id, at: updated.updatedAt) }
            say("嗯，它现在叫「\(updated.title)」了。")
            if selectedConversationID == updated.id { selectedConversationValue = updated }
            await search()
        } catch { if namespace == origin, connectionRevision == revision { show(error) } }
    }

    /// Provider callbacks can finish after the user changes conversation or host.
    /// Keep dropped text in the draft that owned the original drop.
    func appendImportedText(_ text: String, to conversationID: String?, scope: String) async {
        guard !text.isEmpty, scope == "unpaired" || scope.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return }
        let target = conversationID ?? "unsent"
        do {
            let destinationStore: LocalStore
            if scope == namespace, let store { destinationStore = store }
            else {
                let url = libraryURL.appendingPathComponent(scope + ".sqlite3")
                guard FileManager.default.fileExists(atPath: url.path) else { throw TheaterError.storage }
                destinationStore = try LocalStore(url: url)
            }
            while scope == namespace, selectedConversationID == conversationID, !draftIsReady, isBusy {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if scope == namespace, draftIsReady, draftOwnerID == target {
                draft += (draft.isEmpty ? "" : "\n\n") + text
                await flushDraft()
            } else { try await destinationStore.appendDraft(conversationID: target, text: text) }
        } catch { show(error) }
    }

    func attach(_ artifact: Artifact) {
        if !pendingAttachments.contains(where: { $0.id == artifact.id }) { pendingAttachments.append(artifact) }
        scheduleDraftSave()
    }
    @discardableResult
    func attach(_ artifact: Artifact, to conversationID: String?) async -> Bool {
        let target = conversationID ?? "unsent"
        let origin = namespace
        do {
            guard let store else { throw TheaterError.storage }
            if draftIsReady, draftOwnerID == target {
                attach(artifact)
                await flushDraft()
                let saved = try await store.loadObject(key: "attachments-" + target, as: [Artifact].self) ?? []
                return saved.contains { $0.id == artifact.id }
            } else {
                var items = try await store.loadObject(key: "attachments-" + target, as: [Artifact].self) ?? []
                if !items.contains(where: { $0.id == artifact.id }) { items.append(artifact) }
                try await store.saveObject(key: "attachments-" + target, value: items)
                return true
            }
        } catch { if namespace == origin { show(error) }; return false }
    }
    func removeAttachment(id: String) { pendingAttachments.removeAll { $0.id == id }; scheduleDraftSave() }

    func saveMemory(content: String, id: String? = nil) async {
        guard let client = gateway else { show(TheaterError.disconnected); return }
        let destinationStore = store, hostRevision = connectionRevision
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let item = try await client.value(MemoryEntry.self, path: id.map { "/api/memories/\($0)" } ?? "/api/memories",
                                             method: id == nil ? "POST" : "PATCH", body: ["content": .string(content)])
            let updated = try await destinationStore?.upsertMemory(item) ?? []
            if hostRevision == connectionRevision {
                memories = updated
                say(id == nil ? "嗯，我记住了。" : "改好了。我会记住新的样子。")
            }
        } catch { show(error) }
    }
    func removeMemory(_ memory: MemoryEntry) async {
        guard let client = gateway else { show(TheaterError.disconnected); return }
        let destinationStore = store, hostRevision = connectionRevision
        do {
            _ = try await client.value([String: JSONValue].self, path: "/api/memories/\(memory.id)", method: "DELETE")
            let updated = try await destinationStore?.forgetMemory(id: memory.id) ?? []
            if hostRevision == connectionRevision {
                memories = updated
                say("先把这件事收起来了。想找回的话，主机回收站里还在。")
            }
        } catch { show(error) }
    }
    func saveSettings(_ value: TheaterSettings) async {
        settings = value
        let revision = UUID(); settingsRevision = revision
        let predecessor = settingsTask
        let destinationStore = store
        let client = isConnected ? gateway : nil
        let hostRevision = connectionRevision
        let operation = Task { [weak self] in
            await predecessor?.value
            do {
                guard let destinationStore else { throw TheaterError.storage }
                var confirmed = value
                if let client {
                    let data = try JSONEncoder().encode(value)
                    let body = try JSONDecoder().decode([String: JSONValue].self, from: data)
                    confirmed = try await client.value(TheaterSettings.self, path: "/api/settings", method: "PATCH", body: body)
                }
                try await destinationStore.saveObject(key: "settings", value: confirmed)
                if let self, self.connectionRevision == hostRevision, self.settingsRevision == revision { self.settings = confirmed }
            } catch {
                if let self, self.connectionRevision == hostRevision, self.settingsRevision == revision { self.show(error) }
            }
        }
        settingsTask = operation
        await operation.value
        if settingsRevision == revision { settingsTask = nil }
    }

    func upload(fileURL: URL) async -> Artifact? {
        guard let client = gateway, isConnected else { show(TheaterError.disconnected); return nil }
        guard transferProgress == nil else { notice = "先让手中的这份文件送完。"; return nil }
        let originNamespace = namespace, originStore = store
        transferProgress = 0
        defer { transferProgress = nil }
        do {
            let artifact = try await client.upload(fileURL: fileURL) { [weak self] amount in
                await self?.updateTransferProgress(amount)
            }
            let updated = try await originStore?.rememberArtifact(artifact) ?? []
            guard namespace == originNamespace else { return nil }
            artifacts = updated
            return artifact
        } catch { show(error); return nil }
    }

    func download(_ artifact: Artifact) async -> URL? {
        let directory = libraryURL.appendingPathComponent(namespace).appendingPathComponent("Files")
        let candidates = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        if gateway == nil, let cached = candidates.first(where: { $0.lastPathComponent.hasPrefix(artifact.id + "-") }) {
            do {
                guard try await GatewayClient.backgroundDigest(cached) == artifact.sha256 else { throw TheaterError.integrity }
                return cached
            } catch { show(error); return nil }
        }
        guard let client = gateway else { show(TheaterError.disconnected); return nil }
        do { return try await client.download(artifact, to: directory) }
        catch { show(error); return nil }
    }
    func exportLibrary() async -> URL? {
        guard let client = gateway else { show(TheaterError.disconnected); return nil }
        do { return try await client.exportLibrary(to: libraryURL.appendingPathComponent(namespace).appendingPathComponent("Exports")) }
        catch { show(error); return nil }
    }

    func requestTranscription(for artifact: Artifact, language: String? = nil, conversationID: String? = nil) async -> SpeechJob? {
        guard let client = gateway, isConnected, let destinationStore = store else { show(TheaterError.disconnected); return nil }
        let origin = namespace, revision = connectionRevision
        do {
            var body: [String: JSONValue] = ["artifact_id": .string(artifact.id), "cleanup": .bool(false)]
            if let language, !language.isEmpty { body["language"] = .string(language) }
            var job = try await client.value(SpeechJob.self, path: "/api/speech/transcriptions", method: "POST", body: body)
            job.clientContextID = origin
            job.clientConversationID = conversationID
            let saved = try await destinationStore.saveSpeechJob(job)
            guard namespace == origin, connectionRevision == revision else { return nil }
            return saved
        } catch {
            if namespace == origin, connectionRevision == revision { show(error) }
            return nil
        }
    }

    func refreshTranscription(_ job: SpeechJob) async -> SpeechJob? {
        await updateTranscription(job, stop: false)
    }

    func stopTranscription(_ job: SpeechJob) async -> SpeechJob? {
        await updateTranscription(job, stop: true)
    }

    private func updateTranscription(_ job: SpeechJob, stop: Bool) async -> SpeechJob? {
        guard job.clientContextID == namespace else { notice = "这段录音属于另一间琴房，请先接回原来的主机。"; return nil }
        guard let destinationStore = store else { show(TheaterError.storage); return nil }
        let origin = namespace, revision = connectionRevision
        guard let client = gateway else {
            if stop { show(TheaterError.disconnected); return nil }
            let cached = (try? await destinationStore.loadObject(key: "speech-job-" + job.id, as: SpeechJob.self)) ?? job
            guard namespace == origin, connectionRevision == revision else { return nil }
            return cached
        }
        do {
            var updated = try await client.value(SpeechJob.self, path: "/api/speech/transcriptions/\(job.id)" + (stop ? "/stop" : ""),
                                                 method: stop ? "POST" : "GET")
            updated.clientContextID = origin
            updated.clientConversationID = job.clientConversationID
            let saved = try await destinationStore.saveSpeechJob(updated)
            guard namespace == origin, connectionRevision == revision else { return nil }
            return saved
        } catch {
            if namespace == origin, connectionRevision == revision { show(error) }
            return nil
        }
    }

    func cleanTranscript(text: String) async -> String? {
        guard let client = gateway, isConnected else { show(TheaterError.disconnected); return nil }
        let revision = connectionRevision
        do {
            let cleaned = try await client.value(SpeechCleanup.self, path: "/api/speech/clean", method: "POST", body: ["text": .string(text)])
            guard revision == connectionRevision else { return nil }
            return cleaned.text
        } catch { if revision == connectionRevision { show(error) }; return nil }
    }

    func readHotwords() async -> [SpeechHotword]? {
        guard let destinationStore = store else { show(TheaterError.storage); return nil }
        let revision = connectionRevision
        do {
            guard let client = gateway, isConnected else {
                let cached = try await destinationStore.loadObject(key: "speech-hotwords", as: [SpeechHotword].self) ?? []
                guard revision == connectionRevision else { return nil }
                return cached
            }
            let dictionary = try await client.value(SpeechHotwordEnvelope.self, path: "/api/speech/hotwords")
            try await destinationStore.saveObject(key: "speech-hotwords", value: dictionary.hotwords)
            guard revision == connectionRevision else { return nil }
            return dictionary.hotwords
        } catch { if revision == connectionRevision { show(error) }; return nil }
    }

    func saveHotwords(_ entries: [SpeechHotword]) async -> [SpeechHotword]? {
        guard let client = gateway, isConnected, let destinationStore = store else { show(TheaterError.disconnected); return nil }
        let revision = connectionRevision
        do {
            let data = try JSONEncoder().encode(SpeechHotwordEnvelope(hotwords: entries))
            let body = try JSONDecoder().decode([String: JSONValue].self, from: data)
            let dictionary = try await client.value(SpeechHotwordEnvelope.self, path: "/api/speech/hotwords", method: "PUT", body: body)
            try await destinationStore.saveObject(key: "speech-hotwords", value: dictionary.hotwords)
            guard revision == connectionRevision else { return nil }
            return dictionary.hotwords
        } catch { if revision == connectionRevision { show(error) }; return nil }
    }

    func recentTranscriptions() async -> [SpeechJob] {
        let origin = namespace
        do {
            let values = try await store?.loadSpeechJobs() ?? []
            guard namespace == origin else { return [] }
            return values.filter { $0.clientContextID == origin }
        } catch { if namespace == origin { show(error) }; return [] }
    }

    func transcriptDraft(for job: SpeechJob) async -> String? {
        guard job.clientContextID == namespace else { return nil }
        let origin = namespace
        do {
            let text = try await store?.loadObject(key: "speech-draft-" + job.id, as: String.self)
            guard origin == namespace else { return nil }
            return text ?? job.text
        } catch { if namespace == origin { show(error) }; return nil }
    }

    func saveTranscriptDraft(_ text: String, for job: SpeechJob) async {
        guard job.clientContextID == namespace else { return }
        let origin = namespace, destinationStore = store
        do { try await destinationStore?.saveObject(key: "speech-draft-" + job.id, value: text) }
        catch { if origin == namespace { show(error) } }
    }

    func appendTranscript(_ text: String, from job: SpeechJob, to conversationID: String?) async {
        guard job.clientContextID == namespace else { notice = "这段录音属于另一间琴房，请先接回原来的主机。"; return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let target = conversationID ?? "unsent", origin = namespace
        do {
            guard let destinationStore = store else { throw TheaterError.storage }
            try await destinationStore.saveObject(key: "speech-draft-" + job.id, value: text)
            // A selection restores its cached draft before enabling the composer.
            // Let that small local transaction finish so its older read cannot overwrite this append.
            while origin == namespace, selectedConversationID == conversationID, !draftIsReady, isBusy {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard origin == namespace else { return }
            if draftIsReady, draftOwnerID == target {
                draft += (draft.isEmpty ? "" : "\n\n") + text
                await flushDraft()
            } else { try await destinationStore.appendDraft(conversationID: target, text: text) }
        } catch { if origin == namespace { show(error) } }
    }

    func loadPins(for conversationID: String? = nil) async -> [ContextPin]? {
        guard let id = conversationID ?? selectedConversationID, let destinationStore = store else { return [] }
        let origin = namespace, revision = connectionRevision, client = gateway
        do {
            let result = try await contextOperation(key: contextQueueKey(origin: origin, conversationID: id)) {
                let cached = try await destinationStore.loadObject(key: "context-pins-" + id, as: [ContextPin].self) ?? []
                if self.namespace == origin, self.selectedConversationID == id { self.contextPins = cached }
                guard let client, self.connectionRevision == revision, self.isConnected else { return cached }
                return try await self.fetchContextPins(id, client: client, store: destinationStore, origin: origin, revision: revision)
            }
            guard namespace == origin, connectionRevision == revision else { return nil }
            return result
        } catch { if namespace == origin, connectionRevision == revision { show(error) }; return nil }
    }

    func addPin(kind: ContextPinKind, targetID: String? = nil, content: String = "", conversationID: String? = nil) async -> ContextPin? {
        guard let id = conversationID ?? selectedConversationID, let client = gateway, isConnected,
              let destinationStore = store else { show(TheaterError.disconnected); return nil }
        let origin = namespace, revision = connectionRevision
        let key = contextQueueKey(origin: origin, conversationID: id)
        guard !pinMutationKeys.contains(key) else { return nil }
        pinMutationKeys.insert(key); refreshContextBusyState()
        defer { pinMutationKeys.remove(key); refreshContextBusyState() }
        do {
            let result = try await contextOperation(key: key) {
                guard self.namespace == origin, self.connectionRevision == revision else { throw CancellationError() }
                var body: [String: JSONValue] = ["kind": .string(kind.rawValue), "content": .string(content)]
                if let targetID { body["target_id"] = .string(targetID) }
                var added = try await client.value(ContextPin.self, path: "/api/conversations/\(id)/pins", method: "POST", body: body)
                guard added.conversationID == id else { throw TheaterError.invalidResponse }
                added.clientContextID = origin
                var saved = try await destinationStore.loadObject(key: "context-pins-" + id, as: [ContextPin].self) ?? []
                if !saved.contains(where: { $0.id == added.id }) { saved.append(added) }
                try await destinationStore.saveObject(key: "context-pins-" + id, value: saved)
                if self.namespace == origin, self.connectionRevision == revision, self.selectedConversationID == id { self.contextPins = saved }
                do {
                    let canonical = try await self.fetchContextPins(id, client: client, store: destinationStore, origin: origin, revision: revision)
                    return canonical.first(where: { $0.id == added.id }) ?? added
                } catch {
                    if self.namespace == origin, self.connectionRevision == revision { self.show(error) }
                    return added
                }
            }
            guard namespace == origin, connectionRevision == revision else { return nil }
            return result
        } catch { if namespace == origin, connectionRevision == revision { show(error) }; return nil }
    }

    func pinMessage(_ message: ChatMessage) async -> ContextPin? {
        guard !message.id.hasPrefix("pending-"), canonicalMessages.contains(where: { $0.id == message.id && $0.conversationID == message.conversationID }) else { return nil }
        let pin = await addPin(kind: .message, targetID: message.id, conversationID: message.conversationID)
        if pin != nil { say("钉好了。这一段，我会一直放在手边。") }
        return pin
    }

    func removePin(_ pin: ContextPin) async -> Bool {
        guard pin.clientContextID == namespace else { notice = "这枚书签属于另一间琴房，请先接回原来的主机。"; return false }
        guard let client = gateway, isConnected, let destinationStore = store else { show(TheaterError.disconnected); return false }
        let origin = namespace, revision = connectionRevision, id = pin.conversationID
        let key = contextQueueKey(origin: origin, conversationID: id)
        guard !pinMutationKeys.contains(key) else { return false }
        pinMutationKeys.insert(key); refreshContextBusyState()
        defer { pinMutationKeys.remove(key); refreshContextBusyState() }
        do {
            let result = try await contextOperation(key: key) {
                guard self.namespace == origin, self.connectionRevision == revision else { throw CancellationError() }
                let receipt = try await client.value([String: JSONValue].self, path: "/api/pins/\(pin.id)", method: "DELETE")
                guard receipt["status"]?.stringValue == "recycled" else { throw TheaterError.invalidResponse }
                var saved = try await destinationStore.loadObject(key: "context-pins-" + id, as: [ContextPin].self) ?? []
                saved.removeAll { $0.id == pin.id }
                try await destinationStore.saveObject(key: "context-pins-" + id, value: saved)
                if self.namespace == origin, self.connectionRevision == revision, self.selectedConversationID == id { self.contextPins = saved }
                do { _ = try await self.fetchContextPins(id, client: client, store: destinationStore, origin: origin, revision: revision) }
                catch { if self.namespace == origin, self.connectionRevision == revision { self.show(error) } }
                return true
            }
            return namespace == origin && connectionRevision == revision && result
        } catch { if namespace == origin, connectionRevision == revision { show(error) }; return false }
    }

    func loadInteractiveCard(_ artifact: Artifact, conversationID: String) async {
        guard artifact.isNativeCard, let destinationStore = store else { return }
        let origin = namespace, revision = connectionRevision, client = gateway
        let key = conversationID + "|" + artifact.id
        do {
            try await contextOperation(key: "cards|" + contextQueueKey(origin: origin, conversationID: conversationID)) {
                let cached = try await destinationStore.loadObject(key: "card-" + key, as: InteractiveCardSnapshot.self)
                let reading = try await destinationStore.loadObject(key: "card-reading-" + key, as: InteractiveCardReading.self)
                if self.namespace == origin, self.selectedConversationID == conversationID {
                    if var cached, cached.artifactID == artifact.id, cached.conversationID == conversationID {
                        cached.clientContextID = origin
                        self.interactiveCards[key] = cached
                    }
                    if let reading, self.interactiveCardReading[key] == nil { self.interactiveCardReading[key] = reading }
                }
                guard let client, self.connectionRevision == revision, self.isConnected else { return }
                var updated = try await client.value(InteractiveCardSnapshot.self,
                    path: "/api/conversations/\(conversationID)/cards/\(artifact.id)")
                guard updated.artifactID == artifact.id, updated.conversationID == conversationID else { throw TheaterError.invalidResponse }
                updated.clientContextID = origin
                try await destinationStore.saveObject(key: "card-" + key, value: updated)
                if self.namespace == origin, self.connectionRevision == revision, self.selectedConversationID == conversationID {
                    self.interactiveCards[key] = updated
                }
            }
        } catch is CancellationError { }
        catch { if namespace == origin, connectionRevision == revision { show(error) } }
    }

    func saveInteractiveCardReading(_ reading: InteractiveCardReading, in card: InteractiveCardSnapshot) async {
        guard card.clientContextID == namespace, card.conversationID == selectedConversationID,
              card.definition.cards.indices.contains(reading.index), let destinationStore = store else { return }
        let origin = namespace
        do {
            try await contextOperation(key: "card-reading|" + origin + "|" + card.key) {
                try await destinationStore.saveObject(key: "card-reading-" + card.key, value: reading)
                if self.namespace == origin, self.selectedConversationID == card.conversationID {
                    self.interactiveCardReading[card.key] = reading
                }
            }
        } catch is CancellationError { }
        catch { if namespace == origin { show(error) } }
    }

    func vote(_ option: Int, in card: InteractiveCardSnapshot) async {
        guard card.clientContextID == namespace, card.definition.kind == "poll",
              card.definition.options.indices.contains(option), let destinationStore = store,
              let client = gateway, isConnected else { show(TheaterError.disconnected); return }
        let origin = namespace, revision = connectionRevision
        let mutationKey = contextQueueKey(origin: origin, conversationID: card.conversationID) + "|" + card.artifactID
        guard !cardMutationKeys.contains(mutationKey) else { return }
        cardMutationKeys.insert(mutationKey); refreshContextBusyState()
        defer { cardMutationKeys.remove(mutationKey); refreshContextBusyState() }
        do {
            try await contextOperation(key: "cards|" + contextQueueKey(origin: origin, conversationID: card.conversationID)) {
                guard self.namespace == origin, self.connectionRevision == revision else { throw CancellationError() }
                var updated = try await client.value(InteractiveCardSnapshot.self,
                    path: "/api/conversations/\(card.conversationID)/cards/\(card.artifactID)/vote",
                    method: "POST", body: ["option_index": .number(Double(option))])
                guard updated.artifactID == card.artifactID, updated.conversationID == card.conversationID else { throw TheaterError.invalidResponse }
                updated.clientContextID = origin
                try await destinationStore.saveObject(key: "card-" + card.key, value: updated)
                if self.namespace == origin, self.connectionRevision == revision, self.selectedConversationID == card.conversationID {
                    self.interactiveCards[card.key] = updated
                }
            }
        } catch is CancellationError { }
        catch { if namespace == origin, connectionRevision == revision { show(error) } }
    }

    func loadTasks(for message: ChatMessage) async -> MessageTaskState? {
        guard !message.id.hasPrefix("pending-"), let destinationStore = store else { return nil }
        let origin = namespace, revision = connectionRevision, client = gateway
        do {
            let result: MessageTaskState? = try await contextOperation(key: contextQueueKey(origin: origin, conversationID: message.conversationID)) {
                let cached = try await destinationStore.loadObject(key: "context-tasks-" + message.id, as: MessageTaskState.self)
                if let cached, self.namespace == origin, self.selectedConversationID == message.conversationID { self.messageTasks[message.id] = cached }
                guard let client, self.connectionRevision == revision, self.isConnected else { return cached }
                return try await self.fetchMessageTasks(message.id, conversationID: message.conversationID,
                                                       client: client, store: destinationStore, origin: origin, revision: revision)
            }
            guard namespace == origin, connectionRevision == revision else { return nil }
            return result
        } catch { if namespace == origin, connectionRevision == revision { show(error) }; return nil }
    }

    func updateTask(_ item: MessageTaskItem, checked: Bool, in state: MessageTaskState) async -> MessageTaskState? {
        guard state.clientContextID == namespace, let messageID = state.messageID, let conversationID = state.conversationID else {
            notice = "这份清单属于另一间琴房，请先接回原来的主机。"; return nil
        }
        guard state.editable, state.items.contains(where: { $0.index == item.index }), item.index >= 0 else {
            notice = "等这一页写完，再勾下已经完成的事。"; return nil
        }
        guard let client = gateway, isConnected, let destinationStore = store else { show(TheaterError.disconnected); return nil }
        let origin = namespace, revision = connectionRevision
        let queueKey = contextQueueKey(origin: origin, conversationID: conversationID), mutationKey = queueKey + "|" + messageID
        guard !taskMutationKeys.contains(mutationKey) else { return nil }
        taskMutationKeys.insert(mutationKey); refreshContextBusyState()
        defer { taskMutationKeys.remove(mutationKey); refreshContextBusyState() }
        do {
            let result = try await contextOperation(key: queueKey) {
                guard self.namespace == origin, self.connectionRevision == revision else { throw CancellationError() }
                var updated = try await client.value(MessageTaskState.self, path: "/api/messages/\(messageID)/tasks/\(item.index)",
                                                     method: "PATCH", body: ["checked": .bool(checked)])
                updated.messageID = messageID; updated.conversationID = conversationID; updated.clientContextID = origin
                try await destinationStore.saveObject(key: "context-tasks-" + messageID, value: updated)
                if self.namespace == origin, self.connectionRevision == revision, self.selectedConversationID == conversationID {
                    self.messageTasks[messageID] = updated
                }
                return updated
            }
            guard namespace == origin, connectionRevision == revision else { return nil }
            // Ticking off a step she listed earns a (reluctant) word of praise.
            if checked { say(CompanionMood.taskPraise(settings), sticker: "sticker_praise") }
            return result
        } catch { if namespace == origin, connectionRevision == revision { show(error) }; return nil }
    }

    private func contextQueueKey(origin: String, conversationID: String) -> String { origin + "|" + conversationID }
    private func refreshContextBusyState() {
        let prefix = contextQueueKey(origin: namespace, conversationID: selectedConversationID ?? "")
        pinMutationPending = pinMutationKeys.contains(prefix)
        updatingTaskIDs = Set(taskMutationKeys.filter { $0.hasPrefix(prefix + "|") }.map { String($0.dropFirst(prefix.count + 1)) })
        updatingCardIDs = Set(cardMutationKeys.filter { $0.hasPrefix(prefix + "|") }.map { String($0.dropFirst(prefix.count + 1)) })
    }

    /// Serialize reads and writes per host/conversation because the host's context
    /// responses have no revision number. An older GET must not overwrite a checkbox PATCH.
    private func contextOperation<T>(key: String, operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = contextQueues[key], token = UUID()
        let result = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        let completion = Task<Void, Never> { _ = await result.result }
        contextQueues[key] = completion; contextQueueTokens[key] = token
        defer {
            if contextQueueTokens[key] == token { contextQueues[key] = nil; contextQueueTokens[key] = nil }
        }
        return try await withTaskCancellationHandler(operation: { try await result.value }, onCancel: { result.cancel() })
    }

    private func fetchContextPins(_ id: String, client: GatewayClient, store: LocalStore, origin: String, revision: UUID) async throws -> [ContextPin] {
        let envelope = try await client.value(ContextPinEnvelope.self, path: "/api/conversations/\(id)/pins")
        guard envelope.pins.allSatisfy({ $0.conversationID == id }) else { throw TheaterError.invalidResponse }
        let pins = envelope.pins.map { item -> ContextPin in var copy = item; copy.clientContextID = origin; return copy }
        try await store.saveObject(key: "context-pins-" + id, value: pins)
        if namespace == origin, connectionRevision == revision, selectedConversationID == id { contextPins = pins }
        return pins
    }

    private func fetchMessageTasks(_ messageID: String, conversationID: String, client: GatewayClient, store: LocalStore,
                                   origin: String, revision: UUID) async throws -> MessageTaskState {
        var state = try await client.value(MessageTaskState.self, path: "/api/messages/\(messageID)/tasks")
        state.messageID = messageID; state.conversationID = conversationID; state.clientContextID = origin
        try await store.saveObject(key: "context-tasks-" + messageID, value: state)
        if namespace == origin, connectionRevision == revision, selectedConversationID == conversationID { messageTasks[messageID] = state }
        return state
    }

    private func reconcileContext(_ id: String, snapshot: MessageSnapshot, client: GatewayClient, store: LocalStore,
                                  origin: String, revision: UUID) async throws {
        // This is only a request filter. The host supplies the actual task indices.
        let messageIDs = snapshot.messages.filter { Self.mayContainTasks($0.content) }.map(\.id)
        try await deferContextRefresh(id, pins: true, messageIDs: messageIDs, through: snapshot.cursor,
                                      client: client, store: store, origin: origin, revision: revision)
    }

    private struct PendingContextRefresh: Codable {
        var generation: String
        var pins: Bool
        var messageIDs: [String]
        var through: Int64
        var isPending: Bool { pins || !messageIDs.isEmpty }
    }
    private var contextHydrationTasks: [String: Task<Void, Never>] = [:]
    private var contextHydrationRevisions: [String: UUID] = [:]
    private var contextHydrationTokens: [String: UUID] = [:]
    private var contextHydrationWakeups: [String: UUID] = [:]

    /// The durable marker is a prerequisite for advancing the transcript cursor;
    /// optional HTTP endpoints are not. Marker operations use a separate queue so
    /// a slow context request cannot hold up the next reply fragment.
    private func deferContextRefresh(_ id: String, pins: Bool, messageIDs: [String], through: Int64,
                                     client: GatewayClient, store: LocalStore, origin: String, revision: UUID) async throws {
        let key = contextQueueKey(origin: origin, conversationID: id)
        try await contextOperation(key: key + "|marker") {
            let previous = try await store.loadObject(key: "context-pending-" + id, as: PendingContextRefresh.self)
            let pending = PendingContextRefresh(generation: UUID().uuidString, pins: pins || (previous?.pins ?? false),
                                                messageIDs: Set(messageIDs + (previous?.messageIDs ?? [])).sorted(),
                                                through: max(through, previous?.through ?? 0))
            try await store.saveObject(key: "context-pending-" + id, value: pending)
        }
        scheduleContextHydration(id, client: client, store: store, origin: origin, revision: revision)
    }

    private func mayHydrateContext(origin: String, revision: UUID) -> Bool {
        applicationActive && !userDisconnected && !authorizationNeedsReview && gateway != nil
            && namespace == origin && connectionRevision == revision
    }

    /// Lifecycle changes cancel HTTP/sleep work, but never erase pending markers.
    private func cancelContextHydration() {
        for task in contextHydrationTasks.values { task.cancel() }
        contextHydrationTasks.removeAll()
        contextHydrationRevisions.removeAll()
        contextHydrationTokens.removeAll()
        contextHydrationWakeups.removeAll()
    }

    private func scheduleContextHydration(_ id: String, client: GatewayClient, store: LocalStore,
                                          origin: String, revision: UUID) {
        guard mayHydrateContext(origin: origin, revision: revision) else { return }
        let key = contextQueueKey(origin: origin, conversationID: id)
        contextHydrationWakeups[key] = UUID()
        if contextHydrationTasks[key] != nil, contextHydrationRevisions[key] == revision { return }
        contextHydrationTasks[key]?.cancel()
        let token = UUID()
        contextHydrationTokens[key] = token
        contextHydrationRevisions[key] = revision
        contextHydrationTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.contextHydrationTokens[key] == token {
                    self.contextHydrationTasks[key] = nil
                    self.contextHydrationTokens[key] = nil
                    self.contextHydrationRevisions[key] = nil
                    self.contextHydrationWakeups[key] = nil
                }
            }
            var failures = 0
            while !Task.isCancelled, self.mayHydrateContext(origin: origin, revision: revision) {
                let wakeup = self.contextHydrationWakeups[key]
                do {
                    let pending = try await self.contextOperation(key: key + "|marker") {
                        try await store.loadObject(key: "context-pending-" + id, as: PendingContextRefresh.self)
                    }
                    guard let pending, pending.isPending else {
                        if self.contextHydrationWakeups[key] != wakeup { continue }
                        return
                    }
                    let result = try await self.contextOperation(key: key) {
                        var refreshedPins = false, failed = false
                        var refreshedMessages = Set<String>()
                        try Task.checkCancellation()
                        guard self.mayHydrateContext(origin: origin, revision: revision) else { throw CancellationError() }
                        if pending.pins {
                            do {
                                _ = try await self.fetchContextPins(id, client: client, store: store, origin: origin, revision: revision)
                                refreshedPins = true
                            } catch {
                                try Task.checkCancellation()
                                self.recordDiagnostic(error, stage: "context-pins-refresh")
                                failed = true
                            }
                        }
                        for messageID in pending.messageIDs {
                            try Task.checkCancellation()
                            guard self.mayHydrateContext(origin: origin, revision: revision) else { throw CancellationError() }
                            do {
                                _ = try await self.fetchMessageTasks(messageID, conversationID: id, client: client,
                                                                    store: store, origin: origin, revision: revision)
                                refreshedMessages.insert(messageID)
                            } catch {
                                try Task.checkCancellation()
                                self.recordDiagnostic(error, stage: "context-tasks-refresh")
                                failed = true
                            }
                        }
                        return (pins: refreshedPins, messageIDs: refreshedMessages, failed: failed)
                    }
                    try Task.checkCancellation()
                    guard self.mayHydrateContext(origin: origin, revision: revision) else { return }
                    let remaining = try await self.contextOperation(key: key + "|marker") {
                        guard var current = try await store.loadObject(key: "context-pending-" + id, as: PendingContextRefresh.self) else { return false }
                        // Never clear a newer event's reconciliation work with an older GET.
                        if current.generation == pending.generation {
                            if result.pins { current.pins = false }
                            current.messageIDs.removeAll { result.messageIDs.contains($0) }
                            try await store.saveObject(key: "context-pending-" + id, value: current)
                        }
                        return current.isPending
                    }
                    if !remaining {
                        if self.contextHydrationWakeups[key] != wakeup { continue }
                        return
                    }
                    if !result.failed { failures = 0; continue }
                    failures += 1
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, self.mayHydrateContext(origin: origin, revision: revision) else { return }
                    self.recordDiagnostic(error, stage: "context-cache-refresh")
                    failures += 1
                }
                let delay = UInt64(min(1 << min(failures, 6), 60))
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            }
        }
    }

    private static func mayContainTasks(_ content: String) -> Bool {
        content.contains("[ ]") || content.contains("[x]") || content.contains("[X]")
    }

    func flushDraft() async {
        draftTask?.cancel(); draftTask = nil
        guard draftIsReady, let store else { return }
        let id = draftOwnerID
        let text = draft, attachments = pendingAttachments
        do {
            try await store.saveDraft(conversationID: id, text: text)
            try await store.saveObject(key: "attachments-" + id, value: attachments)
        } catch { show(error) }
    }

    private func scheduleDraftSave() {
        guard !restoringDraft, draftIsReady else { return }
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.flushDraft()
        }
    }
    private func restoreDraft(_ text: String) { restoringDraft = true; draft = text; restoringDraft = false }
    private func settleNavigationReadiness() {
        isReadyForNavigation = !startInProgress && connection != .connecting && draftIsReady
    }
    private func updateTransferProgress(_ amount: Double) { transferProgress = amount }
    private static func namespace(for credentials: GatewayCredentials) -> String {
        let identity = credentials.address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "|" + credentials.deviceID
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func openStore(for credentials: GatewayCredentials) throws {
        namespace = Self.namespace(for: credentials)
        store = try LocalStore(url: libraryURL.appendingPathComponent(namespace + ".sqlite3"))
        let saved = UserDefaults.standard.dictionary(forKey: seenLettersKey) as? [String: Double] ?? [:]
        seenLetters = saved.mapValues { Date(timeIntervalSince1970: $0) }
    }
    private var seenLettersKey: String { "hajisaki.seenLetters." + namespace }
    /// Stamped with the host's own times (letter, message or event) where known, so a device clock
    /// that runs a little behind the computer does not mark a letter you just read as new.
    func markSeen(_ id: String, at stamp: String? = nil) {
        seenLetters[id] = stamp.flatMap(Self.letterDate) ?? Date()
        UserDefaults.standard.set(seenLetters.mapValues(\.timeIntervalSince1970), forKey: seenLettersKey)
    }
    /// A letter she answered after you last looked at it on this iPad.
    func isUnread(_ conversation: Conversation) -> Bool {
        guard conversation.id != selectedConversationID, let seen = seenLetters[conversation.id],
              conversation.previewRole == "assistant", conversation.writing != true,
              let updated = Self.letterDate(conversation.updatedAt) else { return false }
        return updated > seen
    }
    private static func letterDate(_ value: String) -> Date? {
        // The host writes microseconds, which ISO8601DateFormatter does not reliably accept.
        ISO8601DateFormatter().date(from: value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    }
    private var writingWatch: Task<Void, Never>?
    /// While she is writing back in another letter, the list looks again every few seconds.
    private func watchWriting() {
        writingWatch?.cancel()
        guard isConnected, conversations.contains(where: { $0.writing == true && $0.id != selectedConversationID }) else { return }
        writingWatch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let writing = Set(self.conversations.filter { $0.writing == true }.map(\.id))
            await self.search()
            if self.conversations.contains(where: { writing.contains($0.id) && $0.writing != true && self.isUnread($0) }) {
                TheaterAudio.shared.play(.reply)
            }
        }
    }
    private func loadCachedLibrary() async throws {
        guard let store else { throw TheaterError.storage }
        let hostRevision = connectionRevision
        let cachedConversations = try await store.loadConversations()
        let cachedMemories = try await store.loadObject(key: "memories", as: [MemoryEntry].self) ?? []
        let cachedArtifacts = try await store.loadObject(key: "artifacts", as: [Artifact].self) ?? []
        let cachedSettings = try await store.loadObject(key: "settings", as: TheaterSettings.self) ?? TheaterSettings()
        let cachedSelection = try await store.loadObject(key: "selection", as: String.self)
        guard hostRevision == connectionRevision else { return }
        conversations = cachedConversations; memories = cachedMemories; artifacts = cachedArtifacts; settings = cachedSettings
        if let id = cachedSelection, let selected = conversations.first(where: { $0.id == id }) {
            await selectConversation(selected)
        } else {
            let text = try await store.draft(conversationID: "unsent")
            let cachedAttachments = try await store.loadObject(key: "attachments-unsent", as: [Artifact].self) ?? []
            guard hostRevision == connectionRevision else { return }
            pendingAttachments = cachedAttachments
            draftOwnerID = "unsent"; draftIsReady = true
            restoreDraft(text)
        }
        try await refreshPending()
    }
    private func normalizeModel() {
        if !models.contains(where: { $0.id == selectedModelID }), let first = models.first { selectedModelID = first.id }
        if !availableEfforts.contains(selectedEffort) { selectedEffort = availableEfforts.first ?? "medium" }
    }
    private func applyStatus(_ status: HostStatus) {
        providerName = status.provider.name; providerAuthenticated = status.provider.authenticated
        providerSimulated = status.provider.simulated ?? (status.provider.name == "development")
        capabilities = status.capabilities
    }
    private func applySnapshot(_ value: MessageSnapshot) {
        canonicalMessages = value.messages
        if value.activeRun?.id != activeRunID { replyStartedAt = value.activeRun == nil ? nil : Date() }
        currentRun = value.activeRun; activeRunID = value.activeRun?.id; cursor = value.cursor
        messages = value.messages
    }
    private func refreshPending() async throws {
        let originNamespace = namespace, revision = selectionRevision
        let queued = try await store?.loadOutbox() ?? []
        guard namespace == originNamespace, revision == selectionRevision else { return }
        pendingCount = queued.count
        messages = canonicalMessages + queued.filter { $0.conversationID == selectedConversationID }.map(\.optimisticMessage)
    }
    private func deliver(_ entry: OutboxEntry, client: GatewayClient) async throws {
        guard let destinationStore = store else { throw TheaterError.storage }
        let hostRevision = connectionRevision, origin = namespace
        let receipt = try await client.send(entry)
        let acceptedSnapshot = try await client.snapshot(entry.conversationID)
        try await reconcileContext(entry.conversationID, snapshot: acceptedSnapshot, client: client, store: destinationStore,
                                   origin: origin, revision: hostRevision)
        do {
            try await destinationStore.saveSnapshot(conversationID: entry.conversationID, snapshot: acceptedSnapshot)
        } catch LocalStoreError.staleSnapshot {
            // A live stream has already durably written a newer canonical snapshot.
        }
        if hostRevision == connectionRevision, entry.conversationID == selectedConversationID {
            if !canonicalMessages.contains(where: { $0.id == receipt.message.id }) { canonicalMessages.append(receipt.message) }
            activeRunID = receipt.runID
            eventTask?.cancel()
            let revision = UUID(); selectionRevision = revision
            try await syncSnapshot(entry.conversationID, client: client, revision: revision)
            if selectionRevision == revision { startStream(entry.conversationID, client: client, revision: revision) }
        }
        // An accepted send stays retryable until its canonical record is on disk.
        // Retrying the same client ID is safe even if the response was interrupted.
        try await destinationStore.markDelivered(clientID: entry.clientID)
        guard hostRevision == connectionRevision else { return }
        try await refreshPending()
        await search()
    }

    private func syncSnapshot(_ id: String, client: GatewayClient, revision: UUID) async throws {
        let hostRevision = connectionRevision, destinationStore = store, origin = namespace
        let snapshot = try await client.snapshot(id)
        guard selectionRevision == revision, selectedConversationID == id, hostRevision == connectionRevision else { return }
        let priorEvents = try await destinationStore?.loadEvents(conversationID: id) ?? []
        var after = priorEvents.last?.seq ?? 0
        var additions: [StreamEvent] = []
        while after < snapshot.cursor {
            let page = try await client.events(id, after: after)
            guard selectionRevision == revision, hostRevision == connectionRevision, !Task.isCancelled else { return }
            let eligible = page.events.filter { $0.seq <= snapshot.cursor }
            additions.append(contentsOf: eligible)
            guard let last = page.events.last, last.seq > after else { break }
            after = last.seq
            if !page.hasMore { break }
        }
        guard selectionRevision == revision, hostRevision == connectionRevision, let store = destinationStore else { return }
        // Forks can carry pins/tasks at cursor zero. Persist reconciliation work
        // before the cursor, then let optional HTTP hydration proceed independently.
        try await reconcileContext(id, snapshot: snapshot, client: client, store: store, origin: origin, revision: hostRevision)
        guard selectionRevision == revision, hostRevision == connectionRevision, !Task.isCancelled else { return }
        try await store.saveSnapshot(conversationID: id, snapshot: snapshot, events: additions)
        guard selectionRevision == revision, hostRevision == connectionRevision else { return }
        applySnapshot(snapshot)
        events = priorEvents + additions
        try await refreshPending()
    }

    private func startStream(_ id: String, client: GatewayClient, revision: UUID) {
        eventTask?.cancel()
        guard applicationActive, !userDisconnected, !authorizationNeedsReview else { eventTask = nil; return }
        let hostRevision = connectionRevision
        eventTask = Task { [weak self] in
            guard let self else { return }
            var attempts = 0
            while !Task.isCancelled, self.applicationActive, !self.userDisconnected, !self.authorizationNeedsReview,
                  self.selectionRevision == revision, self.connectionRevision == hostRevision {
                do {
                    let stream = await client.stream(id, after: self.cursor) { [weak self] in
                        await self?.streamDidConnect(conversationID: id, selection: revision, connection: hostRevision)
                    }
                    for try await event in stream {
                        guard !Task.isCancelled, self.selectionRevision == revision else { return }
                        try await self.consume(event, client: client, revision: revision)
                        attempts = 0
                    }
                    if !Task.isCancelled { throw TheaterError.disconnected }
                } catch {
                    guard !Task.isCancelled, self.selectionRevision == revision else { return }
                    self.recordDiagnostic(error, stage: "event-stream")
                    if Self.isAuthorizationError(error) {
                        self.authorizationNeedsReview = true
                        self.cancelConnectionRecovery()
                        self.connection = .failed
                        self.show(error, stage: "event-stream")
                        return
                    }
                    attempts += 1
                    // Try the normal durable poll route when a proxy buffers SSE.
                    do {
                        let page = try await client.events(id, after: self.cursor)
                        guard !Task.isCancelled, self.connectionRevision == hostRevision, self.selectionRevision == revision else { return }
                        for event in page.events { try await self.consume(event, client: client, revision: revision) }
                        guard !Task.isCancelled, self.connectionRevision == hostRevision, self.selectionRevision == revision else { return }
                        self.streamDidConnect(conversationID: id, selection: revision, connection: hostRevision, source: "event-replay")
                    } catch {
                        guard !Task.isCancelled, self.connectionRevision == hostRevision, self.selectionRevision == revision else { return }
                        self.connection = .failed
                        self.show(error, stage: "event-replay")
                        if Self.isAuthorizationError(error) {
                            self.authorizationNeedsReview = true
                            self.cancelConnectionRecovery()
                            return
                        }
                        if Self.isTransientConnectionError(error) { self.transientConnectionNoticeRevision = self.noticeRevision }
                    }
                    do { try await Task.sleep(nanoseconds: UInt64(min(1 << min(attempts, 4), 15)) * 1_000_000_000) } catch { return }
                }
            }
        }
    }

    private func consume(_ event: StreamEvent, client: GatewayClient, revision: UUID) async throws {
        guard !Task.isCancelled, event.conversationID == selectedConversationID, event.seq > cursor, selectionRevision == revision else { return }
        let hostRevision = connectionRevision, origin = namespace
        if event.kind == "artifact", let raw = event.payload["artifact"] {
            let data = try JSONEncoder().encode(raw)
            if let artifact = try? JSONDecoder().decode(Artifact.self, from: data) {
                let updated = try await store?.rememberArtifact(artifact) ?? artifacts
                guard !Task.isCancelled, selectionRevision == revision, hostRevision == connectionRevision else { return }
                artifacts = updated
            }
        }
        if event.kind == "message_created" || event.kind == "reminder" || (event.kind == "artifact" && currentRun?.id != event.runID) {
            try await syncSnapshot(event.conversationID, client: client, revision: revision)
            return
        }
        var updated = canonicalMessages
        var run = currentRun
        if event.kind == "reply_delta", let messageID = event.messageID {
            if let index = updated.firstIndex(where: { $0.id == messageID }) {
                updated[index].content += event.text; updated[index].status = "running"
            } else {
                updated.append(ChatMessage(id: messageID, conversationID: event.conversationID, role: "assistant", content: event.text,
                                           status: "running", createdAt: event.createdAt, attachments: []))
            }
        } else if event.kind == "run_started", let messageID = event.messageID {
            run = ActiveRun(id: event.runID, status: "running", assistantMessageID: messageID)
        } else if ["run_finished", "run_stopped", "run_failed"].contains(event.kind) {
            if let id = event.messageID, let index = updated.firstIndex(where: { $0.id == id }) {
                updated[index].status = event.payload["status"]?.stringValue ?? "completed"
            }
            if run?.id == event.runID { run = nil }
        } else if event.layer == "L4", let raw = event.payload["artifact"] {
            let data = try JSONEncoder().encode(raw)
            if let artifact = try? JSONDecoder().decode(Artifact.self, from: data), event.kind == "artifact" {
                if let id = run?.assistantMessageID, let index = updated.firstIndex(where: { $0.id == id }),
                   !updated[index].artifactIDs.contains(artifact.id) { updated[index].attachments.append(.artifact(artifact)) }
            }
        }
        let snapshot = MessageSnapshot(messages: updated, activeRun: run, cursor: event.seq)
        guard let store else { throw TheaterError.storage }
        let taskMessageID = event.payload["message_id"]?.stringValue
        let isTaskChange = event.kind == "widget_updated" && event.payload["kind"]?.stringValue == "task"
        let finishedTaskMessage = ["run_finished", "run_stopped", "run_failed"].contains(event.kind)
            && updated.contains(where: { $0.id == taskMessageID && Self.mayContainTasks($0.content) })
        let finishedPinnedMessage = ["run_finished", "run_stopped", "run_failed"].contains(event.kind)
            && contextPins.contains(where: { $0.kind == .message && $0.targetID == taskMessageID })
        if event.kind == "pins_changed" || isTaskChange || finishedTaskMessage || finishedPinnedMessage {
            let messageIDs = (isTaskChange || finishedTaskMessage) ? taskMessageID.map { [$0] } ?? [] : []
            try await deferContextRefresh(event.conversationID, pins: event.kind == "pins_changed" || finishedPinnedMessage,
                                          messageIDs: messageIDs, through: event.seq, client: client, store: store,
                                          origin: origin, revision: hostRevision)
        }
        guard !Task.isCancelled, selectionRevision == revision, hostRevision == connectionRevision else { return }
        try await store.saveSnapshot(conversationID: event.conversationID, snapshot: snapshot, events: [event])
        guard !Task.isCancelled, selectionRevision == revision, hostRevision == connectionRevision else { return }
        applySnapshot(snapshot); events.append(event); connection = .connected
        if event.kind == "card_updated", let id = event.payload["artifact_id"]?.stringValue,
           let artifact = artifacts.first(where: { $0.id == id }),
           interactiveCards[event.conversationID + "|" + id] != nil {
            Task { await self.loadInteractiveCard(artifact, conversationID: event.conversationID) }
        }
        try await refreshPending()
        if event.kind == "run_failed", let text = event.payload["message"]?.stringValue { notice = text }
        if ["run_finished", "run_stopped", "run_failed"].contains(event.kind) {
            markSeen(event.conversationID, at: event.createdAt)
            if event.kind == "run_finished", let id = event.messageID {
                justSealedMessageID = id
                if let reply = canonicalMessages.first(where: { $0.id == id }), reply.content.count > 900 {
                    say(CompanionMood.longReplyLine(settings))
                }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                    if self?.justSealedMessageID == id { self?.justSealedMessageID = nil }
                }
            }
            Task { await self.search() }
        }
    }

    private func streamDidConnect(conversationID: String, selection: UUID, connection: UUID, source: String = "event-stream") {
        guard selectedConversationID == conversationID, selectionRevision == selection,
              connectionRevision == connection, gateway != nil else { return }
        self.connection = .connected
        Self.logger.info("Transport ready stage=\(source, privacy: .public)")
        clearRecoveredTransportNotice()
    }

    private func clearRecoveredTransportNotice() {
        if transientConnectionNoticeRevision == noticeRevision { notice = nil }
        transientConnectionNoticeRevision = nil
    }

    private static func isTransientConnectionError(_ error: Error) -> Bool {
        if let network = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
                    .internationalRoamingOff, .callIsActive, .dataNotAllowed].contains(network.code)
        }
        if let problem = error as? TheaterError {
            switch problem {
            case .disconnected: return true
            case .server(let status, _): return [408, 429, 500, 502, 503, 504].contains(status)
            default: break
            }
        }
        return false
    }

    private static func isAuthorizationError(_ error: Error) -> Bool {
        if let problem = error as? TheaterError {
            switch problem {
            case .address, .pairing: return true
            case .server(let status, _): return status == 401 || status == 403
            default: break
            }
        }
        if let network = error as? URLError {
            return [.userAuthenticationRequired, .userCancelledAuthentication, .appTransportSecurityRequiresSecureConnection,
                    .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                    .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired].contains(network.code)
        }
        return false
    }

    /// Only fixed categories and numeric codes enter diagnostic logs. Never log
    /// localized descriptions, NSError.userInfo, URLs, request bodies or credentials.
    private func recordDiagnostic(_ error: Error, stage: String) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        let native = error as NSError
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let domain = native.domain.count <= 100 && native.domain.unicodeScalars.allSatisfy({ permitted.contains($0) })
            ? native.domain : "custom-error-domain"
        var category = "other", status = 0
        if let problem = error as? TheaterError {
            switch problem {
            case .address: category = "address"
            case .pairing: category = "pairing"
            case .server(let code, _): category = "server"; status = code
            case .invalidResponse: category = "invalid-response"
            case .storage: category = "storage"
            case .integrity: category = "integrity"
            case .disconnected: category = "disconnected"
            }
        } else if error is URLError { category = "url-loading" }
        else if error is LocalStoreError { category = "local-store" }
        Self.logger.error("Failure stage=\(stage, privacy: .public) domain=\(domain, privacy: .public) code=\(native.code, privacy: .public) category=\(category, privacy: .public) httpStatus=\(status, privacy: .public)")
    }

    private func show(_ error: Error, stage: String = "operation") {
        if error is CancellationError { return }
        recordDiagnostic(error, stage: stage)
        if let value = error as? LocalizedError, let text = value.errorDescription, error is TheaterError || error is LocalStoreError {
            notice = text
        } else if let network = error as? URLError, network.code == .cancelled { return }
        else { notice = "这条小路暂时没接通。已写下的内容还在，稍后可以重新接续。" }
    }
    private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}
