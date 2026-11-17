import SwiftUI

struct InteractiveCardView: View {
    @ObservedObject var model: TheaterModel
    let artifact: Artifact
    let conversationID: String
    let onOpenOriginal: () -> Void
    var onLayoutChange: (() -> Void)?
    @Environment(\.theaterPalette) private var palette
    @State private var loading = false
    @State private var savingReading = false

    private var key: String { conversationID + "|" + artifact.id }
    private var snapshot: InteractiveCardSnapshot? { model.interactiveCards[key] }
    private var reading: InteractiveCardReading { model.interactiveCardReading[key] ?? InteractiveCardReading() }
    private var loadIdentity: String { model.libraryScope + "|" + key + (model.isConnected ? "|online" : "|offline") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let card = snapshot {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(card.definition.title).font(.system(size: 20, weight: .medium, design: .serif))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("原件", action: onOpenOriginal).font(.system(size: 12)).frame(minHeight: 44)
                }
                if card.definition.kind == "flashcards", !card.definition.cards.isEmpty {
                    flashcards(card)
                } else if card.definition.kind == "poll" {
                    poll(card)
                }
            } else {
                HStack(spacing: 12) {
                    if loading { ProgressView().controlSize(.small) }
                    Button("展开卡片") { Task { await load() } }.disabled(loading)
                    Spacer()
                    Button("原件", action: onOpenOriginal)
                }.font(.system(size: 14)).frame(minHeight: 80)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(palette.gold.opacity(0.35), lineWidth: 0.5) }
        .task(id: loadIdentity) { await load() }
        .onChange(of: snapshot) { _, _ in onLayoutChange?() }
        .onChange(of: reading) { _, _ in onLayoutChange?() }
    }

    @ViewBuilder private func flashcards(_ card: InteractiveCardSnapshot) -> some View {
        let index = min(max(0, reading.index), card.definition.cards.count - 1)
        let revealed = reading.revealed.contains(index)
        let face = card.definition.cards[index]
        HStack {
            Text(revealed ? "答案" : "题面").foregroundStyle(palette.gold)
            Spacer()
            Text("\(index + 1) / \(card.definition.cards.count)").monospacedDigit().foregroundStyle(palette.secondary)
        }.font(.system(size: 12))
        NativeMessageBody(text: revealed ? face.back : face.front, messageID: artifact.id + ":face",
                          onLayoutChange: onLayoutChange)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        HStack(spacing: 12) {
            Button { changeIndex(index - 1, in: card) } label: { Text("上一张").frame(minHeight: 44) }
                .disabled(index == 0 || savingReading)
            Spacer(minLength: 4)
            Button {
                var next = reading
                next.index = index
                if revealed { next.revealed.remove(index) } else { next.revealed.insert(index) }
                save(next, in: card)
            } label: { Text(revealed ? "翻回题面" : "翻看答案").frame(minHeight: 44) }
                .disabled(savingReading).foregroundStyle(palette.gold)
            Spacer(minLength: 4)
            Button { changeIndex(index + 1, in: card) } label: { Text("下一张").frame(minHeight: 44) }
                .disabled(index + 1 >= card.definition.cards.count || savingReading)
        }.font(.system(size: 14)).buttonStyle(.plain).frame(minHeight: 44)
    }

    @ViewBuilder private func poll(_ card: InteractiveCardSnapshot) -> some View {
        NativeMessageBody(text: card.definition.question, messageID: artifact.id + ":question", onLayoutChange: onLayoutChange)
        VStack(spacing: 8) {
            ForEach(Array(card.definition.options.enumerated()), id: \.offset) { index, option in
                let selected = card.selectedOption == index
                Button {
                    Task { await model.vote(index, in: card) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(selected ? "✓" : "○").foregroundStyle(selected ? palette.gold : palette.secondary)
                        Text(option).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        if card.counts.reduce(0, +) > 0, card.counts.indices.contains(index) {
                            Text("\(card.counts[index]) 票").font(.system(size: 12)).foregroundStyle(palette.secondary).monospacedDigit()
                        }
                    }.font(.system(size: 15)).padding(.horizontal, 13).padding(.vertical, 12).frame(minHeight: 48)
                        .background(selected ? palette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(selected ? palette.gold.opacity(0.65) : palette.line, lineWidth: 0.5) }
                }.buttonStyle(.plain).foregroundStyle(palette.text)
                    .disabled(!model.isConnected || model.updatingCardIDs.contains(artifact.id))
                    .accessibilityValue(selected ? "已选择" : "未选择")
            }
        }
        if model.updatingCardIDs.contains(artifact.id) {
            ProgressView().controlSize(.small).frame(minHeight: 20)
        } else if !model.isConnected {
            Text("接通琴房后可以投票。").font(.system(size: 12)).foregroundStyle(palette.secondary)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        await model.loadInteractiveCard(artifact, conversationID: conversationID)
    }

    private func changeIndex(_ index: Int, in card: InteractiveCardSnapshot) {
        guard card.definition.cards.indices.contains(index) else { return }
        var next = reading
        next.index = index
        save(next, in: card)
    }

    private func save(_ next: InteractiveCardReading, in card: InteractiveCardSnapshot) {
        savingReading = true
        Task {
            await model.saveInteractiveCardReading(next, in: card)
            savingReading = false
        }
    }
}
