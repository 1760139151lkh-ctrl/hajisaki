# Native iPad model / view contract

`ipad/App/Sources/Core/` owns the following Swift types. Target: iPadOS 18+, Swift 5 language mode. The app supplies one `@StateObject var model = TheaterModel()` and calls `await model.start()` once.

## TheaterModel (`@MainActor ObservableObject`)

Published readable state: `conversations: [Conversation]`, `selectedConversationID: String?`, `messages: [ChatMessage]`, `events: [StreamEvent]`, `models: [GatewayModel]`, `memories: [MemoryEntry]`, `artifacts: [Artifact]`, `settings: TheaterSettings`, `connection: ConnectionState`, `notice: String?`, `activeRunID: String?`, `isBusy: Bool`, `pendingCount: Int`, `transferProgress: Double?`.

Published editable bindings: `draft: String` (persisted when it changes), `searchText: String`, `selectedGroup: String` (empty = all), `selectedModelID: String` (default `default` until actual catalogue loads), `selectedEffort: String` (`medium`), `hostAddress: String` (default `https://`), `deviceID: String`. Token is supplied only to `connect(token:)`; it must not be stored in view preferences.

Computed: `selectedConversation: Conversation?`, `isConnected: Bool`, `isGenerating: Bool`, `providerName: String`, `connectionLabel: String`, `availableEfforts: [String]`.

Async actions (Task wrappers from views): `start()`, `connect(token: String)`, `reconnect()`, `refresh()`, `search()`, `selectConversation(_ conversation: Conversation)`, `createConversation(title: String = "新的乐章", group: String = "专属日常")`, `send()`, `stop()`, `retryPending()`, `togglePin(_ conversation: Conversation)`, `fork(from message: ChatMessage)`, `saveMemory(content: String, id: String? = nil)`, `removeMemory(_ memory: MemoryEntry)`, `saveSettings(_ value: TheaterSettings)`, `upload(fileURL: URL) -> Artifact?`, `download(_ artifact: Artifact) -> URL?`, `exportLibrary() -> URL?`.

Sync actions: `disconnect()` (cancels listeners, keeps cache and credentials), `quote(_ message: ChatMessage)` (adds a quotation to draft), `attach(_ artifact: Artifact)` for an immediate selection, and `removeAttachment(id: String)`. `pendingAttachments: [Artifact]` is published. File import/Pencil image export uses the scoped async attachment action below. No artificial chat or AI replies are injected.

For an asynchronous upload, capture the originating conversation ID before awaiting, then use `await attach(artifact, to: capturedID)`; `nil` is the unsent draft. `flushDraft()` is async and should run when the scene leaves the active state. Composer controls are disabled while `isBusy` protects a conversation transition. `providerSimulated`, `providerAuthenticated`, and `capabilities` expose the host's actual capability state.

`ConnectionState` cases `.offline`, `.connecting`, `.connected`, `.failed`. Errors arrive in `notice` as Chinese user-facing text; credentials are never embedded.

## Data objects

- `Conversation: Identifiable, Codable, Equatable`: `id,title,group: String`, `pinned,archived: Bool`, `updatedAt: String`, `preview: String?`.
- `ChatMessage: Identifiable, Codable, Equatable`: `id,conversationID,role,content,status,createdAt: String`, `attachments: [ArtifactReference]`; `isUser: Bool`; `artifactIDs: [String]`.
- `ArtifactReference`: `.id(String)` / `.artifact(Artifact)` with `id: String`, `artifact: Artifact?`.
- `Artifact: Identifiable, Codable, Equatable`: `id,name,mime,sha256,url: String`, `size: Int64`.
- `GatewayModel: Identifiable, Codable, Equatable`: `id,name: String`, `efforts: [String]`.
- `MemoryEntry: Identifiable, Codable, Equatable`: `id,content,createdAt,updatedAt: String`.
- `StreamEvent: Identifiable, Codable, Equatable`: `seq: Int64`, `id: Int64` (seq), `conversationID,runID,layer,kind,createdAt: String`, `payload: [String: JSONValue]`; `text: String`, `messageID: String?`.
- `JSONValue`: Codable/Equatable enum, accessors `.stringValue`, `.objectValue`, `.boolValue`, `.intValue`.
- `TheaterSettings: Codable, Equatable`: `theme: String` (`auto/night/day`), `transparency: String` (`companion/balanced/studio`), `personality: Personality`, `sound: Bool`. Defaults: auto/balanced/65,50,25/false.
- `Personality: Codable, Equatable`: `formality,detail,teasing: Int` (0...100).

Core owns no view layout, Pencil, PDF, audio, widget, or Metal code. SQLite stores canonical messages and event cursor atomically. Events are public summaries/tool metadata/replies/artifacts, never hidden model chain of thought.

## SpotlightLibrary (`@MainActor`)

`Platform/SpotlightLibrary.swift` supplies these static methods:

```swift
SpotlightLibrary.index(conversation: Conversation, messages: [ChatMessage], artifacts: [Artifact], scope: String)
SpotlightLibrary.conversationID(from: NSUserActivity, scope: String) -> String?
SpotlightLibrary.conversationID(from: URL, scope: String) -> String?
```

