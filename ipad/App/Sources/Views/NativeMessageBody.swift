import SwiftUI
import UIKit
import CryptoKit

/// A user bubble keeps its paragraphs together. Assistant islands are flattened
/// into the conversation's one lazy viewport, without nested height estimates.
struct NativeMessageBody: View {
    let text: String
    let messageID: String
    var isStreaming = false
    var onSelectionChange: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var onOpenSource: ((URL) -> Bool)?
    var taskState: MessageTaskState?
    var taskMutationPending = false
    var onToggleTask: ((MessageTaskItem, Bool) -> Void)?
    @State private var chunks: [MessageChunk] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(chunks) { chunk in
                NativeMessageChunk(chunk: chunk, onSelectionChange: onSelectionChange, onLayoutChange: onLayoutChange,
                                   onOpenSource: onOpenSource, taskState: taskState,
                                   taskMutationPending: taskMutationPending, onToggleTask: onToggleTask)
            }
        }
        .task(id: text + (isStreaming ? "\u{0}stream" : "\u{0}final") + taskRangesIdentity) {
            let source = text, streaming = isStreaming, items = taskState?.items ?? []
            do {
                try Task.checkCancellation()
                let parsing = Task.detached(priority: .userInitiated) {
                    try MessageChunkParser.parse(source, streaming: streaming, tasks: items)
                }
                let result = try await withTaskCancellationHandler(operation: { try await parsing.value }, onCancel: { parsing.cancel() })
                try Task.checkCancellation()
                chunks = result
            } catch is CancellationError { }
            catch { }
        }
        .onAppear { RichDocumentView.prewarm() }
        .onChange(of: chunks) { _, _ in
            DispatchQueue.main.async { onLayoutChange?() }
        }
    }

    private var taskRangesIdentity: String {
        (taskState?.items ?? []).map { "\($0.index):\($0.sourceStartLine ?? -1):\($0.sourceEndLine ?? -1)" }.joined(separator: "|")
    }
}

struct ConversationLayoutInput: Equatable, Sendable {
    var message: ChatMessage
    var tasks: [MessageTaskItem]
}

struct ConversationRow: Identifiable, Sendable {
    enum Kind: Sendable {
        case user, header, activity, chunk(MessageChunk), attachments, status
    }
    var id: String
    var message: ChatMessage
    var kind: Kind
}

/// Only changed sources are parsed, away from the main actor. Every assistant
/// block becomes a direct child of the same lazy stack and gets a stable ID.
actor ConversationLayout {
    private var cached: [String: (input: ConversationLayoutInput, chunks: [MessageChunk])] = [:]

    func rows(for input: [ConversationLayoutInput]) throws -> [ConversationRow] {
        var result: [ConversationRow] = []
        var nextCache: [String: (input: ConversationLayoutInput, chunks: [MessageChunk])] = [:]
        for item in input {
            try Task.checkCancellation()
            let message = item.message
            if message.isUser {
                result.append(ConversationRow(id: message.id + ":user", message: message, kind: .user))
            } else {
                let chunks: [MessageChunk]
                if let previous = cached[message.id], previous.input == item {
                    chunks = previous.chunks
                } else {
                    chunks = try MessageChunkParser.parse(message.content,
                        streaming: ["streaming", "running"].contains(message.status), tasks: item.tasks)
                }
                nextCache[message.id] = (item, chunks)
                result.append(ConversationRow(id: message.id + ":header", message: message, kind: .header))
                result.append(ConversationRow(id: message.id + ":activity", message: message, kind: .activity))
                result.append(contentsOf: chunks.map {
                    ConversationRow(id: message.id + ":body:" + $0.id, message: message, kind: .chunk($0))
                })
                if !message.attachments.isEmpty {
                    result.append(ConversationRow(id: message.id + ":attachments", message: message, kind: .attachments))
                }
                if ["failed", "stopped"].contains(message.status) ||
                    (message.content.isEmpty && ["queued", "running", "streaming"].contains(message.status)) {
                    result.append(ConversationRow(id: message.id + ":status", message: message, kind: .status))
                }
            }
        }
        cached = nextCache
        return result
    }
}

