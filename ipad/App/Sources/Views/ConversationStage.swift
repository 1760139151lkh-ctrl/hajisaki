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
                HStack(alignment: .top, spacing: 8) {
                    Text(notice).font(.system(size: 13)).foregroundStyle(palette.warning).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    GlyphButton(label: "收起提示", glyph: .close) { model.notice = nil }
                }.padding(.leading, 22).padding(.trailing, 10).background(palette.warning.opacity(0.05))
            }
            if model.providerSimulated && model.isConnected {
                Text("本地演练 · 回复不来自模型").font(.system(size: 12)).foregroundStyle(palette.gold)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 9)
            }
            if !model.contextPins.isEmpty {
                Button(action: onPins) {
                    HStack(spacing: 8) {
                        Image("icon_bookmark").resizable().scaledToFit().frame(width: 22, height: 22)
                        Text("固定的上下文 · \(model.contextPins.count)").font(.system(size: 12))
                        Spacer()
                    }.padding(.horizontal, 24).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(palette.secondary)
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
                    Text("回到最新").font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(palette.blue).background(palette.raised)
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
                activity(for: message).padding(.top, 13)
            }
        case .chunk(let chunk):
            NativeMessageChunk(chunk: chunk, onSelectionChange: lockReading,
                               onLayoutChange: { messageLayoutRevision &+= 1 }, onOpenSource: onOpenSource,
                               taskState: model.messageTasks[message.id],
                               taskMutationPending: model.updatingTaskIDs.contains(message.id) || !model.isConnected,
                               onToggleTask: { item, checked in
                guard let state = model.messageTasks[message.id] else { return }
                Task { _ = await model.updateTask(item, checked: checked, in: state) }
            }).padding(.top, 13)
        case .attachments:
            messageAttachments(message).padding(.top, 13)
        case .status:
            messageStatus(message)
                .task(id: message.id + ":" + message.status) { await loadTasks(for: message) }
        }
    }

    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 21) {
            Text(model.selectedConversation == nil ? "把这一页，留给我们。" : "新的乐章").font(.system(size: 28, weight: .regular, design: .serif)).tracking(0.5)
            if model.selectedConversation == nil {
                HStack(spacing: 12) {
                    Button("写下新乐章") { Task { await model.createConversation(); composeFocused = true } }.buttonStyle(TheaterActionStyle())
                    if !model.isConnected { Button("连接电脑", action: onOpenConnection).buttonStyle(TheaterActionStyle()) }
                }
            }
        }.padding(.top, 50).padding(.bottom, 35).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageHeader(_ message: ChatMessage) -> some View {
        HStack(spacing: 8) {
                if !message.isUser {
                    Image("profile_portrait").resizable().scaledToFill().frame(width: 27, height: 27).clipShape(Circle())
                }
                Text(message.isUser ? "你" : "祥子").font(.system(size: 12, weight: .semibold)).foregroundStyle(message.isUser ? palette.secondary : palette.gold)
                Spacer(minLength: 0)
                if message.status == "queued" || message.status == "pending" {
                    Text("待寄出").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                Button { actionMessageID = message.id } label: {
                    TheaterGlyph(kind: .more).stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round)).frame(width: 19, height: 19)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
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

    private func messageView(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            messageHeader(message)
            if !message.content.isEmpty {
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
            if !message.attachments.isEmpty {
                messageAttachments(message)
            }
            messageStatus(message)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(palette.selection.opacity(0.55), in: RoundedRectangle(cornerRadius: 15))
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
            Text("这一段没能写完。已经写下的内容仍在。 ").font(.system(size: 12)).foregroundStyle(palette.warning).padding(.top, 13)
        } else if message.status == "stopped" {
            Text("先停在这里。 ").font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.top, 13)
        } else if !message.isUser && message.content.isEmpty && ["queued", "running", "streaming"].contains(message.status) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("稍等，我在看。 ").font(.system(size: 13)).foregroundStyle(palette.secondary)
            }.frame(minHeight: 27).padding(.top, 13)
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
                HStack {
                    Text("\(model.pendingCount) 条消息待寄出").font(.system(size: 12)).foregroundStyle(palette.secondary)
                    Spacer()
                    Button(model.isConnected ? "重新寄出" : "连接电脑") {
                        if model.isConnected { Task { await model.retryPending() } } else { onOpenConnection() }
                    }.font(.system(size: 12, weight: .medium))
                }
            }
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(model.pendingAttachments) { artifact in
                            HStack(spacing: 6) {
                                Image(artifactImageName(artifact)).resizable().scaledToFit().frame(width: 23, height: 23)
                                Text(artifact.name).font(.system(size: 12)).lineLimit(1).frame(maxWidth: 180)
                                GlyphButton(label: "移除附件 \(artifact.name)", glyph: .close) { model.removeAttachment(id: artifact.id) }.frame(width: 28, height: 30)
                            }.padding(.leading, 8).background(palette.selection, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }
            if let progress = model.transferProgress { ProgressView(value: progress).tint(palette.gold) }
            VStack(spacing: 6) {
                TextField("写给祥子", text: $model.draft, prompt: Text("写给祥子…").foregroundColor(palette.secondary), axis: .vertical)
                    .font(.system(size: 17)).lineSpacing(5).lineLimit(2...7).focused($composeFocused)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .padding(.horizontal, 15).padding(.top, 15).accessibilityLabel("写给祥子")
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
                        GlyphButton(label: "停止回复", glyph: .stop, active: true) { Task { await model.stop() } }
                    } else {
                        Button {
                            followsLatest = true
                            TheaterAudio.shared.play(.send)
                            Task { await model.send() }
                        } label: {
                            TheaterGlyph(kind: .send).stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                                .frame(width: 23, height: 23).frame(width: 38, height: 38)
                                .foregroundStyle(palette.background).background(palette.blue, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityLabel("发送")
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(model.isBusy || (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty))
                            .opacity(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty ? 0.4 : 1)
                    }
                }.padding(.horizontal, 7).padding(.bottom, 7)
            }.background(palette.raised, in: RoundedRectangle(cornerRadius: 19))
                .overlay(RoundedRectangle(cornerRadius: 19).stroke(palette.line, lineWidth: 0.5))
        }.frame(maxWidth: 680).padding(.horizontal, 22).padding(.top, 9).padding(.bottom, 19).frame(maxWidth: .infinity)
    }

    private var modelMenu: some View {
        Button(action: onModels) {
            HStack(spacing: 5) {
                Text(model.models.first(where: { $0.id == model.selectedModelID })?.name ?? "模型与思考")
                    .font(.system(size: 11)).lineLimit(1)
                TheaterGlyph(kind: .chevron).stroke(lineWidth: 1).frame(width: 13, height: 13)
            }.foregroundStyle(palette.secondary).frame(minHeight: 44).padding(.horizontal, 5).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("模型、思考深度与透视度")
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
                    TheaterGlyph(kind: .chevron).stroke(lineWidth: 1).frame(width: 14, height: 14).rotationEffect(.degrees(expanded ? 180 : 0))
                    Text("思考摘记").font(.system(size: 12))
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
                Image(artifactImageName(artifact)).resizable().scaledToFit().frame(width: 36, height: 36)
                    .pencilPreview(title: artifact.name, text: "\(artifact.mime) · \(formatFileSize(artifact.size))")
                VStack(alignment: .leading, spacing: 4) {
                    Text(artifact.name).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(formatFileSize(artifact.size)).font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
                TheaterGlyph(kind: .back).stroke(lineWidth: 1).rotationEffect(.degrees(180)).frame(width: 15, height: 15)
            }.padding(11).background(palette.selection, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
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
                Text(event.layer == "L4" ? "审阅画面" : "这一步的记录").font(.system(size: 15, weight: .medium))
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
