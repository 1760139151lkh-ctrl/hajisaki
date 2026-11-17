import SwiftUI
import UIKit
import PencilKit
import Metal
import CryptoKit
import ImageIO

/// A conversation keeps its own editable PencilKit document. Export never replaces it.
struct ScratchpadView: View {
    let conversationID: String
    let onShare: (URL) -> Void
    var backgroundImage: UIImage? = nil
    var initialDrawing: PKDrawing? = nil
    var paperSize = CGSize(width: 900, height: 1200)
    var initialColor: UIColor? = nil
    @StateObject private var session = InkSession()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(InkTool.allCases) { tool in
                        Button(tool.title) { session.select(tool) }
                            .foregroundStyle(session.tool == tool ? Color(red: 0.34, green: 0.52, blue: 0.80) : .primary)
                            .accessibilityAddTraits(session.tool == tool ? .isSelected : [])
                    }
                    Menu("墨色") {
                        Button("普鲁士蓝") { session.setColor(.inkBlue) }
                        Button("香槟金") { session.setColor(.inkGold) }
                        Button("红茶红") { session.setColor(.inkRed) }
                    }
                    Button("撤销") { session.undo() }.disabled(!session.canUndo)
                        .keyboardShortcut("z", modifiers: .command)
                    Button("重做") { session.redo() }.disabled(!session.canRedo)
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                    Button("画笔环") { session.openPalette(.tools, at: CGPoint(x: 140, y: 150)) }
                }
                .font(.system(size: 14, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 12)
            }
            Divider()
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    InkCanvasHost(session: session)
                        .accessibilityLabel("草稿纸")
                        .allowsHitTesting(session.isReady)
                    if let point = session.palettePoint {
                        Color.black.opacity(0.08).onTapGesture { session.palettePoint = nil }
                        watchPalette
                            .position(x: min(max(122, point.x), max(122, geometry.size.width - 122)),
                                      y: min(max(122, point.y), max(122, geometry.size.height - 122)))
                            .transition(.scale(scale: 0.94).combined(with: .opacity))
                    }
                }
                .clipped()
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: session.palettePoint != nil)
            }
            if let error = session.error {
                HStack {
                    Text(error).font(.footnote)
                    Spacer()
                    Button("重试") { session.retry() }
                }.foregroundStyle(Color(red: 0.77, green: 0.29, blue: 0.40)).padding(12)
            }
            if session.hasInk {
                HStack {
                    Spacer()
                    Button("递给祥子看这段") {
                        if let url = session.exportPNG() { onShare(url) }
                    }
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 20).padding(.vertical, 11)
                    .background(Color(red: 0.84, green: 0.70, blue: 0.41).opacity(0.14), in: Capsule())
                    Spacer()
                }.padding(12)
            }
        }
        .task(id: conversationID) {
            session.paperSize = paperSize; session.background = backgroundImage
            if let initialColor { session.setColor(initialColor) }
            session.open(conversationID, initialDrawing: initialDrawing)
        }
        .onDisappear { session.save() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.save() } }
    }

    private var watchPalette: some View {
        ZStack {
            Circle().fill(Color(red: 0.05, green: 0.09, blue: 0.17))
            Circle().stroke(Color(red: 0.84, green: 0.70, blue: 0.41), lineWidth: 1)
            Circle().stroke(Color(red: 0.84, green: 0.70, blue: 0.41).opacity(0.35), lineWidth: 0.5).padding(9)
            switch session.paletteKind {
            case .tools:
                paletteButton("书写", x: 0, y: -72) { session.select(.pen) }
                paletteButton("高光", x: 69, y: -22) { session.select(.marker) }
                paletteButton("橡皮", x: 44, y: 62) { session.select(.eraser) }
                paletteButton("撤销", x: -44, y: 62) { session.undo() }
                paletteButton("递给她", x: -69, y: -22) {
                    if let url = session.exportPNG() { onShare(url) }
                }
            case .colors:
                paletteButton("苍蓝", x: 0, y: -72) { session.setColor(.inkBlue) }
                paletteButton("香槟金", x: 69, y: -22) { session.setColor(.inkGold) }
                paletteButton("红茶红", x: 44, y: 62) { session.setColor(.inkRed) }
                paletteButton("钢笔", x: -44, y: 62) { session.select(.pen) }
                paletteButton("高光", x: -69, y: -22) { session.select(.marker) }
            case .attributes:
                paletteButton("细", x: 0, y: -72) { session.setWidth(pen: 2, marker: 10) }
                paletteButton("适中", x: 69, y: -22) { session.setWidth(pen: 4, marker: 22) }
                paletteButton("粗", x: 44, y: 62) { session.setWidth(pen: 7, marker: 36) }
                paletteButton("钢笔", x: -44, y: 62) { session.select(.pen) }
                paletteButton("高光", x: -69, y: -22) { session.select(.marker) }
            }
            Button("收起") { session.palettePoint = nil }
                .font(.system(size: 12)).foregroundStyle(Color(red: 0.84, green: 0.70, blue: 0.41))
                .frame(width: 48, height: 48)
        }.frame(width: 232, height: 232).shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }

    private func paletteButton(_ label: String, x: CGFloat, y: CGFloat, action: @escaping () -> Void) -> some View {
        Button(label) { action(); session.palettePoint = nil }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(Color(red: 0.93, green: 0.95, blue: 0.99))
            .frame(width: 56, height: 48).contentShape(Rectangle()).offset(x: x, y: y)
    }
}