struct NativeMessageChunk: View {
    let chunk: MessageChunk
    var onSelectionChange: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var onOpenSource: ((URL) -> Bool)?
    var taskState: MessageTaskState?
    var taskMutationPending = false
    var onToggleTask: ((MessageTaskItem, Bool) -> Void)?
    @Environment(\.theaterPalette) private var palette
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 17

    var body: some View {
        Group {
            switch chunk.kind {
            case .native:
                NativeTextRun(source: chunk.source, isNight: palette.isDark, fontSize: fontSize,
                              onSelectionChange: onSelectionChange, onOpenSource: onOpenSource)
            case .code:
                NativeCodeBlock(code: chunk.source, language: chunk.language, fontSize: fontSize,
                                onSelectionChange: onSelectionChange)
            case .complex:
                ComplexMessageIsland(chunk: chunk, isNight: palette.isDark, fontSize: fontSize,
                                     onSelectionChange: onSelectionChange, onLayoutChange: onLayoutChange, onOpenSource: onOpenSource)
            case .task:
                if let state = taskState, let item = state.items.first(where: { $0.index == chunk.taskIndex }) {
                    HStack(alignment: .top, spacing: 7) {
                        Button {
                            onSelectionChange?()
                            onToggleTask?(item, !state.checked(item))
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6).fill(state.checked(item) ? palette.rose : Color.clear)
                                RoundedRectangle(cornerRadius: 6).stroke(state.checked(item) ? palette.rose : palette.secondary, lineWidth: 1.2)
                                if state.checked(item) {
                                    Path { path in
                                        path.move(to: CGPoint(x: 5, y: 11))
                                        path.addLine(to: CGPoint(x: 9, y: 15))
                                        path.addLine(to: CGPoint(x: 17, y: 6))
                                    }.stroke(palette.onAccent, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                                }
                            }.frame(width: 22, height: 22).frame(width: 44, height: 44)
                        }.buttonStyle(.plain)
                            .disabled(!state.editable || taskMutationPending || onToggleTask == nil)
                            .accessibilityLabel(item.text)
                            .accessibilityValue(state.checked(item) ? "已完成" : "未完成")
                        Group {
                            if chunk.language == "inline-math" {
                                ComplexMessageIsland(chunk: chunk, isNight: palette.isDark, fontSize: fontSize,
                                                     onSelectionChange: onSelectionChange, onLayoutChange: onLayoutChange,
                                                     onOpenSource: onOpenSource)
                            } else {
                                NativeTextRun(source: item.text, isNight: palette.isDark, fontSize: fontSize,
                                              onSelectionChange: onSelectionChange, onOpenSource: onOpenSource)
                            }
                        }.padding(.top, 8)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MessageChunk: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case native, code, complex, task }
    var id: String
    var kind: Kind
    var source: String
    var language: String = ""
    var incomplete = false
    var taskIndex: Int?
}

enum MessageChunkParser {
    static func parse(_ source: String, streaming: Bool, tasks: [MessageTaskItem] = []) throws -> [MessageChunk] {
        try Task.checkCancellation()
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let mappedTasks = tasks.filter { item in
            guard let start = item.sourceStartLine, let end = item.sourceEndLine else { return false }
            return start >= 0 && end > start && end <= lines.count
                && tasks.filter({ $0.sourceStartLine == start }).count == 1
        }
        let footnotes = try footnoteDefinitions(lines)
        var lineOffsets = [Int: Int]()
        var result: [MessageChunk] = [], native: [String] = []
        var nativeStart = 0, nativeStartOffset = 0, index = 0, nativeCount = 0
        func flushNative() {
            let value = native.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !value.isEmpty { result.append(MessageChunk(id: "native-\(nativeStart)-\(nativeStartOffset)", kind: .native, source: value)) }
            native.removeAll(keepingCapacity: true); nativeCount = 0
        }
        func appendNative(_ line: String, at position: Int) {
            if native.isEmpty { nativeStart = position; nativeStartOffset = lineOffsets[position, default: 0] }
            native.append(line); nativeCount += line.utf16.count + 1
        }
        while index < lines.count {
            try Task.checkCancellation()
            if lineOffsets[index, default: 0] == 0,
               let item = mappedTasks.first(where: { $0.sourceStartLine == index }), let end = item.sourceEndLine {
                flushNative()
                let math = try normalizedInlineMath(item.text, streaming: false)
                result.append(MessageChunk(id: "task-\(item.index)", kind: .task,
                    source: math.hasFormula ? math.text : item.text,
                    language: math.hasFormula ? "inline-math" : "", taskIndex: item.index))
                index = end
                continue
            }
            if footnotes.indices.contains(index) { index += 1; continue }
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if let opening = fence(line) {
                flushNative()
                let start = index, offset = lineOffsets[index, default: 0]; index += 1
                var body: [String] = [], closed = false
                while index < lines.count {
                    try Task.checkCancellation()
                    if closesFence(lines[index], marker: opening.marker, count: opening.count) { closed = true; index += 1; break }
                    body.append(lines[index]); index += 1
                }
                let code = body.joined(separator: "\n"), language = opening.language.lowercased()
                if ["mermaid", "echarts", "abc"].contains(language) {
                    let marker = String(repeating: opening.marker, count: opening.count)
                    result.append(MessageChunk(id: "complex-\(start)-\(offset)", kind: .complex,
                                               source: marker + language + "\n" + code + "\n" + marker,
                                               language: language, incomplete: !closed && streaming))
                } else if ["math", "latex", "tex"].contains(language) {
                    result.append(MessageChunk(id: "complex-\(start)-\(offset)", kind: .complex, source: "$$\n" + code + "\n$$",
                                               language: "math", incomplete: !closed && streaming))
                } else {
                    result.append(MessageChunk(id: "code-\(start)-\(offset)", kind: .code, source: code, language: opening.language,
                                               incomplete: !closed && streaming))
                }
                continue
            }
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                flushNative()
                let start = index, offset = lineOffsets[index, default: 0], closing = trimmed.hasPrefix("$$") ? "$$" : "\\]"
                let first = String(trimmed.dropFirst(2))
                var body: [String] = [], closed = false
                if let end = first.range(of: closing) {
                    body = [String(first[..<end.lowerBound])]; closed = true
                    let suffix = String(first[end.upperBound...])
                    if suffix.trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
                    else { lineOffsets[index, default: 0] += lines[index].utf16.count - suffix.utf16.count; lines[index] = suffix }
                } else {
                    body.append(first); index += 1
                    while index < lines.count {
                        try Task.checkCancellation()
                        if let end = lines[index].range(of: closing) {
                            body.append(String(lines[index][..<end.lowerBound])); closed = true
                            let suffix = String(lines[index][end.upperBound...])
                            if suffix.trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
                            else { lineOffsets[index, default: 0] += lines[index].utf16.count - suffix.utf16.count; lines[index] = suffix }
                            break
                        }
                        body.append(lines[index]); index += 1
                    }
                }
                result.append(MessageChunk(id: "complex-\(start)-\(offset)", kind: .complex,
                                           source: "$$\n" + body.joined(separator: "\n") + "\n$$", language: "math", incomplete: !closed && streaming))
                continue
            }
            if trimmed.lowercased().hasPrefix("<details") {
                flushNative()
                let start = index, offset = lineOffsets[index, default: 0]; var depth = 0, block: [String] = []
                repeat {
                    try Task.checkCancellation()
                    let value = lines[index].lowercased()
                    if value.contains("<details") { depth += 1 }
                    if value.contains("</details>") { depth -= 1 }
                    block.append(lines[index]); index += 1
                } while index < lines.count && depth > 0
                result.append(MessageChunk(id: "complex-\(start)-\(offset)", kind: .complex, source: block.joined(separator: "\n"), language: "details", incomplete: depth > 0 && streaming))
                continue
            }
            if index + 1 < lines.count, line.contains("|"), isTableDivider(lines[index + 1]) {
                flushNative()
                let start = index, offset = lineOffsets[index, default: 0]; var block = [line, lines[index + 1]]; index += 2
                while index < lines.count && lines[index].contains("|") && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    try Task.checkCancellation()
                    block.append(lines[index]); index += 1
                }
                result.append(MessageChunk(id: "complex-\(start)-\(offset)", kind: .complex, source: block.joined(separator: "\n"), language: "table"))
                continue
            }
            if trimmed.isEmpty {
                appendNative(line, at: index); index += 1
                if nativeCount >= 6000 { flushNative() }
                continue
            }
            // A paragraph containing a true inline formula remains a single
            // rich island, preserving formula/text baselines and punctuation.
            var paragraph = [line], next = index + 1
            while next < lines.count && !lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
                try Task.checkCancellation()
                if footnotes.indices.contains(next) || fence(lines[next]) != nil || lines[next].trimmingCharacters(in: .whitespaces).hasPrefix("$$") ||
                    (next + 1 < lines.count && lines[next].contains("|") && isTableDivider(lines[next + 1])) { break }
                paragraph.append(lines[next]); next += 1
            }
            let paragraphText = paragraph.joined(separator: "\n")
            let inlineMath = try normalizedInlineMath(paragraphText, streaming: streaming && next == lines.count)
            let hasFootnote = paragraphText.range(of: #"\[\^[^\]]+\]"#, options: .regularExpression) != nil
            let isAlert = paragraphText.range(of: #"(?m)^ {0,3}>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]"#, options: .regularExpression) != nil
            if inlineMath.hasFormula || hasFootnote || isAlert {
                flushNative()
                let rendered = inlineMath.text + (hasFootnote ? "\n\n" + footnotes.source : "")
                result.append(MessageChunk(id: "complex-\(index)-\(lineOffsets[index, default: 0])", kind: .complex, source: rendered, language: "inline-math", incomplete: inlineMath.incomplete))
                index = next
                continue
            }
            if streaming && index == lines.count - 1 && ["`", "``", "~", "~~", "$$", "\\["].contains(trimmed) {
                index += 1; continue
            }
            for (offset, value) in paragraph.enumerated() {
                let position = index + offset
                if streaming && position == lines.count - 1 && ["`", "``", "~", "~~"].contains(value.trimmingCharacters(in: .whitespaces)) { continue }
                if nativeCount >= 4500 && isHeading(value) { flushNative() }
                appendNative(value, at: position)
            }
            index = next
        }
        flushNative()
        return result
    }

    private struct Fence { var marker: String; var count: Int; var language: String }
    private static func fence(_ line: String) -> Fence? {
        let leading = line.prefix { $0 == " " }.count
        guard leading <= 3 else { return nil }
        let trimmed = String(line.dropFirst(leading))
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        let info = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        guard first != "`" || !info.contains("`") else { return nil }
        return Fence(marker: String(first), count: count, language: String(info.split(whereSeparator: \.isWhitespace).first ?? ""))
    }
    private static func closesFence(_ line: String, marker: String, count: Int) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard let first = marker.first else { return false }
        let actual = value.prefix { $0 == first }.count
        return actual >= count && value.dropFirst(actual).trimmingCharacters(in: .whitespaces).isEmpty
    }
    private static func isTableDivider(_ line: String) -> Bool {
        line.range(of: #"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$"#, options: .regularExpression) != nil
    }
    private static func isHeading(_ line: String) -> Bool {
        line.range(of: #"^ {0,3}#{1,6}\s+"#, options: .regularExpression) != nil
    }
    private static func footnoteDefinitions(_ lines: [String]) throws -> (source: String, indices: Set<Int>) {
        var definitions: [String] = [], indices = Set<Int>(), openFence: Fence?
        var index = 0
        while index < lines.count {
            try Task.checkCancellation()
            if let current = openFence {
                if closesFence(lines[index], marker: current.marker, count: current.count) { openFence = nil }
                index += 1; continue
            }
            if let current = fence(lines[index]) { openFence = current; index += 1; continue }
            if lines[index].range(of: #"^ {0,3}\[\^[^\]]+\]:\s*"#, options: .regularExpression) != nil {
                repeat {
                    try Task.checkCancellation()
                    definitions.append(lines[index]); indices.insert(index); index += 1
                } while index < lines.count && (lines[index].hasPrefix("    ") || lines[index].hasPrefix("\t"))
                definitions.append("")
            } else { index += 1 }
        }
        return (definitions.joined(separator: "\n"), indices)
    }
    private static func normalizedInlineMath(_ text: String, streaming: Bool) throws -> (text: String, hasFormula: Bool, incomplete: Bool) {
        let characters = Array(text)
        var index = 0, codeTicks = 0, output = "", found = false
        while index < characters.count {
            if index % 128 == 0 { try Task.checkCancellation() }
            if characters[index] == "`" {
                var end = index
                while end < characters.count && characters[end] == "`" { end += 1 }
                let run = end - index
                if codeTicks == 0 { codeTicks = run } else if codeTicks == run { codeTicks = 0 }
                output += String(characters[index..<end])
                index = end; continue
            }
            if codeTicks > 0 { output.append(characters[index]); index += 1; continue }
            if characters[index] == "\\" {
                if index + 1 < characters.count && characters[index + 1] == "(" {
                    var end = index + 2
                    while end + 1 < characters.count && !(characters[end] == "\\" && characters[end + 1] == ")") {
                        if end % 128 == 0 { try Task.checkCancellation() }; end += 1
                    }
                    if end + 1 < characters.count {
                        output += "$" + String(characters[(index + 2)..<end]) + "$"; found = true; index = end + 2; continue
                    } else if streaming { return (output, true, true) }
                }
                output.append(characters[index])
                if index + 1 < characters.count { output.append(characters[index + 1]) }
                index += 2; continue
            }
            if characters[index] == "$", index + 1 < characters.count, characters[index + 1] == "$" {
                var end = index + 2
                while end + 1 < characters.count {
                    if end % 128 == 0 { try Task.checkCancellation() }
                    if characters[end] == "\\" { end += 2; continue }
                    if characters[end] == "$" && characters[end + 1] == "$" { break }
                    end += 1
                }
                if end + 1 < characters.count {
                    output += "\n\n$$\n" + String(characters[(index + 2)..<end]) + "\n$$\n\n"
                    found = true; index = end + 2; continue
                } else if streaming { return (output, true, true) }
                output += "\\$\\$"; index += 2; continue
            }
            if characters[index] == "$", index + 1 < characters.count,
               characters[index + 1] != "$", !characters[index + 1].isWhitespace {
                var end = index + 1
                while end < characters.count && characters[end] != "\n" {
                    if end % 128 == 0 { try Task.checkCancellation() }
                    if characters[end] == "\\" { end += 2; continue }
                    if characters[end] == "$" {
                        let content = String(characters[(index + 1)..<end])
                        let tailIsDigit = end + 1 < characters.count && characters[end + 1].isNumber
                        if end > index + 1 && !characters[end - 1].isWhitespace && !tailIsDigit {
                            output += "$" + content + "$"; found = true; index = end + 1
                            break
                        }
                        break
                    }
                    end += 1
                }
                if index == end + 1 { continue }
                if end >= characters.count && streaming {
                    let tail = String(characters[(index + 1)...])
                    let shellOrMoney = tail.range(of: #"^(?:[A-Z_][A-Z_0-9]*|[\d.,]+)$"#, options: .regularExpression) != nil
                    if !shellOrMoney && !tail.isEmpty { return (output, true, true) }
                }
                output += "\\$"; index += 1; continue
            }
            output.append(characters[index])
            index += 1
        }
        return (output, found, false)
    }
}

private struct ComplexMessageIsland: View {
    let chunk: MessageChunk
    let isNight: Bool
    let fontSize: CGFloat
    let onSelectionChange: (() -> Void)?
    let onLayoutChange: (() -> Void)?
    let onOpenSource: ((URL) -> Bool)?
    @State private var height: CGFloat = 60
    @State private var visible = false
    var body: some View {
        Group {
            if visible {
                RichDocumentView(text: chunk.source, isNight: isNight, contentHeight: $height,
                                 fontSize: fontSize, isIncomplete: chunk.incomplete, onSelectionChange: onSelectionChange, onOpenSource: onOpenSource)
            } else { Color.clear }
        }.frame(maxWidth: .infinity).frame(height: max(24, height))
            .onAppear { visible = true }.onDisappear { visible = false }
            .onChange(of: height) { _, _ in onLayoutChange?() }
    }
}

private struct NativeCodeBlock: View {
    let code: String
    let language: String
    let fontSize: CGFloat
    let onSelectionChange: (() -> Void)?
    @Environment(\.theaterPalette) private var palette
    @State private var expanded = false
    private var lines: [String] { code.components(separatedBy: "\n") }
    private var displayed: String { lines.count > 30 && !expanded ? lines.prefix(16).joined(separator: "\n") : code }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.dim)
                Spacer()
                Button("复制") { UIPasteboard.general.string = code }.font(.system(size: 12)).foregroundStyle(palette.rose)
            }.padding(.horizontal, 13).frame(height: 38)
            ScrollView(.horizontal) {
                NativeTextRun(source: displayed, isNight: palette.isDark, fontSize: max(13, fontSize - 3),
                              codeOnly: true, onSelectionChange: onSelectionChange)
                    .frame(width: codeWidth).padding(.horizontal, 13).padding(.bottom, 13)
            }.scrollIndicators(.visible)
            if lines.count > 30 {
                Button(expanded ? "收起代码" : "展开全部 \(lines.count) 行") { expanded.toggle() }
                    .font(.system(size: 12)).padding(.horizontal, 13).frame(height: 38)
            }
        }.background(palette.sunken, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.line, lineWidth: 0.6))
    }
    private var codeWidth: CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: max(13, fontSize - 3), weight: .regular)
        return max(120, lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 120) + 3
    }
}

