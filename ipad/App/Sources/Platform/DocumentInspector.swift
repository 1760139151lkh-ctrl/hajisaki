import SwiftUI
import UIKit
import PDFKit
import QuickLook
import UniformTypeIdentifiers
import ImageIO

/// Receives an authenticated, downloaded file URL. It never fetches a host path.
struct DocumentInspector: View {
    let url: URL
    let title: String
    let page: Int?
    let libraryScope: String
    @ObservedObject var interactiveSession: InteractiveDocumentSession
    @ObservedObject var markdownSession: MarkdownDocumentSession
    var fileSHA256: String? = nil
    var line: Int? = nil
    var endLine: Int? = nil
    var initialSoftLight = false
    var onDigestResolved: ((String) -> Void)? = nil
    var onPageChange: ((Int) -> Void)? = nil
    var onSoftLightChange: ((Bool) -> Void)? = nil
    var onShare: ((URL) -> Void)? = nil
    var onOpenSource: ((URL) -> Bool)? = nil
    @Environment(\.theaterPalette) private var palette
    @ScaledMetric(relativeTo: .body) private var readingFontSize: CGFloat = 17
    @State private var selectedPage = 1
    @State private var pageCount = 0
    @State private var softLight = false
    @State private var kind: InspectorFileKind = .loading
    @State private var textChunk = ""
    @State private var textOffset: UInt64 = 0
    @State private var nextOffset: UInt64 = 0
    @State private var priorOffsets: [UInt64] = []
    @State private var priorLines: [Int] = []
    @State private var textStartLine = 1
    @State private var locationNotice: String?
    @State private var loadID = UUID()
    @State private var focusLoadTask: Task<Void, Never>?
    @State private var fileSize: UInt64 = 0
    @State private var image: UIImage?
    @State private var error: String?
    @State private var annotation: AnnotationDocument?
    @State private var resolvedDigest: String?
    @State private var preparingAnnotation = false
    @State private var annotationTask: Task<Void, Never>?
    @State private var exportedDocument: ExportedDocument?
    @State private var preparingExport = false
    @State private var exportTask: Task<Void, Never>?
    @State private var interactiveHTML = ""
    @State private var showsSource = false
    @State private var markdownText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                Spacer(minLength: 8)
                if kind == .interactive || kind == .markdown {
                    Button(sourceVisible ? "预览" : "源码") {
                        if !sourceVisible {
                            do { try readChunk(at: 0) }
                            catch { self.error = "源码暂时没能展开，原件仍可导出。"; return }
                        } else if kind == .interactive {
                            interactiveSession.retryAfterFailure()
                        }
                        error = nil
                        sourceVisible.toggle()
                    }
                }
                if kind == .pdf || kind == .image {
                    Button(softLight ? "原色" : "柔光") { softLight.toggle() }
                    if onShare != nil {
                        Button { beginAnnotation() } label: {
                            if preparingAnnotation { ProgressView().controlSize(.small) }
                            else { Text("批注") }
                        }.disabled(preparingAnnotation).accessibilityLabel("批注这一页")
                    }
                }
                Button { exportOriginal() } label: {
                    if preparingExport { ProgressView().controlSize(.small) }
                    else { Text("导出") }
                }.disabled(preparingExport).accessibilityLabel("保存原件到文件")
            }.font(.system(size: 13)).padding(14)
            Divider()
            if let locationNotice {
                Text(locationNotice).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            Group {
                if let error {
                    VStack(spacing: 14) {
                        Text(error).multilineTextAlignment(.center)
                        Button("重新展开") { interactiveSession.retryAfterFailure(); load() }
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if softLight && (kind == .pdf || kind == .image) { content.colorInvert() }
                    else { content }
                }
            }
            .overlay { if softLight && (kind == .pdf || kind == .image) { Color(red: 0.06, green: 0.10, blue: 0.18).opacity(0.19).allowsHitTesting(false) } }
            if kind == .pdf && pageCount > 0 {
                HStack {
                    Button("上一页") { selectedPage -= 1 }.disabled(selectedPage <= 1)
                    Spacer()
                    Text("\(selectedPage) / \(pageCount)").monospacedDigit()
                    Spacer()
                    Button("下一页") { selectedPage += 1 }.disabled(selectedPage >= pageCount)
                }.font(.system(size: 13)).padding(12)
            }
            if (kind == .text || ((kind == .interactive || kind == .markdown) && sourceVisible)) && (textOffset > 0 || nextOffset < fileSize) {
                HStack {
                    Button(priorOffsets.isEmpty ? "回到开头" : "上一段") { previousChunk() }.disabled(priorOffsets.isEmpty && textOffset == 0)
                    Spacer()
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(nextOffset), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))")
                        .font(.caption).monospacedDigit()
                    Spacer()
                    Button("下一段") { nextChunk() }.disabled(nextOffset >= fileSize)
                }.font(.system(size: 13)).padding(12)
            }
        }
        .task(id: url) { load() }
        .onDisappear { focusLoadTask?.cancel(); annotationTask?.cancel(); exportTask?.cancel(); loadID = UUID() }
        .onChange(of: page) { _, value in
            if let value { selectedPage = max(1, min(max(1, pageCount), value)) }
        }
        .onChange(of: selectedPage) { _, value in
            onPageChange?(value)
            if preparingAnnotation { annotationTask?.cancel(); preparingAnnotation = false }
        }
        .onChange(of: softLight) { _, value in onSoftLightChange?(value) }
        .sheet(item: $annotation) { item in
            NavigationStack {
                ScratchpadView(conversationID: item.id, onShare: { exported in
                    onShare?(exported); annotation = nil
                }, backgroundImage: item.image)
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { annotation = nil } } }
            }
        }
        .sheet(item: $exportedDocument) { document in
            NativeDocumentExport(url: document.url, onFinish: { exportedDocument = nil })
        }
    }

    private var sourceVisible: Bool {
        get { kind == .markdown ? markdownSession.showsSource : showsSource }
        nonmutating set {
            if kind == .markdown { markdownSession.showsSource = newValue }
            else { showsSource = newValue }
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .pdf:
            NativePDFView(url: url, selectedPage: $selectedPage, pageCount: $pageCount, focusPage: page)
        case .image:
            if let image { ZoomableImageView(image: image) }
        case .text:
            SelectableSourceView(text: textChunk, isDiff: ["diff", "patch"].contains(url.pathExtension.lowercased()),
                                 firstLine: textStartLine, focusLine: line, endLine: endLine)
        case .markdown:
            ZStack {
                if sourceVisible {
                    SelectableSourceView(text: textChunk, isDiff: false, firstLine: textStartLine, focusLine: nil, endLine: nil)
                } else {
                    MarkdownDocumentView(session: markdownSession, text: markdownText, isNight: palette.isDark,
                                         fontSize: readingFontSize, onOpenSource: onOpenSource)
                        .padding(16)
                    if markdownSession.isLoading { ProgressView().tint(.secondary).allowsHitTesting(false) }
                }
            }
        case .interactive:
            if showsSource {
                SelectableSourceView(text: textChunk, isDiff: false, firstLine: textStartLine, focusLine: nil, endLine: nil)
            } else {
                ZStack {
                    InteractiveDocumentView(html: interactiveHTML, session: interactiveSession, onFailure: {
                        error = "这份小剧场暂时没能展开，原件仍可导出。"
                    })
                    if interactiveSession.isLoading { ProgressView().tint(.secondary).allowsHitTesting(false) }
                }
            }
        case .other:
            NativeFilePreview(url: url, title: title)
        }
    }

    private func load() {
        focusLoadTask?.cancel()
        annotationTask?.cancel(); preparingAnnotation = false; resolvedDigest = fileSHA256
        exportTask?.cancel(); preparingExport = false
        softLight = initialSoftLight
        let requestID = UUID(); loadID = requestID
        kind = .loading; error = nil; locationNotice = nil; textOffset = 0; priorOffsets = []; priorLines = []; textStartLine = 1; image = nil; pageCount = 0; showsSource = false; interactiveHTML = ""; markdownText = ""
        guard url.isFileURL else { error = "先把这份文件接到琴房，再一起看。"; return }
        guard FileManager.default.isReadableFile(atPath: url.path) else { error = "这份文件还没能展开，请重新下载。"; return }
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let markdown = ["md", "markdown"].contains(ext) && line == nil
        if ["html", "htm"].contains(ext) || markdown {
            let sourceURL = url
            focusLoadTask = Task {
                do {
                    let work = Task.detached(priority: .userInitiated) {
                        let input = try FileHandle(forReadingFrom: sourceURL)
                        defer { try? input.close() }
                        let data = try input.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
                        guard data.count <= 2 * 1024 * 1024, let html = String(data: data, encoding: .utf8) else {
                            throw CocoaError(.fileReadInapplicableStringEncoding)
                        }
                        try Task.checkCancellation()
                        return (html, UInt64(data.count))
                    }
                    let loaded = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                    guard loadID == requestID else { return }
                    fileSize = loaded.1
                    if markdown {
                        markdownText = loaded.0
                        if markdownSession.showsSource { try readChunk(at: 0) }
                        kind = .markdown
                    }
                    else { interactiveHTML = loaded.0; kind = .interactive }
                } catch is CancellationError { }
                catch {
                    guard loadID == requestID else { return }
                    if markdown {
                        do {
                            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                            fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                            try readChunk(at: 0); kind = .text
                            locationNotice = "这份笔记先分段展开原文。"
                        } catch { self.error = "这份笔记暂时没能展开，原件仍可导出。" }
                    } else {
                        self.error = "这份小剧场暂时无法展开。请选用2MiB以内的UTF-8独立页面，原件仍可导出。"
                    }
                }
            }
        } else if ext == "pdf" {
            guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                error = "这份 PDF 暂时没能展开，原件仍可导出。"; return
            }
            selectedPage = max(1, min(document.pageCount, page ?? 1)); kind = .pdf
            if let page, page > document.pageCount { locationNotice = "原件只有 \(document.pageCount) 页，先停在最后一页。" }
        } else if type?.conforms(to: .image) == true {
            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
                  let preview = CGImageSourceCreateThumbnailAtIndex(source, 0,
                    [kCGImageSourceCreateThumbnailFromImageAlways: true,
                     kCGImageSourceCreateThumbnailWithTransform: true,
                     kCGImageSourceThumbnailMaxPixelSize: 3000] as CFDictionary) else {
                error = "这张图暂时没能展开，原件仍可导出。"; return
            }
            image = UIImage(cgImage: preview); kind = .image
        } else if type?.conforms(to: .text) == true || Self.textExtensions.contains(ext) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                if let line {
                    let targetURL = url
                    focusLoadTask = Task {
                        do {
                            let work = Task.detached(priority: .userInitiated) {
                                try Self.position(before: line, in: targetURL)
                            }
                            let position = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                            guard loadID == requestID else { return }
                            try readChunk(at: position.offset, firstLine: position.line)
                            kind = .text
                            let lastLine = textStartLine + textChunk.filter { $0 == "\n" }.count
                            if !position.found || line > lastLine { locationNotice = "原件中没有第 \(line) 行。" }
                        } catch {
                            guard loadID == requestID else { return }
                            self.error = "这处文字暂时没能展开，原件仍可导出。"
                        }
                    }
                } else { try readChunk(at: 0); kind = .text }
            } catch { self.error = "这份文字暂时没能展开，原件仍可导出。" }
        } else { kind = .other }
    }

    private func beginAnnotation() {
        if let digest = resolvedDigest ?? fileSHA256 { presentAnnotation(digest: digest); return }
        let request = loadID, requestedPage = selectedPage
        preparingAnnotation = true
        annotationTask = Task {
            defer { if request == loadID { preparingAnnotation = false } }
            do {
                let digest = try await GatewayClient.backgroundDigest(url)
                try Task.checkCancellation()
                guard request == loadID, requestedPage == selectedPage else { return }
                resolvedDigest = digest; onDigestResolved?(digest)
                presentAnnotation(digest: digest)
            } catch is CancellationError { }
            catch { if request == loadID { self.error = "这份原件暂时没能展开批注，原稿还在。" } }
        }
    }
    private func exportOriginal() {
        let original = url, filename = GatewayClient.safeName(title), request = loadID
        preparingExport = true
        exportTask = Task {
            defer { if request == loadID { preparingExport = false } }
            do {
                let work = Task.detached(priority: .userInitiated) {
                    let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                               appropriateFor: nil, create: true)
                        .appendingPathComponent("DocumentExports", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = directory.appendingPathComponent(filename)
                    var coordinationError: NSError?
                    var copyError: Error?
                    NSFileCoordinator().coordinate(readingItemAt: original, options: .withoutChanges, error: &coordinationError) { source in
                        do { try FileManager.default.copyItem(at: source, to: destination) }
                        catch { copyError = error }
                    }
                    if let coordinationError { throw coordinationError }
                    if let copyError { throw copyError }
                    try Task.checkCancellation()
                    return destination
                }
                let destination = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                guard request == loadID, !Task.isCancelled else { return }
                exportedDocument = ExportedDocument(url: destination)
            } catch is CancellationError { }
            catch { if request == loadID { self.error = "原件还在，暂时没能递到文件里。" } }
        }
    }
    private func presentAnnotation(digest: String) {
        // File contents and the paired library stay stable when iPadOS relocates
        // its data container during an update. Absolute sandbox URLs do not.
        let identity = "document:v3:library:\(libraryScope):sha256:\(digest)"
        if kind == .image, let image {
            annotation = AnnotationDocument(id: identity + ":image", image: image, title: title)
        } else if kind == .pdf, let document = PDFDocument(url: url), let source = document.page(at: selectedPage - 1) {
            let bounds = source.bounds(for: .cropBox)
            guard bounds.width > 0, bounds.height > 0 else { return }
            let factor = 1800 / max(bounds.width, bounds.height)
            let size = CGSize(width: bounds.width * factor, height: bounds.height * factor)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.scaleBy(x: factor, y: -factor)
                context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                source.draw(with: .cropBox, to: context.cgContext)
            }
            annotation = AnnotationDocument(id: identity + ":page:\(selectedPage)", image: image,
                                            title: "\(title) · 第 \(selectedPage) 页")
        }
    }

    nonisolated private static func position(before target: Int, in url: URL) throws -> (offset: UInt64, line: Int, found: Bool) {
        let first = max(1, target - 8)
        guard first > 1 else { return (0, 1, true) }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var position: UInt64 = 0
        var number = 1
        while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            for (index, byte) in bytes.enumerated() where byte == 10 {
                number += 1
                if number == first { return (position + UInt64(index) + 1, number, true) }
            }
            position += UInt64(bytes.count)
        }
        return (0, 1, false)
    }
    private func readChunk(at offset: UInt64, firstLine: Int = 1) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var bytes = try handle.read(upToCount: 256 * 1024) ?? Data()
        // Keep a UTF-8 code point intact at the boundary; advance by consumed bytes only.
        if offset + UInt64(bytes.count) < fileSize {
            for _ in 0..<4 {
                if String(data: bytes, encoding: .utf8) != nil { break }
                if !bytes.isEmpty { bytes.removeLast() }
            }
        }
        guard let text = String(data: bytes, encoding: .utf8) ?? (offset == 0 && fileSize <= UInt64(bytes.count) ? String(data: bytes, encoding: .utf16) : nil) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        textChunk = text; textOffset = offset; nextOffset = offset + UInt64(bytes.count); textStartLine = firstLine
    }
    private func nextChunk() {
        do {
            let old = textOffset, oldLine = textStartLine
            let followingLine = textStartLine + textChunk.filter { $0 == "\n" }.count
            try readChunk(at: nextOffset, firstLine: followingLine)
            priorOffsets.append(old); priorLines.append(oldLine)
        }
        catch { self.error = "下一段还没能展开，原件仍可导出。" }
    }
    private func previousChunk() {
        guard let offset = priorOffsets.last else {
            do { try readChunk(at: 0) }
            catch { self.error = "开头还没能展开，原件仍可导出。" }
            return
        }
        do { try readChunk(at: offset, firstLine: priorLines.last ?? 1); priorOffsets.removeLast(); priorLines.removeLast() }
        catch { self.error = "上一段还没能展开，原件仍可导出。" }
    }
    private static let textExtensions: Set<String> = ["txt", "md", "log", "py", "js", "ts", "tsx", "jsx", "json", "yml", "yaml", "toml", "xml", "html", "css", "swift", "c", "cpp", "h", "rs", "go", "sql", "diff", "patch", "csv", "tex", "sh", "ps1", "ets"]
}