private enum InkTool: String, CaseIterable, Identifiable {
    case pen, marker, eraser
    var id: String { rawValue }
    var title: String { switch self { case .pen: return "钢笔"; case .marker: return "高光"; case .eraser: return "橡皮" } }
}
private enum InkPaletteKind: Equatable { case tools, colors, attributes }

private extension UIColor {
    static let inkBlue = UIColor(displayP3Red: 0.10, green: 0.22, blue: 0.40, alpha: 1)
    static let inkGold = UIColor(displayP3Red: 0.66, green: 0.48, blue: 0.18, alpha: 1)
    static let inkRed = UIColor(displayP3Red: 0.70, green: 0.21, blue: 0.32, alpha: 1)
    static let inkPaper = UIColor(displayP3Red: 0.965, green: 0.965, blue: 0.976, alpha: 1)
}

@MainActor private final class InkSession: ObservableObject {
    @Published var tool: InkTool = .pen
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var hasInk = false
    @Published var isReady = false
    @Published var palettePoint: CGPoint?
    @Published var paletteKind: InkPaletteKind = .tools
    @Published var error: String?
    var color: UIColor = .inkBlue
    var penWidth: CGFloat = 4
    var markerWidth: CGFloat = 22
    var drawing = PKDrawing()
    var paperSize = CGSize(width: 900, height: 1200) { didSet { host?.configurePaper() } }
    var background: UIImage? { didSet { host?.refreshBackground() } }
    weak var host: InkHostView?
    private var previousTool: InkTool = .eraser
    private var undoStack: [PKDrawing] = []
    private var redoStack: [PKDrawing] = []
    private var strokeStart: PKDrawing?
    private var documentURL: URL?
    private var openedID: String?
    private var requestedID: String?
    private let io = DispatchQueue(label: "dev.hajisaki.ink.persistence", qos: .userInitiated)