/// TextKit2 owns each continuous run. Never access `layoutManager`, which would
/// force the compatibility text engine and lose current system selection.
private struct NativeTextRun: UIViewRepresentable {
    let source: String
    let isNight: Bool
    let fontSize: CGFloat
    var codeOnly = false
    var onSelectionChange: (() -> Void)?
    var onOpenSource: ((URL) -> Bool)?
    @Environment(\.openURL) private var openURL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITextView {
        let view = MeasuredMessageTextView(usingTextLayoutManager: true)
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onOpenURL = { url in
            if onOpenSource?(url) == true { return }
            if url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil { openURL(url) }
        }
        let key = NativeTextTypography.key(source, fontSize: fontSize, isNight: isNight, code: codeOnly)
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        let attributed = NativeTextTypography.render(source, fontSize: fontSize, isNight: isNight, code: codeOnly)
        let selected = view.selectedRange
        context.coordinator.updating = true
        view.textStorage.setAttributedString(attributed)
        if selected.location != NSNotFound && NSMaxRange(selected) <= attributed.length { view.selectedRange = selected }
        view.linkTextAttributes = [.foregroundColor: UIColor(TheaterPalette(isDark: isNight).blue), .underlineStyle: NSUnderlineStyle.single.rawValue]
        context.coordinator.updating = false
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        // Stacks probe children with an unbounded width before their final
        // finite layout. Leave that probe to UIKit rather than integer-keying it.
        guard let width = proposal.width, width.isFinite, width > 0,
              width < CGFloat(Int.max / 4) else { return nil }
        let key = (context.coordinator.key ?? NativeTextTypography.key(source, fontSize: fontSize, isNight: isNight, code: codeOnly)) + ":w\(Int((width * 2).rounded()))"
        if let cached = MessageMeasuredHeights.shared.value(for: key) { return CGSize(width: width, height: cached) }
        let height = ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        MessageMeasuredHeights.shared.insert(height, for: key)
        return CGSize(width: width, height: height)
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var key: String?
        var updating = false
        var onSelectionChange: (() -> Void)?
        var onOpenURL: ((URL) -> Void)?
        func textViewDidChangeSelection(_ textView: UITextView) {
            if !updating && textView.selectedRange.length > 0 { onSelectionChange?() }
        }
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            if interaction == .invokeDefaultAction { onOpenURL?(URL) }
            return false
        }
    }
}