Pass `model.libraryScope`, the read-only nonsecret storage namespace, rather than the editable host address or any credential. `index` returns immediately and hands metadata preparation to a separate actor. It coalesces changes for 500 ms, skips unchanged indexable content, and submits batches of 64 through the asynchronous Core Spotlight API. A named `HajiSakiLibrary` index uses `.complete` data protection. Temporary submission failures retain the latest snapshot and retry with a bounded delay; logs contain only a generic failure message, not content, IDs, paths or credentials.

The index includes the conversation title, completed assistant replies, and metadata for files actually attached to that conversation. It does not index user drafts, pending/streaming replies, tool logs, the unrelated global file cabinet, or the contents of PDF originals. PDF file entries use the `.pdf` content type; replies use `.text`. The complete supplied reply text is indexed; only its displayed summary is shortened. This is on-device search metadata, not a guarantee that every historical conversation has already been visited or indexed.

The unique identifier is a route of the form `hajisaki://conversation/<id>?scope=<SHA256(scope)>&item=<kind-id>`. Core Spotlight returns it under `CSSearchableItemActivityIdentifier` in `CSSearchableItemActionType` activities. The parser validates the scheme, conversation ID and current scope. The app also routes matching `.onOpenURL` events and registers only the `hajisaki` scheme. `contentURL` is not populated: Apple defines it as the content's file URL, and this module does not disclose local filesystem paths. Root app integration must retain a pending route until `model.start()` has restored the library, then resolve the conversation before selecting it.

Groups containing 私密, 隐私, 隱私, 保险箱, 保險箱, private or vault are excluded. Calling `index` for such a conversation withdraws its previous derived search entries while preserving original records/files. Call it on group changes as well as message changes; after a complete conversation-list refresh, pass excluded conversations even if they are not selected. Data protection and exclusion do not imply a Touch ID vault is implemented. Ordinary calls never request location or change application permissions.

The implementation follows Apple's [indexing API](https://developer.apple.com/documentation/corespotlight/cssearchableindex/indexsearchableitems(_:completionhandler:)), [protected named indexes](https://developer.apple.com/documentation/corespotlight/cssearchableindex/init(name:protectionclass:)), and [activity identifier](https://developer.apple.com/documentation/corespotlight/cssearchableitemactivityidentifier). Code and metadata contracts were inspected; compilation, real Spotlight results, private-group withdrawal and launch continuation still require the integrated app's verification. Successful indexing callbacks mean the operation was journaled, not that a result has already appeared on screen.

## Speech transcription

`requestTranscription(for: Artifact, language: String? = nil, conversationID: String? = nil) async -> SpeechJob?` submits the existing audio artifact with `cleanup: false`; pass the captured destination conversation (`nil` for unsent). The returned `clientConversationID` preserves that destination across reopening and refresh. Submission is never automatically repeated. `refreshTranscription(_:)` and `stopTranscription(_:)` return updated typed jobs. `cleanTranscript(text:) async -> String?` is explicit conservative filler removal; the original audio and original text are retained.

`SpeechJob` contains `id`, `status`, `artifactID`, `originalText`, `text`, `segments`, `uncertainSpans`, `dictionarySuggestions`, `originalAudio`, `progress`, optional `detail/provider/language/languageProbability/durationSeconds/createdAt/cleanup/capabilities`, and a client-only host context ID. `isTerminal` and `isCompleted` reflect actual statuses. Initial queued jobs can legitimately omit provider/capabilities/duration. Progress is a processed segment count and audio timestamp, not an invented percentage.

`SpeechSegment` has `index/text/start/end/avgLogprob/noSpeechProbability/words`; timestamps and scores can be nil. `SpeechUncertainSpan` has the actual text, score, segment index, audio interval, Unicode scalar character interval, and provider candidate array. The current provider supplies **no acoustic Top-3 alternatives**. Dictionary suggestions are explicitly user-dictionary replacements and must not be presented as acoustic alternatives. `utf16Range(in:)` converts the host's `original_text_unicode_codepoints` offsets for UIKit; do not use Swift Character indices against those offsets, or apply them after the transcript has been edited.

`readHotwords() async -> [SpeechHotword]?` and `saveHotwords(_:) async -> [SpeechHotword]?` use `{term,aliases}`. Host validation remains authoritative. `recentTranscriptions()` reads this host's durable local jobs. `transcriptDraft(for:)` returns a saved edit or the original current job text; `saveTranscriptDraft(_:for:)` saves only the edit. `appendTranscript(_:from:to:)` appends reviewed text to the captured conversation draft (`nil` means unsent) and never sends it automatically or removes the audio attachment.

Views capture the originating conversation before upload, attach the original with `attach(_:to:)`, then request transcription. Polling a known job is safe; closing a sheet does not stop a host job. Only an explicit stop action calls `stopTranscription`. Every speech operation captures its gateway/store context; a result from an earlier host is saved only in that host's database and cannot update the newly paired host's UI.
