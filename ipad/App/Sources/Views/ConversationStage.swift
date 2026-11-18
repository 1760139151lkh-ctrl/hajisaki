import SwiftUI
import UniformTypeIdentifiers

struct ConversationStage: View {
    @ObservedObject var model: TheaterModel
    let onOpenConnection: () -> Void
    let onImport: () -> Void
    let onScratchpad: () -> Void
    let onVoice: () -> Void
    let onPins: () -> Void
    let onModels: () -> Void
    let onArtifact: (Artifact) -> Void
    let onTranscribe: (Artifact) -> Void
    let onTool: (StreamEvent) -> Void
    let onOpenSource: (URL) -> Bool
    var pencilInteractionRevision = 0
    var onPreview: ((PencilPreview) -> Void)? = nil
    /// Saki's current portrait, chosen by the root view from what is happening.
    var portrait = "idle_gentle"
    @Environment(\.theaterPalette) private var palette
    @State private var followsLatest = true
    @State private var selectionMessage: ChatMessage?
    @State private var actionMessageID: String?
    @State private var afterMessageActions: (() -> Void)?
    @State private var messageLayoutRevision = 0
    @State private var layout = ConversationLayout()
    @State private var rows: [ConversationRow] = []
    /// Work notes the user opened stay open while the reply keeps arriving.
    @State private var openNotes: Set<String> = []
    /// The night she last asked you to go to sleep, so she asks once.
    @AppStorage("hajisaki.nightCare") private var nightCareNight = ""
    @FocusState private var composeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 10) {
                    Text(notice).font(.system(size: 13)).foregroundStyle(palette.text).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    GlyphButton(label: "收起提示", glyph: .close) { model.notice = nil }
                }.padding(.leading, 22).padding(.trailing, 10).background(palette.sunken)
            }
            TimelineView(.everyMinute) { context in
                if model.selectedConversation != nil, CompanionMood.isLateNight(context.date),
                   context.date.timeIntervalSince(CompanionMood.launchedAt) > 25 * 60,
                   nightCareNight != Self.nightKey(context.date) {
                    nightCare(context.date)
                }
            }
            if model.providerSimulated && model.isConnected {
                HStack(spacing: 7) {
                    TheaterGlyph(kind: .lamp).stroke(lineWidth: 1.2).frame(width: 14, height: 14)
                    Text("本地演练 · 回复不来自模型").font(.system(size: 12))
                }.foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 9)
                    .background(palette.sunken)
            }
            if !model.contextPins.isEmpty {
                Button(action: onPins) {
                    HStack(spacing: 8) {
                        Image("icon_bookmark").resizable().scaledToFit().frame(width: 24, height: 24)
                        Text("固定的上下文 · \(model.contextPins.count)").font(.system(size: 12))
                        Spacer()
                        TheaterGlyph(kind: .back).stroke(lineWidth: 1.1).rotationEffect(.degrees(180)).frame(width: 13, height: 13).foregroundStyle(palette.dim)
                    }.padding(.horizontal, 24).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(palette.secondary)
                    .overlay(alignment: .bottom) { TheaterRule() }
            }
            ZStack(alignment: .bottom) {
                Group {
                    if model.messages.isEmpty {
                        ScrollView {
                            emptyConversation.frame(maxWidth: 680).padding(.horizontal, 28).frame(maxWidth: .infinity)
                        }
                    } else {
                        ConversationList(rows: visibleRows, followsLatest: $followsLatest,
                                         layoutRevision: messageLayoutRevision, palette: palette) { row in
                            conversationRow(row).frame(maxWidth: 680, alignment: .leading)
                                .padding(.horizontal, 28).frame(maxWidth: .infinity)
                        }
                    }
                }
                .onChange(of: model.selectedConversationID) { _, _ in
                    rows = []
                    followsLatest = true
                }
            }
            if !followsLatest && !model.messages.isEmpty {
                Button { followsLatest = true } label: {
                    HStack(spacing: 6) {
                        if model.isGenerating {
                            HeartShape().fill(palette.rose).frame(width: 11, height: 10)
                        } else {
                            TheaterGlyph(kind: .chevron).stroke(lineWidth: 1.4).frame(width: 14, height: 14)
                        }
                        Text(model.isGenerating ? "她还在写" : "回到最新").font(.system(size: 13, weight: .medium))
                    }.foregroundStyle(palette.background).padding(.horizontal, 16).frame(height: 36)
                        .background(palette.text, in: Capsule())
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.top, 4)
                    .accessibilityLabel("回到最新消息")
            }
            composer
        }
        .sheet(item: $selectionMessage) { message in
            NativeMessageSelectionView(text: message.content).environment(\.theaterPalette, palette)
        }
        .task(id: layoutInput) {
            let input = layoutInput
            do {
                let updated = try await layout.rows(for: input)
                try Task.checkCancellation()
                rows = updated
                messageLayoutRevision &+= 1
            } catch is CancellationError { }
            catch { }
        }
        .onAppear { RichDocumentView.prewarm() }
        .onChange(of: pencilInteractionRevision) { _, _ in lockReading() }
    }

    /// Past midnight, once: she asks you to go to sleep.
    private func nightCare(_ date: Date) -> some View {
        HStack(alignment: .center, spacing: 14) {
          Image("sticker_sleep").resizable().scaledToFit().frame(width: 72, height: 72).accessibilityLabel("快去睡觉！")
          VStack(alignment: .leading, spacing: 6) {
            ScriptLine(text: "Sweet dreams", size: 20)
            Text(CompanionMood.nightCare(date, settings: model.settings)).font(.theaterSerif(15)).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Spacer(minLength: 0)
                Button("好，这就去睡") {
                    nightCareNight = Self.nightKey(date)
                    let name = (model.settings.nickname ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    model.say(name.isEmpty ? "晚安。梦里见。" : "晚安，\(name)。梦里见。")
                }
                Button("再聊一会儿") {
                    nightCareNight = Self.nightKey(date)
                    model.say(model.settings.personality.teasing >= 60 ? "……就十分钟。我会看着时间的。" : "那就再一会儿。我陪你。")
                }
            }.font(.system(size: 14, weight: .medium)).foregroundStyle(palette.rose).buttonStyle(.plain)
          }
        }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            .letterCard(cornerRadius: 18)
            .frame(maxWidth: 680).padding(.horizontal, 22).padding(.top, 12).frame(maxWidth: .infinity)
            .transition(.opacity)
    }
    /// One key per night: the hours after midnight belong to the evening before.
    private static func nightKey(_ date: Date) -> String {
        let evening = date.addingTimeInterval(-12 * 3600)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: evening)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    private var layoutInput: [ConversationLayoutInput] {
        model.messages.map { ConversationLayoutInput(message: $0, tasks: model.messageTasks[$0.id]?.items ?? []) }
    }

    private var visibleRows: [ConversationRow] {
        let visibleRuns = Set(model.events.filter { event in
            ["L1", "L2", "L3", "L4"].contains(event.layer) && !["reply_delta", "artifact"].contains(event.kind) &&
                (event.layer == "L2" || event.layer == "L4" ||
                 (!event.text.isEmpty && (event.layer == "L1" || event.kind == "narration")))
        }.map(\.runID))
        let visibleMessages = Set(model.events.compactMap { visibleRuns.contains($0.runID) ? $0.messageID : nil })
        return rows.filter { row in
            if case .activity = row.kind {
                return model.settings.transparency != "companion" && visibleMessages.contains(row.message.id)
            }
            return true
        }
    }

    private func lockReading() {
        guard followsLatest else { return }
        followsLatest = false
    }

    @ViewBuilder private func conversationRow(_ row: ConversationRow) -> some View {
        let message = row.message
        switch row.kind {
        case .user:
            messageView(message).padding(.top, 32)
        case .header:
            messageHeader(message).padding(.top, 32)
        case .activity:
            if model.settings.transparency != "companion", !events(for: message).isEmpty {
                letterMargin(activity(for: message).padding(.top, 13))
            }
        case .chunk(let chunk):
            letterMargin(NativeMessageChunk(chunk: chunk, onSelectionChange: lockReading,
                               onLayoutChange: { messageLayoutRevision &+= 1 }, onOpenSource: onOpenSource,
                               taskState: model.messageTasks[message.id],
                               taskMutationPending: model.updatingTaskIDs.contains(message.id) || !model.isConnected,
                               onToggleTask: { item, checked in
                guard let state = model.messageTasks[message.id] else { return }
                Task { _ = await model.updateTask(item, checked: checked, in: state) }
            }).padding(.top, 13))
        case .attachments:
            letterMargin(messageAttachments(message).padding(.top, 13))
        case .status:
            letterMargin(messageStatus(message))
                .task(id: message.id + ":" + message.status) { await loadTasks(for: message) }
        }
    }

    /// Saki's reply rows are plain paper, like the phone; kept as one hook for future margins.
    private func letterMargin<Content: View>(_ content: Content) -> some View {
        content
    }

    private var emptyConversation: some View {
        VStack(spacing: 10) {
            ArchedPortrait(image: palette.isDark ? "night-room" : "day-room", width: 200, height: 264)
                .padding(.bottom, 10)
            FiligreeDivider(width: 132)
            ScriptLine(text: "Only for you", size: 26)
            Text(model.selectedConversation == nil ? "把这一页，留给我们。" : CompanionMood.emptyHeading())
                .font(.theaterSerif(24)).tracking(2).multilineTextAlignment(.center)
            Text(model.selectedConversation == nil ? "「" + (milestone ?? CompanionMood.dailyNote(settings: model.settings)) + "」" : "不用急着整理语言。想到哪里，就从哪里开始吧。")
                .font(.system(size: 14)).lineSpacing(5).foregroundStyle(palette.secondary).multilineTextAlignment(.center)
            if model.selectedConversation == nil {
                // The piece she would like to play for you today.
                let today = CompanionMood.todaysPiece()
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    TheaterGlyph(kind: .sparkle).fill(palette.gold).frame(width: 10, height: 10)
                    (Text("今天想弹给你听：").foregroundStyle(palette.secondary)
                     + Text(today.piece).font(.theaterSerif(14)).foregroundStyle(palette.text)
                     + Text("  " + today.word).foregroundStyle(palette.dim)).font(.system(size: 13))
                }.multilineTextAlignment(.center).padding(.top, 8)
            }
            if model.selectedConversation == nil, let week = weekSummary {
                // Sunday: a page from her weekly journal.
                HStack(spacing: 14) {
                    Image("weekly_journal_cover").resizable().scaledToFill().frame(width: 40, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 4)).rotationEffect(.degrees(-4)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        ScriptLine(text: "This week", size: 18)
                        Text(week).font(.theaterSerif(14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: 420, alignment: .leading)
                    .letterCard(cornerRadius: 16).padding(.top, 10)
            }
            if model.selectedConversation == nil {
                HStack(spacing: 12) {
                    Button("写一封信") { Task { await model.createConversation(); composeFocused = true } }
                        .buttonStyle(TheaterActionStyle(prominent: true))
                    if !model.isConnected { Button("连接电脑", action: onOpenConnection).buttonStyle(TheaterActionStyle()) }
                }.padding(.top, 14)
            } else {
                VStack(spacing: 8) { starterButtons }.frame(maxWidth: 360).padding(.top, 18)
            }
        }.padding(.top, 48).padding(.bottom, 35).frame(maxWidth: .infinity)
    }

    /// Letters touched and hearts given this week, on Sundays only.
    private var weekSummary: String? {
        guard Calendar.current.component(.weekday, from: .now) == 1 else { return nil }
        let since = Date().addingTimeInterval(-7 * 86_400)
        let letters = model.conversations.filter { !$0.archived && (hostDate($0.updatedAt) ?? .distantPast) >= since }.count
        let hearts = model.heartedLines.values.filter { $0.at >= since }.count
        return CompanionMood.weekLine(letters: letters, hearts: hearts, settings: model.settings)
    }

    /// On round days (100, 365, 520…) the note belongs to the two of you.
    private var milestone: String? {
        model.conversations.compactMap { $0.createdAt.flatMap(hostDate) }.min()
            .flatMap { CompanionMood.milestoneNote(CompanionMood.daysTogether(since: $0)) }
    }

    @ViewBuilder private var starterButtons: some View {
        ForEach(CompanionMood.starters(), id: \.0) { starter in
            Button {
                model.draft = starter.1
                composeFocused = true
            } label: {
                HStack(spacing: 10) {
                    Text(starter.0).font(.system(size: 14)).foregroundStyle(palette.text)
                    Spacer(minLength: 0)
                    TheaterGlyph(kind: .back).stroke(lineWidth: 1.2).rotationEffect(.degrees(180)).frame(width: 13, height: 13).foregroundStyle(palette.dim)
                }.padding(.horizontal, 16).frame(height: 48)
                    .letterCard(cornerRadius: 14)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("放进草稿，不会自动寄出")
        }
    }

    private func messageHeader(_ message: ChatMessage) -> some View {
        HStack(spacing: 8) {
                if message.isUser {
                    Spacer(minLength: 0)
                    if readByHer(message) {
                        HStack(spacing: 3) {
                            HeartShape().fill(palette.rose).frame(width: 9, height: 8.3)
                            Text("已读").font(.system(size: 11.5))
                        }.foregroundStyle(palette.rose).accessibilityElement(children: .combine)
                    }
                    if message.status == "queued" || message.status == "pending" {
                        HStack(spacing: 5) {
                            TheaterGlyph(kind: .letter).stroke(lineWidth: 1.1).frame(width: 13, height: 13).foregroundStyle(palette.rose)
                            Text(model.isConnected ? "寄出中" : "等琴房亮灯就寄出").font(.system(size: 12)).foregroundStyle(palette.dim)
                        }
                    }
                    Text(messageClock(message.createdAt)).font(.system(size: 12)).monospacedDigit().foregroundStyle(palette.dim)
                } else {
                    CameoPortrait(image: "idle_gentle", size: 28)
                    Text("祥子").font(.theaterSerif(15)).tracking(1).foregroundStyle(palette.rose)
                    TiaraMark(width: 13)
                        .overlay { if model.justSealedMessageID == message.id { SealBurst() } }
                    Text(messageClock(message.createdAt)).font(.system(size: 12)).monospacedDigit().foregroundStyle(palette.dim)
                    if model.heartedMessages.contains(message.id) {
                        HeartShape().fill(palette.rose).frame(width: 11, height: 10).accessibilityLabel("你心动过")
                    }
                    Spacer(minLength: 0)
                }
                Button { actionMessageID = message.id } label: {
                    TheaterGlyph(kind: .more).stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round)).frame(width: 19, height: 19)
                        .frame(width: 44, height: 44).foregroundStyle(palette.dim).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("这条消息的操作")
                .popover(isPresented: Binding(get: { actionMessageID == message.id }, set: { if !$0 { actionMessageID = nil } })) {
                  TheaterPopup {
                    if !message.isUser && !message.content.isEmpty {
                        Button(model.heartedMessages.contains(message.id) ? "取消心动" : "心动") { finishMessageActions { model.toggleHeart(message) } }
                    }
                    Button("引用到输入框") { finishMessageActions { model.quote(message); composeFocused = true } }
                    Button("从这里分支") { finishMessageActions { Task { await model.fork(from: message) } } }
                    Button("记入记忆星空") { finishMessageActions { Task { await model.saveMemory(content: message.content) } } }.disabled(message.content.isEmpty)
                    Button("固定为上下文") { finishMessageActions { Task { _ = await model.pinMessage(message) } } }
                        .disabled(model.pinMutationPending || !model.isConnected || model.contextPins.contains(where: { $0.kind == .message && $0.targetID == message.id }))
                    Button("念给我听") { finishMessageActions { TheaterAudio.shared.speak(text: message.content) } }.disabled(message.content.isEmpty)
                    Button("选择整条文字") { finishMessageActions { selectionMessage = message } }.disabled(message.content.isEmpty)
                    if onPreview != nil {
                        Button("查看手稿") { finishMessageActions { onPreview?(PencilPreview(title: "这一段手稿", text: message.content)) } }.disabled(message.content.isEmpty)
                    }
                    ShareLink(item: message.content) { Text("分享文字") }
                  }.environment(\.theaterPalette, palette)
                      .onDisappear {
                          let action = afterMessageActions; afterMessageActions = nil
                          action?()
                      }
                }
        }
        .task(id: message.id + ":" + message.status) { await loadTasks(for: message) }
    }

    /// Your words: a blush bubble on the right, hugging short lines and widening for rich ones.
    private func messageView(_ message: ChatMessage) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            VStack(alignment: .leading, spacing: 10) {
                if !message.content.isEmpty { userBody(message) }
                if !message.attachments.isEmpty {
                    messageAttachments(message)
                }
                messageStatus(message)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(palette.bubble, in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20))
            .opacity(message.status == "queued" || message.status == "pending" ? 0.6 : 1)
            messageHeader(message)
        }
        .frame(maxWidth: 560, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func isPlainShort(_ text: String) -> Bool {
        text.count <= 160 && !text.contains("\n") && text.rangeOfCharacter(from: CharacterSet(charactersIn: "`*_#[]|$<>~")) == nil
    }

    @ViewBuilder private func userBody(_ message: ChatMessage) -> some View {
        if isPlainShort(message.content) {
            Text(message.content).font(.body).lineSpacing(4).foregroundStyle(palette.bubbleText)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } else {
            NativeMessageBody(text: message.content, messageID: message.id,
                              isStreaming: message.status == "streaming" || message.status == "running",
                              onSelectionChange: lockReading,
                              onLayoutChange: { messageLayoutRevision &+= 1 },
                              onOpenSource: onOpenSource,
                              taskState: model.messageTasks[message.id],
                              taskMutationPending: model.updatingTaskIDs.contains(message.id) || !model.isConnected,
                              onToggleTask: { item, checked in
                                  guard let state = model.messageTasks[message.id] else { return }
                                  Task { _ = await model.updateTask(item, checked: checked, in: state) }
                              })
        }
    }

    private func messageAttachments(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(message.attachments, id: \.id) { reference in
                if let artifact = reference.artifact ?? model.artifacts.first(where: { $0.id == reference.id }) {
                    if artifact.isNativeCard {
                        InteractiveCardView(model: model, artifact: artifact, conversationID: message.conversationID,
                                            onOpenOriginal: { onArtifact(artifact) },
                                            onLayoutChange: { messageLayoutRevision &+= 1 })
                    } else {
                        ArtifactRow(artifact: artifact, onOpen: { onArtifact(artifact) })
                            .contextMenu { if artifactIsAudio(artifact) { Button("转写这段录音") { onTranscribe(artifact) } } }
                    }
                }
            }
        }
    }

    @ViewBuilder private func messageStatus(_ message: ChatMessage) -> some View {
        if message.status == "failed" {
            VStack(alignment: .leading, spacing: 6) {
                Text(message.content.isEmpty ? "这封回信没能写成。把你的信再寄一次，我重新写给你。" : "这一段没能写完。已经写下的内容仍在。")
                    .font(message.content.isEmpty ? .theaterSerif(14) : .system(size: 12))
                    .foregroundStyle(message.content.isEmpty ? palette.secondary : palette.warning)
                if message.content.isEmpty && !message.isUser {
                    Button { resend(answering: message) } label: {
                        HStack(spacing: 6) {
                            TheaterGlyph(kind: .letter).stroke(lineWidth: 1.2).frame(width: 15, height: 15)
                            Text("放回信纸，再寄一次").font(.system(size: 13, weight: .medium))
                        }.foregroundStyle(palette.rose).frame(minHeight: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 13)
        } else if message.status == "stopped" {
            Text(message.content.isEmpty ? "还没落笔，就先停下了。" : "先停在这里。想继续时，再叫我。")
                .font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.top, 13)
        } else if !message.isUser && message.content.isEmpty && ["queued", "running", "streaming"].contains(message.status) {
            // Before her first words: reading your letter, looking things up, or thinking a little long.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let phase = replyPhase(for: message, now: context.date)
                HStack(spacing: 9) {
                    TypingHearts()
                    Text(CompanionMood.phaseLine(phase, settings: model.settings, letter: letterContext(answering: message)))
                        .font(.theaterSerif(14)).tracking(0.5).foregroundStyle(palette.rose)
                    if phase == .working {
                        // While she looks things up for you, she holds up her little "交给我吧".
                        Image("sticker_trust").resizable().scaledToFit().frame(width: 52, height: 52)
                            .rotationEffect(.degrees(-4)).padding(.vertical, -10).accessibilityLabel("交给我吧")
                    }
                }.frame(minHeight: 30).padding(.top, 10)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    /// The letter this reply answers: pictures, a recording, documents, or many words.
    private func letterContext(answering message: ChatMessage) -> CompanionMood.LetterContext {
        guard let index = model.messages.firstIndex(where: { $0.id == message.id }),
              let letter = model.messages[..<index].last(where: { $0.isUser }) else { return CompanionMood.LetterContext() }
        let files = letter.attachments.compactMap { reference in reference.artifact ?? model.artifacts.first { $0.id == reference.id } }
        return CompanionMood.LetterContext(images: files.filter { $0.mime.hasPrefix("image/") }.count,
                                           audio: files.filter { $0.mime.hasPrefix("audio/") }.count,
                                           documents: files.filter { !$0.mime.hasPrefix("image/") && !$0.mime.hasPrefix("audio/") && !$0.mime.hasPrefix("video/") }.count,
                                           long: letter.content.count > 300,
                                           small: hostDate(letter.createdAt).map { (1..<5).contains(Calendar.current.component(.hour, from: $0)) } ?? false)
    }

    private func replyPhase(for message: ChatMessage, now: Date) -> CompanionMood.ReplyPhase {
        if workSteps(events(for: message), live: true).contains(where: { $0.state == .working }) { return .working }
        if let started = model.replyStartedAt, now.timeIntervalSince(started) > 30 { return .long }
        return .reading
    }

    /// Your latest letter shows "已读" once she has really started on it (not merely when it was queued).
    private func readByHer(_ message: ChatMessage) -> Bool {
        guard message.isUser, let index = model.messages.lastIndex(where: { $0.isUser }), model.messages[index].id == message.id,
              let answer = model.messages[(index + 1)...].first(where: { !$0.isUser }) else { return false }
        return answer.status != "queued" || !answer.content.isEmpty
    }

    /// A reply that failed before any words: the letter that asked for it goes back into the draft.
    private func resend(answering message: ChatMessage) {
        guard let index = model.messages.firstIndex(where: { $0.id == message.id }),
              let asked = model.messages[..<index].last(where: { $0.isUser }) else { return }
        model.draft = asked.content
        composeFocused = true
    }

    private func loadTasks(for message: ChatMessage) async {
        guard ["completed", "stopped", "failed"].contains(message.status),
              message.content.contains("[ ]") || message.content.contains("[x]") || message.content.contains("[X]") else { return }
        _ = await model.loadTasks(for: message)
    }

    private func events(for message: ChatMessage) -> [StreamEvent] {
        guard let runID = model.events.first(where: { $0.messageID == message.id })?.runID else { return [] }
        return model.events.filter { $0.runID == runID && ["L1", "L2", "L3", "L4"].contains($0.layer) && !["reply_delta", "artifact"].contains($0.kind) }
    }

    private func finishMessageActions(_ action: @escaping () -> Void) {
        afterMessageActions = action
        actionMessageID = nil
    }
    /// One tool step of a reply, merged per call so it shows once with its latest state.
    struct WorkStep: Identifiable {
        enum State { case working, done, alert }
        let id: String
        var label: String
        var state: State
        var event: StreamEvent
    }
    private func workSteps(_ values: [StreamEvent], live: Bool) -> [WorkStep] {
        var steps: [WorkStep] = []
        for event in values where event.layer == "L2" && event.kind == "tool" {
            let raw = event.payload["summary"]?.stringValue ?? event.payload["title"]?.stringValue ?? event.payload["name"]?.stringValue ?? ""
            let label = raw.replacingOccurrences(of: #"^Antigravity\s*·\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            let value = (event.payload["state"]?.stringValue ?? "").lowercased()
            let state: WorkStep.State = value.range(of: "block|fail|error|denied|permission|cancel|reject", options: .regularExpression) != nil ? .alert
                : value.range(of: "done|complete|success|finish", options: .regularExpression) != nil ? .done : .working
            let call = event.payload["detail"]?.objectValue?["tool_call_id"]?.stringValue
            if let call, let index = steps.firstIndex(where: { $0.id == call }) {
                steps[index].label = label; steps[index].state = state; steps[index].event = event
            } else if call == nil, let last = steps.indices.last, steps[last].label == label, steps[last].state == .working {
                steps[last].state = state; steps[last].event = event
            } else {
                steps.append(WorkStep(id: call ?? String(event.seq), label: label, state: state, event: event))
            }
        }
        return live ? steps : steps.map { step in var step = step; if step.state == .working { step.state = .done }; return step }
    }

    private enum ActivityItem: Identifiable {
        case notes(String), narration(StreamEvent), summary(StreamEvent), capsule(StreamEvent)
        var id: String {
            switch self {
            case .notes(let run): return "notes:" + run
            case .narration(let event), .summary(let event), .capsule(let event): return String(event.seq)
            }
        }
    }
    @ViewBuilder private func activity(for message: ChatMessage) -> some View {
        let values = events(for: message)
        let live = values.first.map { $0.runID == model.activeRunID } ?? false
        let steps = workSteps(values, live: live)
        let items: [ActivityItem] = values.reduce(into: []) { items, event in
            if event.layer == "L2" && event.kind == "tool" {
                if !steps.isEmpty, !items.contains(where: { if case .notes = $0 { return true }; return false }) { items.append(.notes(event.runID)) }
            } else if event.layer == "L2" || event.layer == "L4" {
                items.append(.capsule(event))
            } else if !event.text.isEmpty {
                if event.layer == "L1" { items.append(.summary(event)) }
                else if event.kind == "narration" { items.append(.narration(event)) }
            }
        }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(items) { item in
                    switch item {
                    case .notes(let run): workNotes(steps, run: run, live: live)
                    case .summary(let event): PublicSummaryView(text: event.text)
                    case .narration(let event):
                        // A short note she slips in while she works — her voice, so in her serif.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            TheaterGlyph(kind: .quill).stroke(lineWidth: 1.1).frame(width: 13, height: 13).foregroundStyle(palette.gold)
                            Text(event.text).font(.theaterSerif(14.5)).lineSpacing(4).foregroundStyle(palette.secondary).textSelection(.enabled)
                        }
                    case .capsule(let event):
                        Button {
                            if event.layer == "L4", let artifact = eventArtifact(event) { onArtifact(artifact) }
                            else { onTool(event) }
                        } label: {
                            HStack(spacing: 8) {
                                TheaterGlyph(kind: event.layer == "L4" ? .book : .chevron).stroke(lineWidth: 1.2).frame(width: 16, height: 16)
                                Text(capsuleTitle(event)).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 10).padding(.vertical, 9).background(palette.selection, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).foregroundStyle(palette.secondary)
                            .pencilPreview(title: capsuleTitle(event), text: event.payload["detail"]?.stringValue ?? event.payload["summary"]?.stringValue ?? event.text)
                    }
                }
            }
        }
    }

    /// Every step of one reply folded into a single line; the current step writes with a quill.
    private func workNotes(_ steps: [WorkStep], run: String, live: Bool) -> some View {
        let current = live ? steps.last(where: { $0.state == .working }) : nil
        let alerts = steps.filter { $0.state == .alert }
        let open = openNotes.contains(run)
        let title = current.map { $0.label + "…" }
            ?? (alerts.count == 1 ? alerts[0].label : alerts.count > 1 ? "有 \(alerts.count) 步没有走通" : "工作札记 · \(steps.count) 步")
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { if open { openNotes.remove(run) } else { openNotes.insert(run) } }
            } label: {
                HStack(spacing: 8) {
                    if current != nil {
                        QuillWriting()
                    } else {
                        TheaterGlyph(kind: alerts.isEmpty ? .check : .sparkle).stroke(lineWidth: 1.3).frame(width: 14, height: 14)
                            .foregroundStyle(alerts.isEmpty ? palette.gold : palette.rose)
                    }
                    Text(title).font(.system(size: 12.5)).lineLimit(1)
                        .foregroundStyle(alerts.isEmpty ? (current == nil ? palette.secondary : palette.text) : palette.rose)
                    TheaterGlyph(kind: .chevron).stroke(lineWidth: 1.1).frame(width: 12, height: 12)
                        .rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(palette.dim)
                }.padding(.horizontal, 12).frame(minHeight: 34)
                    .background(palette.raised, in: Capsule())
                    .overlay(Capsule().strokeBorder(alerts.isEmpty ? (current == nil ? palette.goldLine.opacity(0.5) : palette.goldLine) : palette.rose, lineWidth: 0.8))
                    .contentShape(Capsule())
            }.buttonStyle(.plain)
                .accessibilityLabel(title).accessibilityHint(open ? "收起这些步骤" : "展开这些步骤")
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { step in
                        Button { onTool(step.event) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                TheaterGlyph(kind: step.state == .done ? .check : step.state == .alert ? .close : .quill)
                                    .stroke(lineWidth: 1.2).frame(width: 12, height: 12)
                                    .foregroundStyle(step.state == .done ? palette.gold : palette.rose)
                                Text(step.label).font(.system(size: 12.5)).multilineTextAlignment(.leading)
                                    .foregroundStyle(step.state == .alert ? palette.rose : step.state == .working ? palette.text : palette.secondary)
                            }.frame(minHeight: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.leading, 18).padding(.vertical, 2)
                    .overlay(alignment: .leading) { Rectangle().fill(palette.goldLine.opacity(0.5)).frame(width: 0.8).padding(.leading, 6) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    private func capsuleTitle(_ event: StreamEvent) -> String {
        if event.layer == "L4", event.payload["status"]?.stringValue == "prepared_for_model" { return "随这封信递上的画面" }
        if let title = event.payload["title"]?.stringValue, !title.isEmpty { return String(title.prefix(80)) }
        if let summary = event.payload["summary"]?.stringValue, !summary.isEmpty, !summary.contains("\n") { return String(summary.prefix(80)) }
        if !event.text.isEmpty && event.text.count < 100 && !event.text.contains("\n") { return event.text }
        return event.layer == "L4" ? "查看附带画面" : "查看这一步"
    }
    private func eventArtifact(_ event: StreamEvent) -> Artifact? {
        guard let value = event.payload["artifact"], let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(Artifact.self, from: data)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.pendingCount > 0 {
                HStack(spacing: 8) {
                    Text("\(model.pendingCount) 封信待寄出，我会替你收好").font(.system(size: 12)).foregroundStyle(palette.secondary)
                    Spacer()
                    Button(model.isConnected ? "重新寄出" : "连接电脑") {
                        if model.isConnected { Task { await model.retryPending() } } else { onOpenConnection() }
                    }.font(.system(size: 12, weight: .medium)).foregroundStyle(palette.rose)
                }.padding(.horizontal, 14).frame(minHeight: 36)
                    .background(palette.sunken, in: RoundedRectangle(cornerRadius: 10))
            }
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(model.pendingAttachments) { artifact in
                            HStack(spacing: 6) {
                                Image(artifactImageName(artifact)).resizable().scaledToFit().frame(width: 24, height: 24)
                                Text(artifact.name).font(.system(size: 12)).lineLimit(1).frame(maxWidth: 180)
                                GlyphButton(label: "移除附件 \(artifact.name)", glyph: .close) { model.removeAttachment(id: artifact.id) }.frame(width: 30, height: 32)
                            }.padding(.leading, 9).background(palette.raised, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 0.7))
                        }
                    }
                }
            }
            if let progress = model.transferProgress { ProgressView(value: progress).tint(palette.rose) }
            VStack(spacing: 4) {
                TextField("写给祥子", text: $model.draft, prompt: Text(CompanionMood.draftPrompt()).foregroundColor(palette.dim), axis: .vertical)
                    .font(.system(size: 17)).lineSpacing(5).lineLimit(2...7).focused($composeFocused)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .padding(.horizontal, 18).padding(.top, 15).accessibilityLabel("写给祥子")
                    .disabled(model.isBusy)
                HStack(spacing: 2) {
                    GlyphButton(label: "添加附件", glyph: .attachment, action: onImport).disabled(model.isBusy)
                    GlyphButton(label: "展开草稿纸", glyph: .pencil, action: onScratchpad)
                    Button(action: onVoice) {
                        Image("icon_microphone").resizable().scaledToFit().frame(width: 26, height: 26).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("打开语音手稿").disabled(model.isBusy)
                    modelMenu
                    Spacer(minLength: 0)
                    if model.isGenerating {
                        Button { Task { await model.stop() } } label: {
                            TheaterGlyph(kind: .stop).stroke(style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                                .frame(width: 18, height: 18).frame(width: 40, height: 40)
                                .foregroundStyle(palette.background).background(palette.text, in: Circle())
                                .frame(width: 46, height: 46).contentShape(Circle())
                        }.buttonStyle(.plain).accessibilityLabel("请她先停一停")
                    } else {
                        let empty = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty
                        Button {
                            followsLatest = true
                            TheaterAudio.shared.play(.send)
                            Task { await model.send() }
                        } label: {
                            Group {
                                if empty {
                                    TheaterGlyph(kind: .send).stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                                        .frame(width: 18, height: 18).frame(width: 40, height: 40)
                                        .foregroundStyle(palette.dim).background(palette.sunken, in: Circle())
                                } else {
                                    WaxHeart(size: 40)
                                }
                            }.frame(width: 46, height: 46).contentShape(Circle())
                        }.buttonStyle(.plain).accessibilityLabel("封好，寄给祥子")
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(model.isBusy || empty)
                    }
                }.padding(.horizontal, 7).padding(.bottom, 7)
            }.background(palette.raised, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(composeFocused ? palette.rose.opacity(0.6) : palette.goldLine, lineWidth: 1))
                .shadow(color: palette.shadow, radius: 8, x: 0, y: 2)
                .animation(.easeOut(duration: 0.18), value: composeFocused)
        }.frame(maxWidth: 680).padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 16).frame(maxWidth: .infinity)
    }

    private var modelMenu: some View {
        Button(action: onModels) {
            HStack(spacing: 5) {
                Text(model.models.first(where: { $0.id == model.selectedModelID })?.name ?? "模型与思考")
                    .font(.system(size: 12)).lineLimit(1)
                Text("·").foregroundStyle(palette.dim)
                Text(effortLabel(model.selectedEffort)).font(.system(size: 12)).lineLimit(1)
                TheaterGlyph(kind: .chevron).stroke(lineWidth: 1.1).frame(width: 13, height: 13)
            }.foregroundStyle(palette.secondary).padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("模型、思考深度与透视度")
            .accessibilityValue(effortLabel(model.selectedEffort))
    }
}

func effortLabel(_ value: String) -> String {
    ["low": "轻声回应", "medium": "细细斟酌", "high": "深入推敲", "xhigh": "尽力深思", "minimal": "简短回应", "none": "直接回应"][value] ?? value
}

private struct PublicSummaryView: View {
    let text: String
    @Environment(\.theaterPalette) private var palette
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Text("她的思考摘记").font(.system(size: 12))
                    TheaterGlyph(kind: .chevron).stroke(lineWidth: 1).frame(width: 13, height: 13).rotationEffect(.degrees(expanded ? 180 : 0))
                }.foregroundStyle(palette.secondary)
            }.buttonStyle(.plain)
            if expanded { Text(text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled).foregroundStyle(palette.secondary) }
        }
    }
}

