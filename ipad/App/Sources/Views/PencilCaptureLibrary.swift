import SwiftUI
import UIKit
import PencilKit
import CryptoKit
import ImageIO

private struct StoredPencilCapture: Identifiable, Sendable {
    let id: String
    let archive: PencilArchive
    let imageURL: URL
    let backgroundURL: URL?
    let drawingURL: URL

    static func load(scope: String, conversationID: String?) throws -> (records: [StoredPencilCapture], unreadable: Int) {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Pencil Captures", isDirectory: true)
        let key = SHA256.hash(data: Data((scope + "/" + (conversationID ?? "unsent")).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = base.appendingPathComponent(key, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], 0) }
        var latest: [UUID: StoredPencilCapture] = [:]
        var unreadable = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            try Task.checkCancellation()
            guard let data = try? Data(contentsOf: url), let archive = try? JSONDecoder().decode(PencilArchive.self, from: data) else {
                unreadable += 1; continue
            }
            guard archive.libraryScope == scope, archive.conversationID == conversationID else { continue }
            let stem = url.deletingPathExtension()
            let named = directory.appendingPathComponent("圈画-\(stem.lastPathComponent).png")
            let image = FileManager.default.fileExists(atPath: named.path) ? named : stem.appendingPathExtension("png")
            guard FileManager.default.fileExists(atPath: image.path) else { unreadable += 1; continue }
            let background = directory.appendingPathComponent(stem.lastPathComponent + ".background.png")
            let capture = StoredPencilCapture(id: stem.lastPathComponent, archive: archive, imageURL: image,
                backgroundURL: archive.formatVersion == 2 && FileManager.default.fileExists(atPath: background.path) ? background : nil,
                drawingURL: stem.appendingPathExtension("drawing"))
            if latest[archive.id].map({ $0.archive.createdAt < archive.createdAt }) ?? true { latest[archive.id] = capture }
        }
        return (latest.values.sorted { $0.archive.createdAt > $1.archive.createdAt }, unreadable)
    }
}

struct PencilCaptureLibrary: View {
    let scope: String
    let conversationID: String?
    let onShare: (URL, String?, String) async -> Bool
    @Environment(\.theaterPalette) private var palette
    @State private var captures: [StoredPencilCapture] = []
    @State private var opened: StoredPencilCapture?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        TheaterPanel(title: "圈画手稿") {
            Group {
                if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if captures.isEmpty {
                    VStack(spacing: 18) {
                        TheaterGlyph(kind: .pencil).stroke(lineWidth: 1).frame(width: 46, height: 46).foregroundStyle(palette.gold)
                        Text(error ?? "这一页还没有圈画手稿。").foregroundStyle(palette.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(captures) { capture in
                        Button { opened = capture } label: {
                            HStack(spacing: 14) {
                                CaptureThumbnail(url: capture.imageURL).frame(width: 78, height: 68).clipped()
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(capture.archive.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 15, weight: .medium))
                                    Text("\(capture.archive.strokes.count)笔圈画").font(.system(size: 12)).foregroundStyle(palette.secondary)
                                }
                                Spacer()
                                TheaterGlyph(kind: .chevron).stroke(lineWidth: 1).frame(width: 13, height: 13)
                            }.padding(.vertical, 7).foregroundStyle(palette.text)
                        }.buttonStyle(.plain).listRowBackground(palette.raised)
                    }.scrollContentBackground(.hidden)
                        .safeAreaInset(edge: .top) {
                            if let error { Text(error).font(.footnote).foregroundStyle(palette.warning).padding(12) }
                        }
                }
            }
            .task(id: scope + "/" + (conversationID ?? "unsent")) {
                loading = true; error = nil
                do {
                    let task = Task.detached(priority: .userInitiated) { try StoredPencilCapture.load(scope: scope, conversationID: conversationID) }
                    let loaded = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                    try Task.checkCancellation()
                    captures = loaded.records
                    if loaded.unreadable > 0 { error = "有\(loaded.unreadable)份手稿暂时没能展开，原稿还留着。" }
                } catch is CancellationError { return }
                catch { self.error = "手稿暂时没能展开，原稿还留着。" }
                loading = false
            }
            .sheet(item: $opened) { capture in
                CaptureEditor(capture: capture, scope: scope, onShare: onShare)
                    .environment(\.theaterPalette, palette)
            }
        }
    }
}

private struct CaptureThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable().scaledToFit() } else { Color.clear } }
            .task(id: url) {
                if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let cg = CGImageSourceCreateThumbnailAtIndex(source, 0,
                    [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240,
                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) { image = UIImage(cgImage: cg) }
            }
    }
}

private struct CaptureEditor: View {
    let capture: StoredPencilCapture
    let scope: String
    let onShare: (URL, String?, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var background: UIImage?
    @State private var drawing: PKDrawing?
    @State private var error: String?
    @State private var sharing = false
    @State private var isReady = false
    @State private var paperSize = CGSize(width: 900, height: 1200)
    @State private var initialColor: UIColor?
    var body: some View {
        NavigationStack {
            Group {
                if let background, let drawing {
                    ScratchpadView(conversationID: "pencil-capture-edit:v2:\(scope):\(capture.id)", onShare: share,
                                   backgroundImage: background, initialDrawing: drawing, paperSize: paperSize, initialColor: initialColor)
                } else if isReady {
                    VStack(spacing: 18) {
                        if let image = UIImage(contentsOfFile: capture.imageURL.path) { ZoomableImageView(image: image) }
                        Button("附到草稿") { share(capture.imageURL) }.buttonStyle(TheaterActionStyle()).disabled(sharing)
                    }.padding(16)
                } else { ProgressView() }
            }
            .navigationTitle("圈画手稿").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .overlay(alignment: .bottom) { if let error { Text(error).font(.footnote).padding(14) } }
            .task(id: capture.id) {
                if let url = capture.backgroundURL, let image = UIImage(contentsOfFile: url.path) {
                    do {
                        let raw = try PKDrawing(data: Data(contentsOf: capture.drawingURL))
                        let size = capture.archive.region.size
                        let scale = 900 / size.width
                        paperSize = CGSize(width: 900, height: size.height * scale)
                        initialColor = raw.strokes.first?.ink.color.withAlphaComponent(1)
                        let transform = CGAffineTransform(scaleX: scale, y: scale)
                            .translatedBy(x: -capture.archive.region.minX, y: -capture.archive.region.minY)
                        drawing = raw.transformed(using: transform); background = image
                    } catch { self.error = "原圈画还在，笔迹暂时未能重新展开。" }
                }
                isReady = true
            }
        }
    }
    private func share(_ url: URL) {
        guard !sharing else { return }
        sharing = true
        Task {
            if await onShare(url, capture.archive.conversationID, scope) { dismiss() }
            else { error = "手稿还在，暂时没能附到草稿。" }
            sharing = false
        }
    }
}
