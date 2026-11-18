import SwiftUI

struct ContextPinsPanel: View {
    @ObservedObject var model: TheaterModel
    let onArtifact: (Artifact) -> Void
    let onOpenSource: (URL) -> Bool
    @Environment(\.theaterPalette) private var palette

    var body: some View {
        TheaterPanel(title: "固定的上下文") {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if model.contextPins.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Image("icon_bookmark").resizable().scaledToFit().frame(width: 64, height: 64)
                            Text("还没有固定的内容。").font(.theaterSerif(16))
                            Text("想让她一直记着的段落或原件，可以钉在这里。").font(.system(size: 13)).foregroundStyle(palette.secondary)
                        }
                    }
                    ForEach(model.contextPins) { pin in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(pin.kind == .artifact ? "原件" : pin.kind == .message ? "对话摘记" : "记下的话")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.gold)
                                Spacer()
                                Button("移出") { Task { await model.removePin(pin) } }
                                    .font(.system(size: 12)).disabled(model.pinMutationPending || !model.isConnected)
                                    .accessibilityLabel("移出这条固定的上下文")
                            }
                            if let artifact = pin.source?.artifact {
                                ArtifactRow(artifact: artifact, onOpen: { onArtifact(artifact) })
                            } else {
                                DisclosureGroup {
                                    NativeMessageBody(text: pin.displayText, messageID: "pin-" + pin.id, onOpenSource: onOpenSource)
                                } label: {
                                    Text(preview(pin.displayText)).font(.system(size: 16)).lineLimit(3)
                                        .foregroundStyle(palette.text).multilineTextAlignment(.leading)
                                }
                            }
                            StitchRule()
                        }
                    }
                    if !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("固定当前草稿") {
                            let content = model.draft, destination = model.selectedConversationID
                            Task { _ = await model.addPin(kind: .text, content: content, conversationID: destination) }
                        }.buttonStyle(TheaterActionStyle())
                            .disabled(model.pinMutationPending || !model.isConnected || model.selectedConversationID == nil)
                    }
                    if let notice = model.notice { Text(notice).font(.system(size: 13)).foregroundStyle(palette.warning) }
                }.padding(24).frame(maxWidth: 680).frame(maxWidth: .infinity, alignment: .center)
            }.task(id: model.selectedConversationID) { _ = await model.loadPins() }
        }
    }
    private func preview(_ source: String) -> String {
        if let value = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return String(value.characters)
        }
        return source
    }
}