private struct AnnotationDocument: Identifiable {
    let id: String
    let image: UIImage
    let title: String
}

private struct ExportedDocument: Identifiable {
    let id = UUID()
    let url: URL
}

private struct NativeDocumentExport: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void
    @Environment(\.theaterPalette) private var palette
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.delegate = context.coordinator
        controller.shouldShowFileExtensions = true
        controller.overrideUserInterfaceStyle = palette.isDark ? .dark : .light
        controller.view.backgroundColor = UIColor(palette.background)
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onFinish() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish() }
    }
}

private enum InspectorFileKind: Equatable { case loading, pdf, image, text, markdown, interactive, other }

private struct NativePDFView: UIViewRepresentable {
    let url: URL
    @Binding var selectedPage: Int
    @Binding var pageCount: Int
    let focusPage: Int?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.backgroundColor = UIColor.secondarySystemBackground
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak coordinator = context.coordinator, weak view] _ in
            guard let coordinator, !coordinator.openingDocument, let view, let document = view.document, let page = view.currentPage else { return }
            let number = document.index(for: page) + 1
            coordinator.lastPage = number
            coordinator.parent.selectedPage = number
        }
        return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedURL != url {
            let requestedPage = selectedPage
            context.coordinator.loadedURL = url
            context.coordinator.openingDocument = true
            uiView.document = PDFDocument(url: url)
            let count = uiView.document?.pageCount ?? 0
            DispatchQueue.main.async { pageCount = count }
            context.coordinator.lastPage = nil
            context.coordinator.focusPage = nil
            context.coordinator.focusAnnotation = nil
            DispatchQueue.main.async { [weak uiView, weak coordinator = context.coordinator] in
                guard let uiView, let coordinator, coordinator.loadedURL == url,
                      let document = uiView.document, document.pageCount > 0 else { return }
                let target = max(1, min(document.pageCount, requestedPage))
                uiView.layoutIfNeeded()
                if let page = document.page(at: target - 1) { uiView.go(to: page) }
                coordinator.lastPage = target
                coordinator.parent.selectedPage = target
                coordinator.openingDocument = false
            }
        }
        guard let document = uiView.document, document.pageCount > 0 else { return }
        if context.coordinator.focusPage != focusPage {
            if let old = context.coordinator.focusAnnotation, let page = old.page { page.removeAnnotation(old) }
            context.coordinator.focusAnnotation = nil; context.coordinator.focusPage = focusPage
            if let focusPage, let page = document.page(at: focusPage - 1) {
                let annotation = PDFAnnotation(bounds: page.bounds(for: .cropBox).insetBy(dx: 4, dy: 4), forType: .square, withProperties: nil)
                annotation.color = UIColor(TheaterPalette(isDark: false).blue).withAlphaComponent(0.65)
                let border = PDFBorder(); border.lineWidth = 2; annotation.border = border
                page.addAnnotation(annotation); context.coordinator.focusAnnotation = annotation
            }
        }
        guard !context.coordinator.openingDocument else { return }
        let clamped = max(1, min(document.pageCount, selectedPage))
        if context.coordinator.lastPage != clamped, let page = document.page(at: clamped - 1) {
            context.coordinator.lastPage = clamped; uiView.go(to: page)
            if selectedPage != clamped { DispatchQueue.main.async { selectedPage = clamped } }
        }
    }
    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }
    final class Coordinator {
        var parent: NativePDFView
        var loadedURL: URL?
        var lastPage: Int?
        var observer: NSObjectProtocol?
        var openingDocument = false
        var focusPage: Int?
        var focusAnnotation: PDFAnnotation?
        init(_ parent: NativePDFView) { self.parent = parent }
    }
}