/// SwiftUI owns the measured height. TextKit's intrinsic-size invalidations can
/// otherwise re-enter the surrounding lazy stack while a streamed line wraps.
private final class MeasuredMessageTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}

@MainActor
enum NativeTextTypography {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let value = NSCache<NSString, NSAttributedString>(); value.countLimit = 128; value.totalCostLimit = 4 * 1024 * 1024; return value
    }()
    static func key(_ source: String, fontSize: CGFloat, isNight: Bool, code: Bool) -> String {
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return "native-v1:\(digest):\(fontSize):\(isNight):\(code)"
    }
    static func render(_ source: String, fontSize: CGFloat, isNight: Bool, code: Bool = false) -> NSAttributedString {
        let cacheKey = key(source, fontSize: fontSize, isNight: isNight, code: code)
        if let found = cache.object(forKey: cacheKey as NSString) { return found }
        let palette = TheaterPalette(isDark: isNight)
        let textColor = UIColor(palette.text), secondary = UIColor(palette.secondary)
        if code {
            let style = NSMutableParagraphStyle(); style.lineSpacing = 4; style.lineBreakMode = .byClipping
            let value = NSAttributedString(string: source, attributes: [.font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), .foregroundColor: textColor, .paragraphStyle: style])
            cache.setObject(value, forKey: cacheKey as NSString, cost: value.length * 4); return value
        }
        let parsed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full))) ?? AttributedString(source)
        let result = NSMutableAttributedString(string: "")
        var lastBlock: Int?, seenListItems = Set<Int>()
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            var blockID: Int?, header = 0, quote = false, ordered = false, depth = 0, listKindChosen = false
            var itemID: Int?, ordinal = 1, blockCode = false, thematic = false
            for component in components {
                switch component.kind {
                case .header(let level): header = level; blockID = component.identity
                case .paragraph: if blockID == nil { blockID = component.identity }
                case .blockQuote: quote = true
                case .orderedList:
                    if !listKindChosen { ordered = true; listKindChosen = true }; depth += 1
                case .unorderedList:
                    if !listKindChosen { ordered = false; listKindChosen = true }; depth += 1
                case .listItem(let number):
                    if itemID == nil { itemID = component.identity; ordinal = number }
                case .codeBlock: blockCode = true; blockID = component.identity
                case .thematicBreak: thematic = true; blockID = component.identity
                default: break
                }
            }
            let freshBlock = blockID != lastBlock
            if freshBlock && result.length > 0 && !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n")) }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = fontSize * 0.32; style.paragraphSpacing = fontSize * 0.65
            style.lineBreakMode = .byWordWrapping
            if quote { style.headIndent = 15; style.firstLineHeadIndent = 15 }
            if depth > 0 { style.headIndent = CGFloat(depth * 18 + 12); style.firstLineHeadIndent = CGFloat(max(0, depth - 1) * 18) }
            var size = fontSize, weight = UIFont.Weight.regular
            if header > 0 { size += CGFloat(max(0, 7 - header)) * 1.4; weight = .semibold; style.paragraphSpacingBefore = fontSize * 0.45 }
            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.stronglyEmphasized) { weight = .semibold }
            var font = blockCode || inline.contains(.code) ? UIFont.monospacedSystemFont(ofSize: size * 0.88, weight: weight) : UIFont.systemFont(ofSize: size, weight: weight)
            if inline.contains(.emphasized), let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) { font = UIFont(descriptor: descriptor, size: size) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: quote ? secondary : textColor, .paragraphStyle: style]
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if inline.contains(.code) || blockCode { attributes[.backgroundColor] = UIColor(palette.blueSoft) }
            if let link = run.link { attributes[.link] = link }
            if let itemID, !seenListItems.contains(itemID) {
                seenListItems.insert(itemID)
                result.append(NSAttributedString(string: ordered ? "\(ordinal). " : "• ", attributes: attributes))
            }
            let characters = String(parsed[run.range].characters)
            result.append(NSAttributedString(string: thematic ? "――――" : characters, attributes: attributes))
            lastBlock = blockID
        }
        cache.setObject(result, forKey: cacheKey as NSString, cost: result.length * 4)
        return result
    }
}

@MainActor
final class MessageMeasuredHeights {
    static let shared = MessageMeasuredHeights()
    private let cache = NSCache<NSString, NSNumber>()
    private init() { cache.countLimit = 768 }
    func value(for key: String) -> CGFloat? { cache.object(forKey: key as NSString).map { CGFloat(truncating: $0) } }
    func insert(_ value: CGFloat, for key: String) {
        guard value.isFinite, value > 0 else { return }
        cache.setObject(NSNumber(value: Double(value)), forKey: key as NSString)
    }
}

/// One continuous native text surface is available for selection spanning
/// different islands. It supplements, rather than pretends to remove, the
/// system boundary between independent TextKit and WebKit selections.
struct NativeMessageSelectionView: View {
    let text: String
    @Environment(\.theaterPalette) private var palette
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 17
    var body: some View {
        TheaterPanel(title: "选择整条文字") {
            ScrollView {
                NativeTextRun(source: text, isNight: palette.isDark, fontSize: fontSize)
                    .padding(25).frame(maxWidth: 800).frame(maxWidth: .infinity)
            }
        }
    }
}
