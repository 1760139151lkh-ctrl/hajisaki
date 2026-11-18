import SwiftUI
import UniformTypeIdentifiers
import UIKit
import CoreSpotlight

private enum TheaterSheet: String, Identifiable {
    case connection, settings, memories, media, search, sidebar, inspector, voice, transcription, pins, models, rename, pencilCaptures
    var id: String { rawValue }
}
private enum InspectorMode: String, CaseIterable { case portrait = "琴房", scratchpad = "草稿", document = "卷宗" }

@MainActor struct TheaterDocument: Identifiable {
    let id = UUID()
    var url: URL
    var title: String
    var page: Int?
    var line: Int? = nil
    var endLine: Int? = nil
    var softLight = false
    var fileSHA256: String? = nil
    let interactiveSession = InteractiveDocumentSession()
    let markdownSession = MarkdownDocumentSession()
}

private struct PendingImport {
    var url: URL
    var conversationID: String?
    var libraryScope: String
}

struct TheaterRootView: View {
    @ObservedObject var model: TheaterModel
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var pencil = TheaterPencilController()
    @State private var showSidebar = true
    @State private var showInspector = true
    @State private var sheet: TheaterSheet?
    @State private var inspectorMode: InspectorMode = .portrait
    @State private var document: TheaterDocument?
    @State private var importPresented = false
    @State private var previewRequestID = UUID()
    @State private var openingArtifact: Artifact?
    @State private var toolDetail: StreamEvent?
    @State private var width: CGFloat = 1180
    @State private var dropHighlighted = false
    @State private var importQueue: [PendingImport] = []
    @State private var drainingImports = false
    @State private var voiceDestinationID: String?
    @State private var voiceDestinationScope = ""
    @State private var sheetAfterDismissal: TheaterSheet?
    @StateObject private var voiceReview = VoiceReviewDraft()
    @ObservedObject private var audio = TheaterAudio.shared
    @AppStorage("hajisaki.ambience") private var ambienceEnabled = false
    @State private var pendingSearchURL: URL?
    @State private var pendingSearchActivity: NSUserActivity?
    @State private var openingSearchResult = false
    @State private var renamingConversation: Conversation?
    @State private var conversationTitle = ""
    @State private var showMainActions = false
    @State private var afterMainActions: (() -> Void)?
    @State private var teaPreference: Bool? = nil
    @State private var moodMoment: String?
    /// Days since your last letter when this session began, for "好久不见" (counted once).
    @State private var awayDays: Int?
    /// Taps on her portrait in a row, and the line she answers with.
    @State private var pokes = 0
    @State private var pokeLine: String?
    @State private var pokeTask: Task<Void, Never>?
    /// Where the last tap landed: her small portrait in the top bar, or the window on the stage.
    @State private var pokedStage = false
    /// While you are writing to her, the header says she is waiting.
    @State private var composing = false
    @State private var composingTask: Task<Void, Never>?