struct ArtifactRow: View {
    let artifact: Artifact
    let onOpen: () -> Void
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(artifactImageName(artifact)).resizable().scaledToFit().frame(width: 40, height: 40)
                    .padding(3).background(palette.sunken, in: RoundedRectangle(cornerRadius: 10))
                    .pencilPreview(title: artifact.name, text: "\(artifact.mime) · \(formatFileSize(artifact.size))")
                VStack(alignment: .leading, spacing: 4) {
                    Text(artifact.name).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(formatFileSize(artifact.size)).font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
                TheaterGlyph(kind: .back).stroke(lineWidth: 1.1).rotationEffect(.degrees(180)).frame(width: 14, height: 14).foregroundStyle(palette.dim)
            }.padding(10).background(palette.raised, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.line, lineWidth: 0.7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct ToolDetailView: View {
    let event: StreamEvent
    let onClose: () -> Void
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(event.layer == "L4" ? "审阅画面" : "这一步的记录").font(.theaterSerif(16))
                Spacer()
                GlyphButton(label: "关闭记录", glyph: .close, action: onClose)
            }.padding(.horizontal, 16).padding(.top, 8)
            ScrollView {
                Text(detail).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }
    }
    private var detail: String {
        if let value = event.payload["detail"]?.stringValue, !value.isEmpty { return value }
        if let value = event.payload["output"]?.stringValue, !value.isEmpty { return value }
        if let value = event.payload["summary"]?.stringValue, !value.isEmpty { return value }
        if !event.text.isEmpty { return event.text }
        return "这一条没有附加文字。"
    }
}