    func open(_ id: String, initialDrawing: PKDrawing? = nil) {
        guard openedID != id else { return }
        save()
        requestedID = id
        isReady = false
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true).appendingPathComponent("Ink", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
            let url = directory.appendingPathComponent(key).appendingPathExtension("drawing")
            let restored: PKDrawing = try io.sync {
                guard FileManager.default.fileExists(atPath: url.path) else { return initialDrawing ?? PKDrawing() }
                return try PKDrawing(data: Data(contentsOf: url))
            }
            documentURL = url; openedID = id; drawing = restored
            undoStack = []; redoStack = []; strokeStart = nil; error = nil
            isReady = true; refreshFlags(); host?.show(drawing)
        } catch {
            // A failed read never becomes an empty document that could overwrite the original.
            documentURL = nil; openedID = nil
            drawing = PKDrawing(); undoStack = []; redoStack = []; refreshFlags(); host?.show(drawing)
            self.error = "这页草稿暂时没能展开，原稿还留着。"
        }
    }

    func select(_ selection: InkTool) {
        if selection != tool { previousTool = tool; tool = selection }
        host?.configureTool()
    }
    func switchPrevious() { select(previousTool) }
    func switchEraser() { select(tool == .eraser ? (previousTool == .eraser ? .pen : previousTool) : .eraser) }
    func setColor(_ value: UIColor) { color = value; host?.configureTool() }
    func setWidth(pen: CGFloat, marker: CGFloat) { penWidth = pen; markerWidth = marker; host?.configureTool() }
    func openPalette(_ kind: InkPaletteKind, at point: CGPoint) {
        if palettePoint != nil && paletteKind == kind { palettePoint = nil }
        else { paletteKind = kind; palettePoint = point }
    }
    func beginStroke() { strokeStart = drawing }
    func changed(_ value: PKDrawing) { drawing = value; hasInk = !value.strokes.isEmpty }
    func endStroke() {
        if let before = strokeStart, before.dataRepresentation() != drawing.dataRepresentation() {
            undoStack.append(before)
            if undoStack.count > 40 { undoStack.removeFirst() }
            redoStack = []
        }
        strokeStart = nil; refreshFlags(); save()
    }
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(drawing); drawing = previous; host?.show(drawing); refreshFlags(); save()
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(drawing); drawing = next; host?.show(drawing); refreshFlags(); save()
    }
    private func refreshFlags() {
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty; hasInk = !drawing.strokes.isEmpty
    }
    func retry() {
        if documentURL != nil { save() }
        else if let requestedID { open(requestedID) }
    }
    func save() {
        guard let url = documentURL else { return }
        let data = drawing.dataRepresentation()
        // Serial, atomic writes preserve stroke order even when the view closes during a save.
        io.async { [weak self] in
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                Task { @MainActor in if self?.documentURL == url { self?.error = nil } }
            }
            catch { Task { @MainActor in self?.error = "这页还没存好，请再试一次。" } }
        }
    }
    func exportPNG() -> URL? {
        guard hasInk else { return nil }
        save()
        let paper = CGRect(origin: .zero, size: paperSize)
        let rect = background == nil ? drawing.bounds.insetBy(dx: -24, dy: -24).intersection(paper) : paper
        guard !rect.isEmpty, !rect.isNull else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        let result = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            UIColor.inkPaper.setFill(); context.fill(CGRect(origin: .zero, size: rect.size))
            background?.draw(in: Self.imageRect(background, in: paper))
            if MTLCreateSystemDefaultDevice() != nil {
                drawing.image(from: rect, scale: 2).draw(at: .zero)
            } else {
                context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
                SoftwareInkView.render(drawing, in: context.cgContext)
            }
        }
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true).appendingPathComponent("草稿导出", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("草稿-\(UUID().uuidString.prefix(8)).png")
            let visibleInk = drawing.bounds.intersection(rect)
            let colors = Set(drawing.strokes.compactMap { stroke -> String? in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                guard stroke.ink.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
                let bytes = [red, green, blue, alpha].map { Int((min(1, max(0, $0)) * 255).rounded()) }
                return String(format: "#%02X%02X%02X%02X", bytes[0], bytes[1], bytes[2], bytes[3])
            }).sorted()
            let metadata: [String: Any] = [
                "format": "hajisaki-ink-v1", "stroke_count": drawing.strokes.count,
                "coordinate_space": "normalized-top-left",
                "background_present": background != nil,
                "image_pixels": ["width": result.cgImage?.width ?? 0, "height": result.cgImage?.height ?? 0],
                "ink_bounds": ["x": (visibleInk.minX - rect.minX) / rect.width,
                               "y": (visibleInk.minY - rect.minY) / rect.height,
                               "width": visibleInk.width / rect.width, "height": visibleInk.height / rect.height],
                "colors_rgba": Array(colors.prefix(16))
            ]
            let description = String(decoding: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), as: UTF8.self)
            let data = NSMutableData()
            guard let image = result.cgImage,
                  let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description]] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            try (data as Data).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            host?.completionFeedback(); error = nil
            return url
        } catch { self.error = "草稿还在，图片没能递出去。"; return nil }
    }
    static func imageRect(_ image: UIImage?, in paper: CGRect) -> CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return paper }
        let scale = min(paper.width / image.size.width, paper.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: paper.midX - size.width / 2, y: paper.midY - size.height / 2, width: size.width, height: size.height)
    }
}

