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
                        TheaterGlyph(kind: .chevron).stroke(lineWidth: 1.4).frame(width: 14, height: 14)
                        Text("回到最新").font(.system(size: 13, weight: .medium))
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
            Text(model.selectedConversation == nil ? "把这一页，留给我们。" : "这一刻，只听你说。")
                .font(.theaterSerif(24)).tracking(2).multilineTextAlignment(.center)
            Text(model.selectedConversation == nil ? CompanionMood.greeting() : "不用急着整理语言。想到哪里，就从哪里开始吧。")
                .font(.system(size: 14)).lineSpacing(5).foregroundStyle(palette.secondary).multilineTextAlignment(.center)
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
                    if message.status == "queued" || message.status == "pending" {
                        Text("正在寄出").font(.system(size: 12)).foregroundStyle(palette.rose)
                    }
                    Text(messageClock(message.createdAt)).font(.system(size: 12)).monospacedDigit().foregroundStyle(palette.dim)
                } else {
                    CameoPortrait(image: "idle_gentle", size: 28)
                    Text("祥子").font(.theaterSerif(15)).tracking(1).foregroundStyle(palette.rose)
                    TiaraMark(width: 13)
                    Text(messageClock(message.createdAt)).font(.system(size: 12)).monospacedDigit().foregroundStyle(palette.dim)
                    Spacer(minLength: 0)
                }
                Button { actionMessageID = message.id } label: {
                    TheaterGlyph(kind: .more).stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round)).frame(width: 19, height: 19)
                        .frame(width: 44, height: 44).foregroundStyle(palette.dim).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("这条消息的操作")
                .popover(isPresented: Binding(get: { actionMessageID == message.id }, set: { if !$0 { actionMessageID = nil } })) {
                  TheaterPopup {
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
            Text("这一段没能写完。已经写下的内容仍在。").font(.system(size: 12)).foregroundStyle(palette.warning).padding(.top, 13)
        } else if message.status == "stopped" {
            Text("先停在这里。想继续时，再叫我。").font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.top, 13)
        } else if !message.isUser && message.content.isEmpty && ["queued", "running", "streaming"].contains(message.status) {
            HStack(spacing: 9) {
                TypingHearts()
                Text("正在写回信").font(.system(size: 13)).foregroundStyle(palette.dim)
            }.frame(minHeight: 30).padding(.top, 10)
                .accessibilityElement(children: .combine)
        }
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
    @ViewBuilder private func activity(for message: ChatMessage) -> some View {
        let values = events(for: message)
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(values) { event in
                    if event.layer == "L2" || event.layer == "L4" {
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
                    } else if !event.text.isEmpty {
                        if event.layer == "L1" {
                            PublicSummaryView(text: event.text)
                        } else if event.kind == "narration" {
                            Text(event.text).font(.system(size: 14)).lineSpacing(4).foregroundStyle(palette.secondary).textSelection(.enabled)
                        }
                    }
                }
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
                TextField("写给祥子", text: $model.draft, prompt: Text("写给祥子…").foregroundColor(palette.dim), axis: .vertical)
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