private struct SelectableSourceView: UIViewRepresentable {
    let text: String
    let isDiff: Bool
    let firstLine: Int
    let focusLine: Int?
    let endLine: Int?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true
        view.backgroundColor = .clear; view.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 24, right: 14)
        view.alwaysBounceVertical = true; view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        return view
    }
    func updateUIView(_ uiView: UITextView, context: Context) {
        let identity = "\(firstLine):\(focusLine ?? 0):\(endLine ?? 0):\(isDiff):" + text
        guard context.coordinator.identity != identity else { return }
        context.coordinator.identity = identity
        let styled = NSMutableAttributedString(string: text, attributes: [.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: UIColor.label])
        if isDiff {
            let source = text as NSString
            var position = 0
            for line in text.components(separatedBy: "\n") {
                let length = (line as NSString).length
                let range = NSRange(location: position, length: min(length, source.length - position))
                if line.hasPrefix("+") && !line.hasPrefix("+++") { styled.addAttribute(.foregroundColor, value: UIColor.systemGreen, range: range) }
                if line.hasPrefix("-") && !line.hasPrefix("---") { styled.addAttribute(.foregroundColor, value: UIColor.systemRed, range: range) }
                position += length + 1
            }
        }
        var focus: NSRange?
        if let focusLine, focusLine >= firstLine {
            let source = text as NSString
            var location = 0, number = firstLine
            while location < source.length {
                let range = source.lineRange(for: NSRange(location: location, length: 0))
                if number >= focusLine && number <= (endLine ?? focusLine) {
                    styled.addAttribute(.backgroundColor, value: UIColor(displayP3Red: 0.53, green: 0.71, blue: 0.98, alpha: 0.23), range: range)
                    focus = focus.map { NSUnionRange($0, range) } ?? range
                }
                if number > (endLine ?? focusLine) { break }
                location = NSMaxRange(range); number += 1
            }
        }
        uiView.attributedText = styled
        if let focus {
            DispatchQueue.main.async {
                guard context.coordinator.identity == identity else { return }
                uiView.layoutIfNeeded(); uiView.scrollRangeToVisible(NSRange(location: focus.location, length: min(focus.length, 240)))
            }
        } else { uiView.setContentOffset(.zero, animated: false) }
    }
    final class Coordinator { var identity = "" }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ImageScrollView {
        let scroll = ImageScrollView(); scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.imageView.image = image; scroll.imageView.contentMode = .scaleAspectFit
        scroll.addSubview(scroll.imageView); return scroll
    }
    func updateUIView(_ uiView: ImageScrollView, context: Context) { uiView.imageView.image = image }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ImageScrollView)?.imageView }
    }
}

final class ImageScrollView: UIScrollView {
    let imageView = UIImageView()
    private var previousSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size {
            zoomScale = 1; imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size; previousSize = bounds.size
        }
    }
}

private struct NativeFilePreview: UIViewControllerRepresentable {
    let url: URL
    let title: String
    func makeCoordinator() -> Coordinator { Coordinator(url: url, title: title) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        if context.coordinator.item.previewItemURL != url {
            context.coordinator.item = PreviewItem(url: url, title: title); uiViewController.reloadData()
        }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var item: PreviewItem
        init(url: URL, title: String) { item = PreviewItem(url: url, title: title) }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { item }
    }
    final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(url: URL, title: String) { previewItemURL = url; previewItemTitle = title }
    }
}