private struct InkCanvasHost: UIViewRepresentable {
    @ObservedObject var session: InkSession
    func makeUIView(context: Context) -> InkHostView { InkHostView(session: session) }
    func updateUIView(_ uiView: InkHostView, context: Context) { uiView.configureTool() }
}

@MainActor private final class InkHostView: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    private let session: InkSession
    private var canvas: PKCanvasView?
    private var software: SoftwareInkView?
    private var scroll: UIScrollView!
    private var appliedWidth: CGFloat = 0
    private let hoverLayer = CAShapeLayer()
    private var changingDrawing = false
    private let paperImage = UIImageView()
    private var softwareZoomDelegate: SoftwareZoomDelegate?
    private lazy var feedback = UICanvasFeedbackGenerator(view: self)

    init(session: InkSession) {
        self.session = session
        super.init(frame: .zero)
        session.host = self
        backgroundColor = .inkPaper
        if MTLCreateSystemDefaultDevice() != nil {
            let canvas = PKCanvasView()
            canvas.drawing = session.drawing; canvas.delegate = self
            canvas.backgroundColor = .inkPaper; canvas.isOpaque = false
            canvas.drawingPolicy = .anyInput
            canvas.contentSize = session.paperSize
            canvas.alwaysBounceVertical = true
            paperImage.image = session.background; paperImage.contentMode = .scaleAspectFit
            paperImage.isUserInteractionEnabled = false
            canvas.insertSubview(paperImage, at: 0)
            self.canvas = canvas; scroll = canvas
        } else {
            let surface = SoftwareInkView(frame: CGRect(origin: .zero, size: session.paperSize))
            surface.session = session; surface.backgroundColor = .inkPaper
            software = surface
            let scroller = UIScrollView()
            let zoomDelegate = SoftwareZoomDelegate(surface: surface)
            softwareZoomDelegate = zoomDelegate; scroller.delegate = zoomDelegate
            scroller.contentSize = surface.bounds.size; scroller.addSubview(surface)
            scroller.panGestureRecognizer.minimumNumberOfTouches = 2
            scroll = scroller
        }
        scroll.maximumZoomScale = 3; addSubview(scroll)
        let interaction = UIPencilInteraction(); interaction.delegate = self; addInteraction(interaction)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        addGestureRecognizer(hover)
        hoverLayer.strokeColor = UIColor(displayP3Red: 0.53, green: 0.71, blue: 0.98, alpha: 1).cgColor
        hoverLayer.fillColor = UIColor.clear.cgColor; hoverLayer.lineWidth = 1.5; hoverLayer.isHidden = true
        layer.addSublayer(hoverLayer)
        configureTool()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); scroll.frame = bounds; hoverLayer.frame = bounds
        guard bounds.width > 0, abs(appliedWidth - bounds.width) > 0.5 else { return }
        let oldMinimum = scroll.minimumZoomScale
        let wasFitted = appliedWidth == 0 || abs(scroll.zoomScale - oldMinimum) < 0.02
        let minimum = min(1, bounds.width / session.paperSize.width)
        scroll.minimumZoomScale = minimum
        if wasFitted { scroll.zoomScale = minimum }
        layoutPaperImage()
        appliedWidth = bounds.width
    }
    func configureTool() {
        guard let canvas else { return }
        switch session.tool {
        case .pen: canvas.tool = PKInkingTool(.fountainPen, color: session.color, width: session.penWidth)
        case .marker: canvas.tool = PKInkingTool(.marker, color: session.color.withAlphaComponent(0.45), width: session.markerWidth)
        case .eraser: canvas.tool = PKEraserTool(.vector)
        }
    }
    func configurePaper() {
        guard session.paperSize.width > 0, session.paperSize.height > 0 else { return }
        appliedWidth = 0
        scroll.zoomScale = 1
        canvas?.contentSize = session.paperSize
        if let software { software.frame = CGRect(origin: .zero, size: session.paperSize); scroll.contentSize = session.paperSize }
        layoutPaperImage(); setNeedsLayout()
    }
    func show(_ drawing: PKDrawing) {
        changingDrawing = true; canvas?.drawing = drawing; changingDrawing = false
        refreshBackground()
        software?.setNeedsDisplay()
    }
    func refreshBackground() {
        paperImage.image = session.background; layoutPaperImage()
        software?.setNeedsDisplay()
    }
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { session.beginStroke(); hoverLayer.isHidden = true }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !changingDrawing else { return }; session.changed(canvasView.drawing)
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { session.changed(canvasView.drawing); session.endStroke() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { layoutPaperImage() }
    private func layoutPaperImage() {
        guard let canvas else { return }
        paperImage.frame = CGRect(origin: .zero, size: CGSize(width: session.paperSize.width * canvas.zoomScale,
                                                            height: session.paperSize.height * canvas.zoomScale))
    }
    func completionFeedback() { feedback.pathCompleted(at: CGPoint(x: bounds.midX, y: bounds.midY)) }
    @objc private func hoverChanged(_ recognizer: UIHoverGestureRecognizer) {
        guard UIPencilInteraction.prefersHoverToolPreview,
              recognizer.state == .began || recognizer.state == .changed else { hoverLayer.isHidden = true; return }
        let point = recognizer.location(in: self)
        let width = session.tool == .marker ? session.markerWidth : max(5, session.penWidth)
        let nib = UIBezierPath(ovalIn: CGRect(x: -width / 2, y: -2, width: width, height: 4))
        nib.apply(CGAffineTransform(translationX: point.x, y: point.y).rotated(by: recognizer.rollAngle))
        hoverLayer.path = nib.cgPath
        hoverLayer.opacity = Float(0.25 + (1 - recognizer.zOffset) * 0.65); hoverLayer.isHidden = false
    }
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        if UIPencilInteraction.preferredSqueezeAction == .showContextualPalette,
           let controller = TheaterPencilController.forWindow(window), controller.acceptsCommands {
            controller.presentForSqueeze(squeeze.timestamp, at: squeeze.hoverPose.map { convert($0.location, to: window) })
            return
        }
        perform(UIPencilInteraction.preferredSqueezeAction, point: squeeze.hoverPose?.location)
    }
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        perform(UIPencilInteraction.preferredTapAction, point: tap.hoverPose?.location)
    }
    private func perform(_ action: UIPencilPreferredAction, point: CGPoint?) {
        switch action {
        case .ignore, .runSystemShortcut: break
        case .switchEraser: session.switchEraser()
        case .switchPrevious: session.switchPrevious()
        case .showColorPalette:
            session.openPalette(.colors, at: point ?? CGPoint(x: bounds.midX, y: bounds.midY))
        case .showInkAttributes:
            session.openPalette(.attributes, at: point ?? CGPoint(x: bounds.midX, y: bounds.midY))
        case .showContextualPalette:
            if let controller = TheaterPencilController.forWindow(window), controller.acceptsCommands {
                controller.presentRing(at: convert(point ?? CGPoint(x: bounds.midX, y: bounds.midY), to: window))
            } else { session.openPalette(.tools, at: point ?? CGPoint(x: bounds.midX, y: bounds.midY)) }
        @unknown default: break
        }
    }
}