    private var palette: TheaterPalette {
        TheaterPalette(isDark: model.settings.theme == "night" || (model.settings.theme == "auto" && systemScheme == .dark))
    }
    private var isWide: Bool { width >= 1024 }
    /// Saki's current face: thinking while she writes, relieved after a reply, sleepy at dawn.
    private var mood: String {
        CompanionMood.portrait(generating: model.isGenerating, group: model.selectedConversation?.group,
                               connected: model.isConnected, paired: !model.deviceID.isEmpty, moment: moodMoment)
    }
    private var preferredScheme: ColorScheme? {
        model.settings.theme == "night" ? .dark : model.settings.theme == "day" ? .light : nil
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 1024 && showSidebar {
                    sidebar.frame(width: min(270, max(218, geometry.size.width * 0.2)))
                    Rectangle().fill(palette.line).frame(width: 0.5)
                }
                VStack(spacing: 0) {
                    topBar.zIndex(2)
                    TheaterRule()
                    ConversationStage(model: model,
                                      onOpenConnection: { sheet = .connection },
                                      onImport: { importPresented = true },
                                      onScratchpad: { openInspector(.scratchpad) },
                                      onVoice: openVoice,
                                      onPins: { sheet = .pins },
                                      onModels: { sheet = .models },
                                      onArtifact: openArtifact,
                                      onTranscribe: transcribeArtifact,
                                      onTool: { event in toolDetail = event; openInspector(.document) },
                                      onOpenSource: openSource,
                                      pencilInteractionRevision: pencil.interactionRevision,
                                      onPreview: { pencil.showPreview($0) },
                                      portrait: mood)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) { keepsake }
                    .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.keepsakeLine)
                if geometry.size.width >= 1024 && showInspector {
                    Rectangle().fill(palette.line).frame(width: 0.5)
                    inspector.frame(width: min(540, geometry.size.width * (inspectorMode == .portrait ? 0.32 : 0.38)))
                }
            }
            .background(palette.background)
            .foregroundStyle(palette.text)
            .onAppear { width = geometry.size.width }
            .onChange(of: geometry.size.width) { oldValue, newValue in
                width = newValue
                if newValue >= 1024 && oldValue < 1024 && (sheet == .sidebar || sheet == .inspector) { sheet = nil }
            }
        }
        .environment(\.theaterPalette, palette)
        .tint(palette.rose)
        .preferredColorScheme(preferredScheme)
        .onChange(of: model.draft) { old, new in
            if old != new && !new.isEmpty { teaPreference = nil }
            composingTask?.cancel()
            composing = !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if composing {
                composingTask = Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if !Task.isCancelled { composing = false } }
            }
        }
        .onChange(of: model.connection) { old, new in
            if old == .failed && new == .connected { model.say("……灯亮了。欢迎回来。") }
        }
        .onChange(of: model.conversations) { _, list in
            guard awayDays == nil, model.isConnected, !list.isEmpty else { return }
            let latest = list.compactMap { hostDate($0.updatedAt) }.max() ?? .now
            awayDays = Int(Date().timeIntervalSince(latest) / 86_400)
        }
        .task(id: model.searchText) {
            do { try await Task.sleep(for: .milliseconds(250)); await model.search() } catch { }
        }
        .sheet(item: $sheet, onDismiss: {
            if let next = sheetAfterDismissal { sheetAfterDismissal = nil; sheet = next }
        }) { selected in
            sheetContent(selected)
                .environment(\.theaterPalette, palette)
                .tint(palette.rose)
                .preferredColorScheme(preferredScheme)
                .presentationBackground(palette.background)
        }
        .fileImporter(isPresented: $importPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure: model.notice = "这份文件暂时未能打开，原件还在。"
            }
        }
        .background(keyboardActions)
        .background(TheaterPencilBridge(controller: pencil, scope: model.libraryScope,
                                       conversationID: model.selectedConversationID,
                                       contentContext: "\(Int(width.rounded()))|\(showSidebar)|\(showInspector)|\(inspectorMode.rawValue)|\(document?.id.uuidString ?? "")|\(document?.page ?? 0)",
                                       active: scenePhase == .active && (sheet == nil || sheet == .inspector) && !importPresented,
                                       palette: palette, onCommand: performPencilCommand, onCapture: attachPencilCapture))
        .onChange(of: pencil.notice) { _, notice in if let notice { model.notice = notice } }
        .overlay {
            if dropHighlighted {
                RoundedRectangle(cornerRadius: 22).stroke(palette.rose, style: StrokeStyle(lineWidth: 2, dash: [7, 5])).padding(7)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.pdf.identifier, UTType.image.identifier, UTType.text.identifier], isTargeted: $dropHighlighted, perform: receiveDrop)
        .onOpenURL { url in
            if url.isFileURL { importFiles([url]) }
            else if url.scheme == "hajisaki" {
                if url.host == "artifact" { _ = openSource(url) }
                else { pendingSearchURL = url; openPendingSearchResult() }
            }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            pendingSearchActivity = activity
            openPendingSearchResult()
        }
        .onChange(of: model.messages) { old, current in
            indexCurrentConversation()
            if let last = current.last, last.role == "assistant", last.status == "completed",
               let previous = old.first(where: { $0.id == last.id }),
               previous.status != "completed" && previous.status != "stopped" {
                audio.play(.reply)
                celebrateReply()
            }
        }
        .onChange(of: model.selectedConversation) { _, _ in indexCurrentConversation() }
        .onChange(of: model.conversations) { _, _ in
            SpotlightLibrary.withdrawPrivateConversations(model.conversations, scope: model.libraryScope)
            openPendingSearchResult()
        }
        .onChange(of: model.libraryScope) { _, _ in
            previewRequestID = UUID(); openingArtifact = nil; document = nil; toolDetail = nil
            if inspectorMode == .document { inspectorMode = .portrait }
            openPendingSearchResult()
        }
        .onChange(of: model.isReadyForNavigation) { _, ready in if ready { openPendingSearchResult() } }
        .onAppear { configureAudio() }
        .onChange(of: model.settings.sound) { _, _ in configureAudio() }
        .onChange(of: ambienceEnabled) { _, _ in configureAudio() }
        .onChange(of: model.selectedEffort) { old, value in
            if old != value && model.isReadyForNavigation { audio.play(.effort) }
        }
    }

    private func celebrateReply() {
        moodMoment = "happy_achieved"
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if moodMoment == "happy_achieved" { moodMoment = nil }
        }
    }

    private func configureAudio() {
        audio.configure(effectsEnabled: model.settings.sound, ambienceEnabled: ambienceEnabled)
    }

    private func indexCurrentConversation() {
        guard let conversation = model.selectedConversation else { return }
        SpotlightLibrary.index(conversation: conversation, messages: model.messages, artifacts: model.artifacts, scope: model.libraryScope)
    }

    private func openPendingSearchResult() {
        guard !openingSearchResult, model.isReadyForNavigation, model.libraryScope != "unpaired" else { return }
        let scope = model.libraryScope
        let identifier = pendingSearchURL.flatMap { SpotlightLibrary.conversationID(from: $0, scope: scope) }
            ?? pendingSearchActivity.flatMap { SpotlightLibrary.conversationID(from: $0, scope: scope) }
        guard let identifier else { return }
        openingSearchResult = true
        Task {
            defer { openingSearchResult = false }
            model.searchText = ""; model.selectedGroup = ""
            await model.search()
            guard scope == model.libraryScope else { return }
            guard let conversation = model.conversations.first(where: { $0.id == identifier }) else { return }
            sheet = nil
            await model.selectConversation(conversation)
            if model.selectedConversationID == identifier && model.libraryScope == scope {
                pendingSearchURL = nil; pendingSearchActivity = nil
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            GlyphButton(label: showSidebar && isWide ? "收起名录" : "打开名录", glyph: .sidebar, active: showSidebar && isWide) { toggleSidebar() }
            Button { pokedStage = false; poke() } label: {
                CameoPortrait(image: mood, size: 34, online: (isWide && showSidebar) ? nil : model.isConnected)
                    .overlay(alignment: .top) { if pokeLine != nil { SealBurst().id(pokes) } }
            }.buttonStyle(.plain).padding(.horizontal, 4).accessibilityLabel("轻轻叫她一声")
                .overlay(alignment: .topLeading) { if !pokedStage { pokeBubble.offset(x: 6, y: 44) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedConversation?.title ?? "哈基祥").font(.theaterSerif(17)).tracking(0.5).lineLimit(1)
                HStack(spacing: 5) {
                    if model.isGenerating {
                        HeartMark(size: 8)
                        Text(replyStatus)
                    } else if composing && model.isConnected && model.selectedConversation != nil {
                        TheaterGlyph(kind: .quill).stroke(lineWidth: 1.1).frame(width: 11, height: 11)
                        Text(CompanionMood.composingLine(model.settings))
                    } else if model.selectedConversation != nil {
                        Text(model.isConnected ? "祥子 · 在你身边" : "琴房的灯暂时熄了 · 草稿会替你留着")
                    } else {
                        Text(model.isConnected ? "琴房灯亮着" : model.connectionLabel)
                    }
                }.font(.system(size: 12)).foregroundStyle(model.isGenerating ? palette.rose : palette.dim).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            GlyphButton(label: "搜索记忆与对话", glyph: .search) { sheet = .search }
            GlyphButton(label: "打开共创台", glyph: .book, active: showInspector && isWide) {
                if isWide { animate { showInspector.toggle() } } else { sheet = .inspector }
            }
            GlyphButton(label: pencil.captureArmed ? "收起圈画" : "怀表指令环", glyph: .watch, active: pencil.captureArmed) {
                if pencil.captureArmed { pencil.cancelCapture() } else { pencil.presentRing() }
            }
            Button { showMainActions.toggle() } label: {
                TheaterGlyph(kind: .more).stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round)).frame(width: 22, height: 22)
                    .frame(width: 44, height: 44).foregroundStyle(palette.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("更多操作")
            .popover(isPresented: $showMainActions) {
                TheaterPopup {
                Button("新的乐章") { finishMainActions { Task { await model.createConversation() } } }
                if let conversation = model.selectedConversation {
                    Button("重命名乐章") { finishMainActions { beginRename(conversation) } }.disabled(!model.isConnected)
                }
                Button("记忆星空") { finishMainActions { sheet = .memories } }
                Button("固定的上下文") { finishMainActions { sheet = .pins } }
                Button("共享文件柜") { finishMainActions { sheet = .media } }
                Button("圈画手稿") { finishMainActions { sheet = .pencilCaptures } }
                Button("琴房设置") { finishMainActions { sheet = .settings } }
                Button("连接电脑") { finishMainActions { sheet = .connection } }
                if audio.isSpeaking { Button("停止朗读") { finishMainActions { audio.stopSpeech() } } }
                if model.settings.sound || ambienceEnabled || audio.isSpeaking {
                    Button("立即静音") {
                        showMainActions = false
                        audio.stopAll(); ambienceEnabled = false
                        var settings = model.settings; settings.sound = false
                        Task { await model.saveSettings(settings) }
                    }
                }
                }.environment(\.theaterPalette, palette)
                    .onDisappear {
                        let action = afterMainActions; afterMainActions = nil
                        action?()
                    }
            }
        }.padding(.horizontal, 10).frame(height: 68).background(palette.background)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SakiSeal(size: 30)
                Text("哈基祥").font(.theaterSerif(20)).tracking(2).lineLimit(1)
                Spacer(minLength: 0)
                GlyphButton(label: "琴房设置", glyph: .settings) { sheet = .settings }
            }.padding(.leading, 20).padding(.trailing, 8).padding(.top, 16).padding(.bottom, 14)
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 4) {
                    HandwrittenScript(text: awayDays.flatMap { CompanionMood.reunion(daysAway: $0, settings: model.settings) } != nil
                                      ? "Welcome back" : CompanionMood.salutation(context.date, settings: model.settings), size: 26)
                    Text(awayDays.flatMap { CompanionMood.reunion(daysAway: $0, settings: model.settings) }
                         ?? CompanionMood.greeting(context.date, settings: model.settings)).font(.theaterSerif(16)).lineSpacing(4)
                        .foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 7) {
                        Text(CompanionMood.dateLine(context.date))
                        Circle().fill(model.isConnected ? palette.online : palette.dim).frame(width: 5, height: 5)
                    }.font(.system(size: 12)).foregroundStyle(palette.dim).padding(.top, 4)
                    if let days = togetherDays {
                        HStack(spacing: 4) {
                            HeartShape().fill(palette.rose).frame(width: 8, height: 7.4)
                            Text("相识第 \(days) 天")
                        }.font(.system(size: 12)).foregroundStyle(palette.rose)
                    }
                }
            }.padding(.horizontal, 20)
            Button { Task { await model.createConversation(); if !isWide { sheet = nil } } } label: {
                HStack(spacing: 8) {
                    Text("写信给祥子…").font(.system(size: 14)).foregroundStyle(palette.dim)
                    Spacer(minLength: 0)
                    WaxHeart(size: 32)
                }.padding(.leading, 14).padding(.trailing, 7).frame(height: 48)
                    .letterCard(cornerRadius: 16)
                    .contentShape(Rectangle())
            }.buttonStyle(SatinPressStyle()).accessibilityLabel("写一封新的信").padding(.horizontal, 16).padding(.top, 16)
            HStack(spacing: 7) {
                TheaterGlyph(kind: .search).stroke(lineWidth: 1.3).frame(width: 15, height: 15)
                TextField("寻找一段回忆", text: $model.searchText).font(.system(size: 14)).textInputAutocapitalization(.never)
                    .foregroundStyle(palette.text)
                if !model.searchText.isEmpty { GlyphButton(label: "清除搜索", glyph: .close) { model.searchText = "" }.frame(width: 30, height: 30) }
            }.foregroundStyle(palette.dim).padding(.horizontal, 12).frame(height: 38)
                .background(palette.sunken, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16).padding(.top, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    groupButton("全部", value: "")
                    ForEach(groups, id: \.self) { group in groupButton(groupLabel(group), value: group) }
                }.padding(.horizontal, 20)
            }.padding(.top, 4)
            TheaterRule().padding(.horizontal, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.conversations.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            if !model.searchText.isEmpty {
                                // She went looking in the rain, under the streetlamp.
                                Image("search_streetlamp").resizable().scaledToFill().frame(width: 112, height: 148)
                                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 56, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 56))
                                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 56, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 56)
                                        .stroke(palette.goldLine, lineWidth: 1))
                                    .accessibilityLabel("雨夜里，祥子站在路灯下")
                                Text("我在路灯下找了一圈……\n还没找到「\(model.searchText)」。").font(.theaterSerif(14)).lineSpacing(4).foregroundStyle(palette.secondary)
                                Button("看看全部信笺") { model.searchText = ""; model.selectedGroup = ""; Task { await model.search() } }
                                    .font(.system(size: 14)).foregroundStyle(palette.rose)
                            } else if !model.selectedGroup.isEmpty {
                                Text("这一册还空着。写一封放进来吧？").font(.system(size: 14)).foregroundStyle(palette.secondary)
                                Button("看看全部信笺") { model.searchText = ""; model.selectedGroup = ""; Task { await model.search() } }
                                    .font(.system(size: 14)).foregroundStyle(palette.rose)
                            } else if !model.isReadyForNavigation {
                                HStack(spacing: 8) {
                                    TypingHearts()
                                    Text("正在取回信笺…").font(.theaterSerif(14)).foregroundStyle(palette.secondary)
                                }
                            } else {
                                // The very first time: she introduces herself.
                                ScriptLine(text: "Nice to meet you", size: 20)
                                Text("初次见面。").font(.theaterSerif(16)).foregroundStyle(palette.text)
                                Text("我是丰川祥子。以后想说的话，都写信给我吧。").font(.system(size: 13)).lineSpacing(3)
                                    .foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 18)
                    }
                    ForEach(model.conversations) { conversation in
                        conversationRow(conversation)
                    }
                }.padding(.horizontal, 8).padding(.vertical, 8)
            }
            TheaterRule()
            // Fits the 238 pt sidebar of an 11-inch iPad in landscape; only the status text may truncate.
            HStack(spacing: 0) {
                sideDestination("记忆", glyph: .sparkle) { sheet = .memories }
                sideDestination("文件柜", glyph: .book) { sheet = .media }
                Spacer(minLength: 0)
                Button { sheet = .connection } label: {
                    HStack(spacing: 6) {
                        Circle().fill(model.isConnected ? palette.online : palette.dim).frame(width: 6, height: 6)
                        Text(model.isConnected ? "灯亮着" : model.connectionLabel).font(.system(size: 12)).lineLimit(1)
                    }.foregroundStyle(palette.secondary).padding(.horizontal, 8).frame(minHeight: 40).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(model.isConnected ? "琴房灯亮着，查看连接" : "连接电脑")
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }.background { palette.sidebar.ignoresSafeArea() }.frame(maxHeight: .infinity)
    }

    private var groups: [String] {
        let defaults = ["专属日常", "代码工坊", "文献卷宗"]
        return defaults + Set(model.conversations.map(\.group)).filter { !$0.isEmpty && !defaults.contains($0) }.sorted()
    }
    private func groupLabel(_ group: String) -> String {
        ["专属日常": "日常", "代码工坊": "工坊", "文献卷宗": "卷宗"][group] ?? group
    }
    private func groupButton(_ label: String, value: String) -> some View {
        TheaterChip(title: label, selected: model.selectedGroup == value) {
            model.selectedGroup = value; Task { await model.search() }
        }
    }
    private func conversationRow(_ conversation: Conversation) -> some View {
        let selected = model.selectedConversationID == conversation.id
        let writing = conversation.writing == true || (selected && model.isGenerating)
        let unread = model.isUnread(conversation)
        return Button {
            Task { await model.selectConversation(conversation); if !isWide { sheet = nil } }
        } label: {
            HStack(alignment: .top, spacing: 11) {
                MonogramRoundel(title: conversation.title, pinned: conversation.pinned, size: 40)
                    .overlay(Circle().strokeBorder(palette.rose, lineWidth: 1).opacity(writing ? 1 : 0))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(conversation.title).font(.theaterSerif(15)).fontWeight(unread ? .semibold : .regular).lineLimit(1)
                        Spacer(minLength: 4)
                        if unread {
                            Circle().fill(palette.rose).frame(width: 7, height: 7)
                                .background(Circle().fill(palette.rose.opacity(0.14)).frame(width: 13, height: 13))
                        }
                        Text(letterDate(conversation.updatedAt)).font(.system(size: 11)).foregroundStyle(palette.dim)
                    }
                    if writing {
                        HStack(spacing: 7) {
                            TypingHearts()
                            Text("正在给你写回信…").font(.theaterSerif(12.5)).foregroundStyle(palette.rose)
                        }
                    } else if let preview = conversation.preview, !preview.isEmpty {
                        Text(readablePreview(preview)).font(.system(size: 12)).foregroundStyle(unread ? palette.text : palette.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }.padding(.top, 2)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 10)
                .background(selected ? palette.sunken : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(SatinPressStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(writing ? "她正在写回信" : unread ? "有新的回信" : "")
            .contextMenu {
                Button("重新命名") { beginRename(conversation) }.disabled(!model.isConnected)
                Button(conversation.pinned ? "不再置顶" : "放在心上（置顶）") { Task { await model.togglePin(conversation) } }
            }
    }
    private func sideDestination(_ title: String, glyph: TheaterGlyphKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                TheaterGlyph(kind: glyph).stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)).frame(width: 15, height: 15)
                Text(title).font(.system(size: 13)).lineLimit(1).fixedSize()
            }.foregroundStyle(palette.secondary).padding(.horizontal, 8).frame(height: 40).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func readablePreview(_ value: String) -> String {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("⚠ API error") || source.hasPrefix("API error (attempt") || source.hasPrefix("Traceback (most recent call last)") {
            return "上次的回复未能写完。"
        }
        if let rendered = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) {
            var preview = "", previousBlock: Int?
            for run in rendered.runs {
                let block = run.presentationIntent?.components.first?.identity
                if !preview.isEmpty && block != previousBlock { preview += " " }
                let text = String(rendered[run.range].characters)
                preview += run.inlinePresentationIntent?.contains(.code) == true ? text : readableMathPreview(text)
                previousBlock = block
            }
            return preview
        }
        return source
    }

    private func readableMathPreview(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"\$\$[\s\S]*?\$\$|(?<![\\$])\$(?!\$)([^$\n]+)\$(?!\$)"#) else { return text }
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let formula: String
            if let body = Range(match.range(at: 1), in: text) {
                formula = String(text[body])
                guard formula == formula.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            } else { formula = "" }
            let readable = formula.isEmpty || formula.contains("\\") || formula.contains("{") || formula.contains("}") ? "公式" : formula
            result.replaceSubrange(range, with: readable)
        }
        return result
    }

    private func beginRename(_ conversation: Conversation) {
        renamingConversation = conversation
        conversationTitle = conversation.title
        sheet = .rename
    }

    private func finishMainActions(_ action: @escaping () -> Void) {
        afterMainActions = action
        showMainActions = false
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(InspectorMode.allCases, id: \.self) { mode in
                    TheaterChip(title: mode.rawValue, selected: inspectorMode == mode) {
                        previewRequestID = UUID(); openingArtifact = nil; animate { inspectorMode = mode }
                    }
                }
                Spacer(minLength: 0)
                if inspectorMode != .portrait {
                    companionStage(closeUp: true)
                        .frame(width: 48, height: 52)
                }
                GlyphButton(label: "收起共创台", glyph: .close) {
                    previewRequestID = UUID()
                    openingArtifact = nil
                    if isWide { animate { showInspector = false } } else { sheet = nil }
                }
            }.padding(.horizontal, 14).frame(height: 68)
            TheaterRule()
            Group {
                switch inspectorMode {
                case .portrait:
                    companionStage(closeUp: false)
                case .scratchpad:
                    ScratchpadView(conversationID: model.selectedConversationID ?? "loose-notes", onShare: { url in
                        let destination = model.selectedConversationID
                        Task { if let artifact = await model.upload(fileURL: url) { await model.attach(artifact, to: destination); if !isWide { sheet = nil } } }
                    })
                case .document:
                    if let toolDetail {
                        ToolDetailView(event: toolDetail, onClose: { self.toolDetail = nil })
                    } else if let openingArtifact {
                        VStack(spacing: 18) {
                            Image(artifactImageName(openingArtifact)).resizable().scaledToFit().frame(width: 72, height: 72)
                            Text(openingArtifact.name).font(.theaterSerif(15)).multilineTextAlignment(.center)
                            HStack(spacing: 8) { TypingHearts(); Text("正在替你翻开…").font(.system(size: 13)).foregroundStyle(palette.secondary) }
                            Button("返回琴房") {
                                previewRequestID = UUID(); self.openingArtifact = nil
                                animate { inspectorMode = .portrait }
                            }.font(.system(size: 13))
                        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let document {
                        DocumentInspector(url: document.url, title: document.title, page: document.page,
                                          libraryScope: model.libraryScope, interactiveSession: document.interactiveSession,
                                          markdownSession: document.markdownSession, fileSHA256: document.fileSHA256,
                                          line: document.line, endLine: document.endLine, initialSoftLight: document.softLight,
                                          onDigestResolved: { value in
                            if self.document?.id == document.id { self.document?.fileSHA256 = value }
                        },
                                          onPageChange: { value in
                            if self.document?.id == document.id { self.document?.page = value }
                        }, onSoftLightChange: { value in
                            if self.document?.id == document.id { self.document?.softLight = value }
                        }, onShare: { url in
                            let destination = model.selectedConversationID
                            Task { if let artifact = await model.upload(fileURL: url) { await model.attach(artifact, to: destination); if !isWide { sheet = nil } } }
                        }, onOpenSource: openSource).id(document.id)
                    } else {
                        VStack(spacing: 16) {
                            Image("icon_document").resizable().scaledToFit().frame(width: 92, height: 92)
                                .shadow(color: palette.shadow, radius: 10, x: 0, y: 5)
                            Text("想一起看的纸页，就放在这里吧。").font(.theaterSerif(15)).foregroundStyle(palette.secondary)
                            Button("打开文件") { importPresented = true }.buttonStyle(TheaterActionStyle(prominent: true))
                            Button("从文件柜选择") { sheet = .media }.font(.system(size: 13)).foregroundStyle(palette.rose)
                        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }.background(palette.letter)
    }

    private func companionStage(closeUp: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { clock in
            let late = isLateNight(clock.date)
            let posture: StagePosture = pencil.isDrawing ? .watching
                : model.isGenerating ? .thinking
                : closeUp ? .watching
                : teaPreference == true ? .tea
                : !model.draft.isEmpty ? .reading
                : teaPreference == nil && late ? .tea : .idle
            let visible = ((isWide && showInspector) || sheet == .inspector) && (sheet == nil || sheet == .inspector)
            let stage = LivingStageView(isNight: palette.isDark, posture: posture, closeUp: closeUp, isPresented: visible)
            if closeUp { stage }
            else {
                VStack(spacing: 0) {
                    stageWindow(stage, visible: visible)
                    VStack(alignment: .leading, spacing: 6) {
                        ScriptLine(text: "Sakiko", size: 24)
                        Text(stageCaption(posture: posture, late: late))
                            .font(.theaterSerif(19)).lineSpacing(3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button("展开草稿纸") { animate { inspectorMode = .scratchpad } }
                                .buttonStyle(TheaterActionStyle())
                            Button(posture == .tea ? "收起茶盏" : "陪我喝杯茶") { teaPreference = posture != .tea }
                                .buttonStyle(TheaterActionStyle())
                        }.padding(.top, 4)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(palette.text).padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 18)
                        .background(palette.raised)
                        .overlay(alignment: .top) { StitchRule() }
                }
            }
        }
    }

    /// Her window on the stage: the season drifting past, the rainy room while the light is out,
    /// and a tap says hello.
    private func stageWindow(_ stage: LivingStageView, visible: Bool) -> some View {
        stage.frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { SeasonalAir(isNight: palette.isDark, animate: visible) }
            .overlay { if model.connection == .failed { RainyRoom(animate: visible).transition(.opacity) } }
            .animation(.easeInOut(duration: 0.9), value: model.connection == .failed)
            .overlay(alignment: .top) { if pokedStage { pokeBubble.padding(.top, 24) } }
            .contentShape(Rectangle())
            .onTapGesture { pokedStage = true; poke() }
            .accessibilityAddTraits(.isButton).accessibilityHint("轻轻叫她一声")
    }

    /// "相识第 N 天", counted from the first letter on this host.
    private var togetherDays: Int? {
        model.conversations.compactMap { $0.createdAt.flatMap(hostDate) }.min().map { CompanionMood.daysTogether(since: $0) }
    }
    /// She answers when you tap her portrait; tap often enough and she gets flustered.
    private func poke() {
        pokes += 1
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { pokeLine = CompanionMood.pokeLine(pokes, settings: model.settings) }
        moodMoment = pokes >= 5 ? (model.settings.personality.teasing >= 60 ? "tsundere_chide" : "happy_achieved") : "proud_smug"
        pokeTask?.cancel()
        pokeTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { pokeLine = nil }
            moodMoment = nil
            try? await Task.sleep(nanoseconds: 5_400_000_000)
            if !Task.isCancelled { pokes = 0 }
        }
    }
    @ViewBuilder private var pokeBubble: some View {
        if let line = pokeLine {
            HStack(spacing: 7) {
                HeartShape().fill(palette.rose).frame(width: 10, height: 9)
                Text(line).font(.theaterSerif(14)).foregroundStyle(palette.text).fixedSize()
            }.padding(.horizontal, 14).frame(minHeight: 36)
                .background(palette.raised, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.goldLine, lineWidth: 0.8))
                .shadow(color: palette.shadow, radius: 8, x: 0, y: 3)
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .topLeading)))
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
        }
    }

    /// Her short reply when something is kept: a pearl capsule that rises, then leaves.
    @ViewBuilder private var keepsake: some View {
        if let line = model.keepsakeLine {
            HStack(spacing: 8) {
                if let sticker = model.keepsakeSticker {
                    Image(sticker).resizable().scaledToFit().frame(width: 58, height: 58)
                        .rotationEffect(.degrees(-4)).padding(.vertical, -10).accessibilityHidden(true)
                } else {
                    HeartShape().fill(palette.rose).frame(width: 12, height: 11)
                }
                Text(line).font(.theaterSerif(14)).foregroundStyle(palette.text)
            }.padding(.horizontal, 18).frame(minHeight: 40)
                .background(palette.raised, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.goldLine, lineWidth: 0.8))
                .shadow(color: palette.shadow, radius: 10, x: 0, y: 4)
                .padding(.bottom, 132)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
        }
    }

    /// The header follows the reply on its way: reading your letter, looking things up, then writing.
    private var replyStatus: String {
        if let reply = model.messages.last(where: { !$0.isUser }), !reply.content.isEmpty,
           ["running", "streaming"].contains(reply.status) { return "正在写回信…" }
        let step = model.events.last { $0.runID == model.activeRunID && $0.layer == "L2" && $0.kind == "tool" }
        let state = (step?.payload["state"]?.stringValue ?? "").lowercased()
        if step != nil, state.range(of: "done|complete|success|finish|block|fail|error|denied|permission|cancel", options: .regularExpression) == nil {
            return "在查资料…"
        }
        return "在读你的信…"
    }

    private func stageCaption(posture: StagePosture, late: Bool) -> String {
        if model.connection == .failed { return "灯熄着。接回琴房，她就会回到窗边。" }
        if posture == .tea { return late ? "夜深了，先松一松肩膀。" : "茶还温着，慢慢喝。" }
        if model.isGenerating { return "她在想，怎么回你才好。" }
        if posture == .reading { return "你写，她在旁边看着呢。" }
        return palette.isDark ? "月下琴房，灯一直亮着。" : "春日影里，窗边的位置留给你。"
    }

    private func isLateNight(_ date: Date) -> Bool {
        let time = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (time.hour == 23 && (time.minute ?? 0) >= 30) || (time.hour ?? 12) < 5
    }

    @ViewBuilder private func sheetContent(_ selected: TheaterSheet) -> some View {
        switch selected {
        case .connection: ConnectionPanel(model: model)
        case .models: ModelPanel(model: model)
        case .rename: renamePanel
        case .settings: SettingsPanel(model: model, onConnect: { sheet = .connection })
        case .pencilCaptures:
            PencilCaptureLibrary(scope: model.libraryScope, conversationID: model.selectedConversationID) { url, destination, scope in
                guard scope == model.libraryScope, let artifact = await model.upload(fileURL: url), scope == model.libraryScope else { return false }
                return await model.attach(artifact, to: destination)
            }
        case .memories: MemoryPanel(model: model)
        case .pins: ContextPinsPanel(model: model, onArtifact: openArtifact, onOpenSource: openSource)
        case .media: MediaPanel(model: model, onImport: { sheet = nil; importPresented = true }, onOpen: openArtifact, onTranscribe: transcribeArtifact)
        case .search: SearchPanel(model: model, onSelect: { sheet = nil })
        case .sidebar: sidebar.presentationDetents([.large])
        case .inspector: inspector.presentationDetents([.large])
        case .voice:
            VoiceNoteSheet(onKeep: { url in
                voiceReview.begin(url: url, destinationID: voiceDestinationID, libraryScope: voiceDestinationScope)
                sheetAfterDismissal = .transcription
            })
        case .transcription:
            VoiceTranscriptPanel(model: model, review: voiceReview, onNewRecording: {
                voiceDestinationID = model.selectedConversationID
                voiceDestinationScope = model.libraryScope
                sheetAfterDismissal = .voice
                sheet = nil
            })
        }
    }

    private var renamePanel: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("给这段乐章起个名字").font(.theaterSerif(22))
                TextField("乐章名称", text: $conversationTitle)
                    .font(.system(size: 18)).padding(16)
                    .background(palette.raised, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.stitch, lineWidth: 0.7))
                    .accessibilityLabel("乐章名称")
                if let notice = model.notice { Text(notice).font(.system(size: 13)).foregroundStyle(palette.warning) }
                Spacer()
            }.padding(24).background(palette.background)
                .navigationTitle("乐章名称").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(palette.background, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { sheet = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            guard let conversation = renamingConversation else { return }
                            let title = conversationTitle, scope = model.libraryScope
                            model.notice = nil
                            Task {
                                await model.renameConversation(conversation, title: title)
                                if scope == model.libraryScope, sheet == .rename,
                                   renamingConversation?.id == conversation.id, model.notice == nil { sheet = nil }
                            }
                        }.disabled(!model.isConnected || conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }

    private func animate(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22), action)
    }
    private func toggleSidebar() {
        if isWide { animate { showSidebar.toggle() } } else { sheet = .sidebar }
    }
    private func openInspector(_ mode: InspectorMode) {
        if mode != .document { previewRequestID = UUID(); openingArtifact = nil }
        animate { inspectorMode = mode; showInspector = true }
        if isWide {
            if sheet == .media || sheet == .pins || sheet == .inspector { sheet = nil }
        } else if let sheet, sheet != .inspector {
            sheetAfterDismissal = .inspector; self.sheet = nil
        } else { sheet = .inspector }
    }
    private func openArtifact(_ artifact: Artifact) {
        openArtifact(artifact, location: nil)
    }
    private func openSource(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "hajisaki" else { return false }
        guard let location = ArtifactLocation(url: url) else {
            model.notice = "这处引用没有标清位置。原件仍在文件柜里。"
            return true
        }
        let known = model.artifacts + model.messages.flatMap { $0.attachments.compactMap(\.artifact) }
        guard let artifact = known.first(where: { $0.id == location.artifactID }) else {
            model.notice = "这份引用暂时没有对应的原件。请从文件柜重新选取。"
            return true
        }
        openArtifact(artifact, location: location)
        return true
    }
    private func openArtifact(_ artifact: Artifact, location: ArtifactLocation?) {
        let requestID = UUID()
        let scope = model.libraryScope
        previewRequestID = requestID
        openingArtifact = artifact; toolDetail = nil
        openInspector(.document)
        Task {
            defer { if previewRequestID == requestID { openingArtifact = nil } }
            if let url = await model.download(artifact), previewRequestID == requestID, scope == model.libraryScope {
                document = TheaterDocument(url: url, title: artifact.name, page: location?.page,
                                           line: location?.line, endLine: location?.endLine, fileSHA256: artifact.sha256)
                toolDetail = nil
            }
        }
    }
    private func openVoice() {
        guard !model.isBusy else { return }
        if voiceReview.recordingURL != nil { sheet = .transcription }
        else { voiceDestinationID = model.selectedConversationID; voiceDestinationScope = model.libraryScope; sheet = .voice }
    }
    private func performPencilCommand(_ command: PencilCommand) {
        switch command {
        case .scratchpad: openInspector(.scratchpad)
        case .voice: openVoice()
        case .effort: sheet = .models
        case .circle, .highlight: break
        }
    }
    private func attachPencilCapture(_ url: URL, destination: String?, scope: String) {
        guard scope == model.libraryScope else { pencil.captureFinished(url, delivered: false); return }
        Task {
            guard let artifact = await model.upload(fileURL: url), scope == model.libraryScope,
                  pencil.isCaptureCurrent(url) else { pencil.captureFinished(url, delivered: false); return }
            let attached = await model.attach(artifact, to: destination)
            pencil.captureFinished(url, delivered: attached)
        }
    }
    private func transcribeArtifact(_ artifact: Artifact) {
        let requestID = UUID(), destination = model.selectedConversationID
        let scope = model.libraryScope
        previewRequestID = requestID
        Task {
            if let url = await model.download(artifact), previewRequestID == requestID {
                guard scope == model.libraryScope else { return }
                voiceReview.begin(url: url, destinationID: destination, artifact: artifact, libraryScope: scope)
                sheet = .transcription
            }
        }
    }
    private func importFiles(_ urls: [URL]) {
        importFiles(urls, to: model.selectedConversationID)
    }
    private func importFiles(_ urls: [URL], to destination: String?, scope: String? = nil) {
        let origin = scope ?? model.libraryScope
        Task {
            for url in urls {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                do {
                    let local = try await Task.detached(priority: .userInitiated) { try Self.keepImportedFile(url) }.value
                    enqueueImportedFile(local, to: destination, scope: origin)
                } catch { model.notice = "这份文件尚未收好。请再打开一次。" }
            }
        }
    }
    nonisolated private static func keepImportedFile(_ url: URL) throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ImportedDocuments", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = directory.appendingPathComponent(url.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { original in
            do { try FileManager.default.copyItem(at: original, to: local) }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return local
    }
    private func openImportedFile(_ local: URL, to destination: String?, scope: String) async {
        guard model.libraryScope == scope else {
            model.notice = "文件已留在本机。切回原来的琴房后，再把它递过去。"
            return
        }
        document = TheaterDocument(url: local, title: local.lastPathComponent, page: nil)
        toolDetail = nil
        openInspector(.document)
        if let artifact = await model.upload(fileURL: local) { await model.attach(artifact, to: destination) }
    }
    private func enqueueImportedFile(_ url: URL, to destination: String?, scope: String) {
        importQueue.append(PendingImport(url: url, conversationID: destination, libraryScope: scope))
        guard !drainingImports else { return }
        drainingImports = true
        Task {
            while !importQueue.isEmpty {
                let next = importQueue.removeFirst()
                await openImportedFile(next.url, to: next.conversationID, scope: next.libraryScope)
            }
            drainingImports = false
        }
    }
    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        let destination = model.selectedConversationID
        let scope = model.libraryScope
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    if let url { Task { @MainActor in importFiles([url], to: destination, scope: scope) } }
                }
            } else if let type = [UTType.pdf.identifier, UTType.image.identifier].first(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
                accepted = true
                provider.loadFileRepresentation(forTypeIdentifier: type) { temporaryURL, _ in
                    guard let temporaryURL else { return }
                    // Provider URLs expire when this callback returns; retain the original first.
                    do {
                        let local = try Self.keepImportedFile(temporaryURL)
                        Task { @MainActor in enqueueImportedFile(local, to: destination, scope: scope) }
                    } catch { Task { @MainActor in model.notice = "这份文件尚未收好。请再打开一次。" } }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    if let text = object as? String {
                        Task { @MainActor in await model.appendImportedText(text, to: destination, scope: scope) }
                    }
                }
            }
        }
        return accepted
    }
    private var keyboardActions: some View {
        Group {
            Button("搜索记忆与对话") { sheet = .search }.keyboardShortcut("k", modifiers: .command)
            Button("新的乐章") { Task { await model.createConversation() } }.keyboardShortcut("n", modifiers: .command)
            Button("显示或隐藏名录") { toggleSidebar() }.keyboardShortcut("\\", modifiers: .command)
            Button("停止回复") { Task { await model.stop() } }.keyboardShortcut(".", modifiers: .command)
            Button("打开语音手稿") { openVoice() }.keyboardShortcut(.space, modifiers: .option)
            Button("怀表指令环") { pencil.presentRing() }.keyboardShortcut("p", modifiers: [.command, .shift])
            ForEach(0..<4) { index in
                Button("思考档位 \(index + 1)") {
                    if model.availableEfforts.indices.contains(index) { model.selectedEffort = model.availableEfforts[index] }
                }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }.frame(width: 0, height: 0).clipped().accessibilityHidden(true)
    }
}