@MainActor private final class SoftwareZoomDelegate: NSObject, UIScrollViewDelegate {
    weak var surface: UIView?
    init(surface: UIView) { self.surface = surface }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { surface }
}

/// Limited software input for environments that actually return no Metal device.
/// It edits the same PKDrawing file; native PencilKit handles real Pencil hardware.
@MainActor private final class SoftwareInkView: UIView {
    weak var session: InkSession?
    private var points: [PKStrokePoint] = []
    private var beganAt: TimeInterval = 0
    private var activeTouch: UITouch?
    private var working = PKDrawing()
    private var strokeColor: UIColor = .inkBlue
    private var strokeTool: InkTool = .pen

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first, let session else { return }
        activeTouch = touch; beganAt = touch.timestamp; points = []; working = session.drawing
        strokeColor = session.color; strokeTool = session.tool; session.beginStroke()
        append(touch, event: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }; append(touch, event: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        append(touch, event: event); activeTouch = nil; session?.endStroke()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouch = nil; session?.endStroke()
    }
    private func append(_ touch: UITouch, event: UIEvent?) {
        guard let session else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            let point = sample.location(in: self)
            if strokeTool == .eraser {
                // Whole-stroke erasing is intentionally not presented as pixel erasing.
                working = PKDrawing(strokes: working.strokes.filter { !$0.renderBounds.insetBy(dx: -8, dy: -8).contains(point) })
            } else {
                let width: CGFloat = strokeTool == .marker ? session.markerWidth : session.penWidth
                points.append(PKStrokePoint(location: point, timeOffset: max(0, sample.timestamp - beganAt),
                                            size: CGSize(width: width, height: width), opacity: 1,
                                            force: 1, azimuth: 0, altitude: .pi / 2))
            }
        }
        if strokeTool == .eraser { session.changed(working) }
        else {
            let ink = PKInk(strokeTool == .marker ? .marker : .pen,
                            color: strokeTool == .marker ? strokeColor.withAlphaComponent(0.35) : strokeColor)
            let stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
            session.changed(PKDrawing(strokes: working.strokes + [stroke]))
        }
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let session else { return }
        session.background?.draw(in: InkSession.imageRect(session.background, in: bounds))
        Self.render(session.drawing, in: context)
    }
    static func render(_ drawing: PKDrawing, in context: CGContext) {
        for stroke in drawing.strokes {
            guard stroke.path.count > 0 else { continue }
            context.saveGState(); context.concatenate(stroke.transform)
            context.setStrokeColor(stroke.ink.color.cgColor); context.setFillColor(stroke.ink.color.cgColor)
            context.setLineCap(.round); context.setLineJoin(.round)
            let first = stroke.path[0]
            context.setLineWidth(max(1, first.size.width))
            if stroke.path.count == 1 {
                context.fillEllipse(in: CGRect(x: first.location.x - first.size.width / 2,
                                               y: first.location.y - first.size.height / 2,
                                               width: max(1, first.size.width), height: max(1, first.size.height)))
            } else {
                context.beginPath(); context.move(to: first.location)
                for point in stroke.path.dropFirst() { context.addLine(to: point.location) }
                context.strokePath()
            }
            context.restoreGState()
        }
    }
}
