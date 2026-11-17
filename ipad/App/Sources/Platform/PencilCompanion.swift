import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import CryptoKit
import ImageIO

enum PencilCommand: String, CaseIterable {
    case circle, highlight, scratchpad, voice, effort
    var title: String {
        switch self {
        case .circle: return "圈选追问"
        case .highlight: return "高光标记"
        case .scratchpad: return "展开草稿"
        case .voice: return "语音附耳"
        case .effort: return "思考档位"
        }
    }
}

struct PencilPreview: Equatable {
    var title: String
    var text: String
}

@MainActor protocol PencilPreviewProviding: AnyObject {
    var pencilPreview: PencilPreview? { get }
}

struct PencilSample: Codable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var time: TimeInterval
    var force: CGFloat
    var azimuth: CGFloat
    var altitude: CGFloat
    var roll: CGFloat
    var point: CGPoint { CGPoint(x: x, y: y) }
}

struct PencilStroke: Codable, Sendable {
    var samples: [PencilSample]
    var marker: Bool
    var width: CGFloat
    var color: [CGFloat]
    var bounds: CGRect {
        samples.reduce(CGRect.null) { $0.union(CGRect(origin: $1.point, size: CGSize(width: 1, height: 1))) }
    }
    var isClosed: Bool {
        guard samples.count >= 6, let first = samples.first, let last = samples.last,
              bounds.width > 35, bounds.height > 35 else { return false }
        let length = zip(samples, samples.dropFirst()).reduce(CGFloat.zero) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        return length > max(150, hypot(bounds.width, bounds.height) * 2) &&
            hypot(first.x - last.x, first.y - last.y) < max(24, hypot(bounds.width, bounds.height) * 0.12)
    }
    var inkColor: UIColor {
        UIColor(displayP3Red: color[0], green: color[1], blue: color[2], alpha: color[3])
    }
}

struct PencilArchive: Codable, Sendable {
    var formatVersion: Int?
    var id: UUID
    var createdAt: Date
    var conversationID: String?
    var libraryScope: String
    var windowSize: CGSize
    var region: CGRect
    var strokes: [PencilStroke]
}

@MainActor
final class TheaterPencilController: NSObject, ObservableObject, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    @Published private(set) var isDrawing = false
    @Published private(set) var interactionRevision = 0
    @Published private(set) var captureArmed = false
    @Published private(set) var notice: String?
    private static let windows = NSMapTable<UIWindow, TheaterPencilController>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    private weak var window: UIWindow?
    private var overlay: PencilWindowOverlay?
    private var interaction: UIPencilInteraction?
    private var inkGesture: PencilInkGesture?
    private var hoverGesture: UIHoverGestureRecognizer?
    private var contentPan: UIPanGestureRecognizer?
    private var scope = ""
    private var conversationID: String?
    private var active = false
    private var contentContext = ""
    private var sourceMoved = false
    private var acceptsTouch = false
    private var marker = false
    private var color = UIColor(displayP3Red: 0.53, green: 0.71, blue: 0.98, alpha: 1)
    private var strokes: [PencilStroke] = []
    private var working: PencilStroke?
    private var captureSize = CGSize.zero
    private var captureID = UUID()
    private var writeRevision = UUID()
    private var readyURL: URL?
    private var readyContext: (id: String?, scope: String)?
    private var sharing = false
    private var palette = TheaterPalette(isDark: true)
    private var onCommand: ((PencilCommand) -> Void)?
    private var onCapture: ((URL, String?, String) -> Void)?
    private var io = DispatchQueue(label: "app.hajisaki.pencil.capture", qos: .userInitiated)
    private var feedback: UICanvasFeedbackGenerator?
    private var lastSqueezeTimestamp: TimeInterval = -.infinity

    static func forWindow(_ window: UIWindow?) -> TheaterPencilController? {
        guard let window else { return nil }
        return windows.object(forKey: window)
    }
    var acceptsCommands: Bool { active && window != nil }
    func presentForSqueeze(_ timestamp: TimeInterval, at point: CGPoint?) {
        guard abs(timestamp - lastSqueezeTimestamp) > 0.001 else { return }
        lastSqueezeTimestamp = timestamp
        presentRing(at: point)
    }
    func isCaptureCurrent(_ url: URL) -> Bool { readyURL == url }
    func captureFinished(_ url: URL, delivered: Bool) {
        guard readyURL == url else { return }
        sharing = false
        if delivered { clearCapture() }
        else if let region = strokes.last?.bounds { overlay?.showCandidate(at: region, ready: true) }
    }

    func configure(scope: String, conversationID: String?, contentContext: String, active: Bool, palette: TheaterPalette,
                   onCommand: @escaping (PencilCommand) -> Void, onCapture: @escaping (URL, String?, String) -> Void) {
        if self.scope != scope || self.conversationID != conversationID { clearCapture() }
        if self.contentContext != contentContext && !strokes.isEmpty { sourceMoved = true; overlay?.hideInkFromContent() }
        self.contentContext = contentContext
        self.scope = scope; self.conversationID = conversationID; self.active = active
        self.palette = palette
        self.onCommand = onCommand; self.onCapture = onCapture
        overlay?.palette = palette
        overlay?.isHidden = !active
        if inkGesture?.isEnabled != active { inkGesture?.isEnabled = active }
        if hoverGesture?.isEnabled != active { hoverGesture?.isEnabled = active }
        if interaction?.isEnabled != active { interaction?.isEnabled = active }
        if contentPan?.isEnabled != active { contentPan?.isEnabled = active }
        if !active { overlay?.hideRing(); overlay?.hidePreview() }
    }

    func attach(to window: UIWindow) {
        guard self.window !== window else { return }
        detach(clearCallbacks: false)
        self.window = window
        Self.windows.setObject(self, forKey: window)
        let overlay = PencilWindowOverlay(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.controller = self
        overlay.palette = palette
        overlay.isHidden = !active
        window.addSubview(overlay); self.overlay = overlay
        feedback = UICanvasFeedbackGenerator(view: overlay)
        let interaction = UIPencilInteraction(); interaction.delegate = self
        window.addInteraction(interaction); self.interaction = interaction
        let ink = PencilInkGesture(controller: self)
        ink.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        ink.cancelsTouchesInView = true; ink.delaysTouchesEnded = true
        ink.delegate = self; window.addGestureRecognizer(ink); inkGesture = ink
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        hover.cancelsTouchesInView = false; window.addGestureRecognizer(hover); hoverGesture = hover
        let pan = UIPanGestureRecognizer(target: self, action: #selector(contentMoved(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pan.cancelsTouchesInView = false; pan.delegate = self; window.addGestureRecognizer(pan); contentPan = pan
    }

    func detach(clearCallbacks: Bool = true) {
        if let window {
            if let inkGesture { window.removeGestureRecognizer(inkGesture) }
            if let hoverGesture { window.removeGestureRecognizer(hoverGesture) }
            if let contentPan { window.removeGestureRecognizer(contentPan) }
            if let interaction { window.removeInteraction(interaction) }
            if Self.windows.object(forKey: window) === self { Self.windows.removeObject(forKey: window) }
        }
        overlay?.removeFromSuperview(); overlay = nil
        window = nil; inkGesture = nil; hoverGesture = nil; contentPan = nil; interaction = nil; feedback = nil
        if clearCallbacks { onCommand = nil; onCapture = nil }
    }

    func presentRing(at point: CGPoint? = nil) {
        guard active, let window, let overlay else { return }
        if overlay.ringVisible { overlay.hideRing(); return }
        window.bringSubviewToFront(overlay)
        overlay.showRing(at: point ?? CGPoint(x: window.bounds.midX, y: window.bounds.midY))
    }

    fileprivate func choose(_ command: PencilCommand) {
        overlay?.hideRing(); overlay?.hidePreview()
        switch command {
        case .circle, .highlight:
            clearCapture()
            marker = command == .highlight
            if marker { color = UIColor(displayP3Red: 0.84, green: 0.70, blue: 0.41, alpha: 1) }
            else { color = UIColor(palette.blue) }
            acceptsTouch = true
            captureArmed = true
            inkGesture?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        default:
            clearCapture()
            onCommand?(command)
        }
    }

    func showPreview(_ preview: PencilPreview, at point: CGPoint? = nil, sourceRect: CGRect? = nil) {
        guard active, let window, let overlay else { return }
        window.bringSubviewToFront(overlay)
        overlay.showPreview(preview, at: point ?? CGPoint(x: window.bounds.midX, y: window.bounds.midY))
        overlay.highlightPreviewSource(sourceRect)
    }

    func cancelCapture() { clearCapture(); overlay?.hideRing(); overlay?.hidePreview() }

    private func clearCapture() {
        writeRevision = UUID(); strokes = []; working = nil; readyURL = nil; readyContext = nil
        captureID = UUID(); captureSize = .zero; acceptsTouch = false; sharing = false
        if isDrawing { isDrawing = false }
        if captureArmed { captureArmed = false }
        sourceMoved = false
        inkGesture?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        overlay?.clearInk()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard active, !sharing, overlay?.ringVisible != true else { return false }
        if gestureRecognizer === contentPan { return !acceptsTouch && !strokes.isEmpty && touch.type != .pencil }
        var responder: UIResponder? = touch.view
        while let current = responder {
            if current is UIControl || current is UITextField || current is UIDocumentPickerViewController || current is UIActivityViewController { return false }
            if let text = current as? UITextView, text.isEditable { return false }
            if !acceptsTouch && (current is PKCanvasView || String(describing: type(of: current)).contains("InkHostView")) { return false }
            responder = current.next
        }
        return touch.type == .pencil || acceptsTouch
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === inkGesture && !(otherGestureRecognizer is UIHoverGestureRecognizer) && otherGestureRecognizer !== contentPan
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === contentPan || otherGestureRecognizer === contentPan
    }
    @objc private func contentMoved(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { sourceMoved = true; overlay?.hideInkFromContent() }
    }

    fileprivate func begin(_ samples: [PencilSample]) {
        guard active, let window, let overlay else { return }
        if sourceMoved || (captureSize != .zero && captureSize != window.bounds.size) {
            // The saved candidate remains available; a new stroke starts a new viewport capture.
            strokes = []; readyURL = nil; captureID = UUID()
        }
        captureSize = window.bounds.size
        sourceMoved = false
        captureArmed = true
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        if let space = CGColorSpace(name: CGColorSpace.displayP3),
           let components = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil)?.components,
           components.count >= 3 {
            red = components[0]; green = components[1]; blue = components[2]
        } else { color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) }
        working = PencilStroke(samples: samples, marker: marker, width: marker ? 16 : 3.5, color: [red, green, blue, marker ? 0.32 : 1])
        readyURL = nil; readyContext = (conversationID, scope); writeRevision = UUID()
        isDrawing = true; interactionRevision &+= 1; notice = nil
        overlay.hidePreview(); overlay.hideCandidate(); window.bringSubviewToFront(overlay)
        overlay.setInk(strokes + (working.map { [$0] } ?? []))
    }

    fileprivate func move(_ samples: [PencilSample]) {
        guard working != nil else { return }
        working?.samples.append(contentsOf: samples)
        overlay?.setInk(strokes + (working.map { [$0] } ?? []))
    }

    fileprivate func end(cancelled: Bool) {
        guard let stroke = working else { return }
        working = nil; isDrawing = false
        guard !cancelled, !stroke.samples.isEmpty else { overlay?.setInk(strokes); return }
        strokes.append(stroke); overlay?.setInk(strokes)
        if stroke.isClosed, let last = stroke.samples.last { feedback?.pathCompleted(at: last.point) }
        saveCandidate()
    }

    private func saveCandidate() {
        guard let window, let overlay, !strokes.isEmpty else { return }
        let inkBounds = strokes.reduce(CGRect.null) { $0.union($1.bounds) }
        let pad: CGFloat = strokes.last?.isClosed == true ? 14 : 64
        var region = inkBounds.insetBy(dx: -pad, dy: -pad).intersection(window.bounds)
        if region.width < 150 { region = region.insetBy(dx: -(150 - region.width) / 2, dy: 0).intersection(window.bounds) }
        if region.height < 100 { region = region.insetBy(dx: 0, dy: -(100 - region.height) / 2).intersection(window.bounds) }
        guard !region.isNull, region.width > 1, region.height > 1 else { return }
        let format = UIGraphicsImageRendererFormat(); format.scale = window.screen.scale; format.opaque = true
        var contentViews: [UIView] = []
        var contentController = window.rootViewController
        while let controller = contentController {
            if let view = controller.viewIfLoaded { contentViews.append(view) }
            contentController = controller.presentedViewController
        }
        guard !contentViews.isEmpty else { return }
        let background = UIGraphicsImageRenderer(size: region.size, format: format).image { context in
            context.cgContext.translateBy(x: -region.minX, y: -region.minY)
            for view in contentViews {
                view.drawHierarchy(in: view.convert(view.bounds, to: window), afterScreenUpdates: false)
            }
        }
        let image = UIGraphicsImageRenderer(size: region.size, format: format).image { context in
            background.draw(at: .zero)
            context.cgContext.translateBy(x: -region.minX, y: -region.minY)
            PencilWindowOverlay.render(strokes, in: context.cgContext)
        }
        guard let cgImage = image.cgImage, let backgroundImage = background.cgImage else { return }
        let version = UUID(), revision = UUID(); writeRevision = revision
        let archive = PencilArchive(formatVersion: 2, id: captureID, createdAt: Date(), conversationID: conversationID,
                                    libraryScope: scope, windowSize: window.bounds.size, region: region, strokes: strokes)
        let context = (conversationID, scope)
        overlay.showCandidate(at: region, ready: false)
        io.async { [weak self] in
            do {
                let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("Pencil Captures", isDirectory: true)
                let key = SHA256.hash(data: Data((archive.libraryScope + "/" + (archive.conversationID ?? "unsent")).utf8))
                    .map { String(format: "%02x", $0) }.joined()
                let directory = base.appendingPathComponent(key, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let stem = directory.appendingPathComponent(version.uuidString)
                try JSONEncoder().encode(archive).write(to: stem.appendingPathExtension("json"), options: [.atomic, .completeFileProtectionUnlessOpen])
                let drawing = PKDrawing(strokes: archive.strokes.map { stroke in
                    let origin = stroke.samples.first?.time ?? 0
                    let points = stroke.samples.map {
                        PKStrokePoint(location: $0.point, timeOffset: max(0, $0.time - origin),
                                      size: CGSize(width: stroke.width, height: stroke.width), opacity: 1,
                                      force: $0.force, azimuth: $0.azimuth, altitude: $0.altitude)
                    }
                    return PKStroke(ink: PKInk(stroke.marker ? .marker : .pen, color: stroke.inkColor),
                                    path: PKStrokePath(controlPoints: points, creationDate: archive.createdAt))
                })
                try drawing.dataRepresentation().write(to: stem.appendingPathExtension("drawing"), options: [.atomic, .completeFileProtectionUnlessOpen])
                let baseData = NSMutableData()
                guard let baseDestination = CGImageDestinationCreateWithData(baseData, "public.png" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
                CGImageDestinationAddImage(baseDestination, backgroundImage, nil)
                guard CGImageDestinationFinalize(baseDestination) else { throw CocoaError(.fileWriteUnknown) }
                try (baseData as Data).write(to: directory.appendingPathComponent(version.uuidString + ".background.png"), options: [.atomic, .completeFileProtectionUnlessOpen])
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
                let bounds = archive.strokes.reduce(CGRect.null) { $0.union($1.bounds) }.intersection(archive.region)
                let description: [String: Any] = ["format": "hajisaki-ink-v1", "stroke_count": archive.strokes.count,
                    "coordinate_space": "normalized-top-left", "background_present": true,
                    "image_pixels": ["width": cgImage.width, "height": cgImage.height],
                    "ink_bounds": ["x": (bounds.minX - archive.region.minX) / archive.region.width,
                                   "y": (bounds.minY - archive.region.minY) / archive.region.height,
                                   "width": bounds.width / archive.region.width, "height": bounds.height / archive.region.height],
                    "colors_rgba": Array(Set(archive.strokes.map { stroke in
                        let bytes = stroke.color.map { Int((min(1, max(0, $0)) * 255).rounded()) }
                        return String(format: "#%02X%02X%02X%02X", bytes[0], bytes[1], bytes[2], bytes[3])
                    }).sorted().prefix(16))]
                let text = String(decoding: try JSONSerialization.data(withJSONObject: description), as: UTF8.self)
                CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: text]] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                let url = directory.appendingPathComponent("圈画-\(version.uuidString).png")
                try (data as Data).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                Task { @MainActor in
                    guard let self, self.writeRevision == revision, self.scope == context.1, self.conversationID == context.0 else { return }
                    self.readyURL = url; self.readyContext = context
                    self.overlay?.showCandidate(at: archive.region, ready: true, image: UIImage(cgImage: cgImage))
                }
            } catch {
                Task { @MainActor in
                    guard let self, self.writeRevision == revision else { return }
                    self.notice = "圈画还在，这张手稿暂时没能收好。"
                    self.overlay?.showCandidate(at: archive.region, ready: false)
                }
            }
        }
    }

    fileprivate func share() {
        guard let url = readyURL, let context = readyContext,
              !sharing, context.scope == scope, context.id == conversationID else { return }
        sharing = true
        overlay?.showCandidate(at: strokes.reduce(CGRect.null) { $0.union($1.bounds) }, ready: false)
        onCapture?(url, context.id, context.scope)
    }

    @objc private func hoverChanged(_ recognizer: UIHoverGestureRecognizer) {
        guard active, !isDrawing, overlay?.ringVisible != true, let window else { return }
        guard recognizer.state == .began || recognizer.state == .changed else { overlay?.hidePreview(); return }
        let point = recognizer.location(in: window)
        if overlay?.previewContains(point) == true { return }
        var view = window.hitTest(point, with: nil)
        while let current = view {
            if let provider = current as? PencilPreviewProviding, let preview = provider.pencilPreview {
                showPreview(preview, at: point, sourceRect: current.convert(current.bounds, to: window)); return
            }
            view = current.superview
        }
        if let target = PencilPreviewArea.at(point, in: window) { showPreview(target.preview, at: point, sourceRect: target.convert(target.bounds, to: window)) }
        else { overlay?.hidePreview() }
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard active, squeeze.phase == .ended else { return }
        switch UIPencilInteraction.preferredSqueezeAction {
        case .showContextualPalette: presentForSqueeze(squeeze.timestamp, at: squeeze.hoverPose?.location)
        case .ignore, .runSystemShortcut: break
        case .showColorPalette, .showInkAttributes: break // PencilKit surfaces retain their dedicated palette.
        case .switchEraser, .switchPrevious: break // The active PencilKit surface handles these tool actions.
        @unknown default: break
        }
    }
}

private final class PencilInkGesture: UIGestureRecognizer {
    weak var controller: TheaterPencilController?
    private var touch: UITouch?
    private var buffered: [PencilSample] = []
    init(controller: TheaterPencilController) { self.controller = controller; super.init(target: nil, action: nil) }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, let first = touches.first else { state = .failed; return }
        touch = first; buffered = samples(first, event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        let values = samples(touch, event)
        if state == .possible {
            buffered.append(contentsOf: values)
            guard let first = buffered.first, let last = buffered.last, hypot(first.x - last.x, first.y - last.y) > 3 else { return }
            state = .began; controller?.begin(buffered); buffered = []
        } else { state = .changed; controller?.move(values) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        if state == .possible { state = .failed }
        else { controller?.move(samples(touch, event)); controller?.end(cancelled: false); state = .ended }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        controller?.end(cancelled: true); state = .cancelled
    }
    override func reset() { super.reset(); touch = nil; buffered = [] }
    private func samples(_ touch: UITouch, _ event: UIEvent) -> [PencilSample] {
        (event.coalescedTouches(for: touch) ?? [touch]).map { value in
            let point = value.location(in: view)
            return PencilSample(x: point.x, y: point.y, time: value.timestamp,
                                force: value.type == .pencil ? value.force : 1,
                                azimuth: value.azimuthAngle(in: view), altitude: value.altitudeAngle,
                                roll: value.type == .pencil ? value.rollAngle : 0)
        }
    }
}

@MainActor private final class PencilWindowOverlay: UIView {
    weak var controller: TheaterPencilController?
    var palette = TheaterPalette(isDark: true) { didSet { style() } }
    private let ring = UIView()
    private let ringBorder = CAShapeLayer()
    private let shareButton = UIButton(type: .system)
    private let candidateImage = UIImageView()
    private let preview = UIView()
    private let previewTitle = UILabel()
    private let previewText = UILabel()
    private let previewClose = UIButton(type: .system)
    private let previewGlow = CAShapeLayer()
    private var ink: [PencilStroke] = []
    private var inkSize = CGSize.zero
    private var previousSize = CGSize.zero
    private var candidate = CGRect.null
    var ringVisible: Bool { !ring.isHidden }

    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear; isOpaque = false; contentMode = .redraw
        previewGlow.fillColor = UIColor.clear.cgColor; previewGlow.lineWidth = 1
        previewGlow.shadowOpacity = 0.45; previewGlow.shadowRadius = 7; previewGlow.isHidden = true
        layer.addSublayer(previewGlow)
        ring.bounds = CGRect(x: 0, y: 0, width: 248, height: 248); ring.layer.cornerRadius = 124
        ring.layer.addSublayer(ringBorder); addSubview(ring); ring.isHidden = true
        let positions: [CGPoint] = [CGPoint(x: 124, y: 47), CGPoint(x: 199, y: 100), CGPoint(x: 172, y: 187), CGPoint(x: 76, y: 187), CGPoint(x: 49, y: 100)]
        for (index, command) in PencilCommand.allCases.enumerated() {
            let button = UIButton(type: .system); button.setTitle(command.title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            button.bounds = CGRect(x: 0, y: 0, width: 76, height: 48); button.center = positions[index]
            button.addAction(UIAction { [weak self] _ in self?.controller?.choose(command) }, for: .touchUpInside)
            ring.addSubview(button)
        }
        let close = UIButton(type: .system); close.setTitle("收起", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 12)
        close.frame = CGRect(x: 100, y: 100, width: 48, height: 48)
        close.addAction(UIAction { [weak self] _ in self?.hideRing() }, for: .touchUpInside); ring.addSubview(close)
        shareButton.setTitle("递给祥子看这段", for: .normal)
        shareButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        shareButton.layer.cornerRadius = 22; shareButton.layer.borderWidth = 0.5
        shareButton.addAction(UIAction { [weak self] _ in self?.controller?.share() }, for: .touchUpInside)
        addSubview(shareButton); shareButton.isHidden = true
        candidateImage.contentMode = .scaleAspectFit; candidateImage.layer.cornerRadius = 6
        candidateImage.clipsToBounds = true; addSubview(candidateImage); candidateImage.isHidden = true
        preview.layer.cornerRadius = 14; preview.layer.borderWidth = 0.5
        previewTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        previewText.font = .monospacedSystemFont(ofSize: 13, weight: .regular); previewText.numberOfLines = 8
        preview.addSubview(previewTitle); preview.addSubview(previewText); addSubview(preview); preview.isHidden = true
        previewClose.setTitle("收起", for: .normal); previewClose.titleLabel?.font = .systemFont(ofSize: 12)
        previewClose.addAction(UIAction { [weak self] _ in self?.hidePreview() }, for: .touchUpInside)
        preview.addSubview(previewClose)
        style()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func style() {
        ring.backgroundColor = UIColor(palette.raised); ringBorder.strokeColor = UIColor(palette.gold).cgColor
        ringBorder.fillColor = UIColor.clear.cgColor; ringBorder.lineWidth = 0.7
        for button in ring.subviews.compactMap({ $0 as? UIButton }) { button.setTitleColor(UIColor(palette.text), for: .normal) }
        shareButton.backgroundColor = UIColor(palette.raised); shareButton.layer.borderColor = UIColor(palette.gold).cgColor
        shareButton.setTitleColor(UIColor(palette.text), for: .normal)
        preview.backgroundColor = UIColor(palette.raised); preview.layer.borderColor = UIColor(palette.line).cgColor
        previewTitle.textColor = UIColor(palette.gold); previewText.textColor = UIColor(palette.text)
        previewClose.setTitleColor(UIColor(palette.blue), for: .normal)
        previewGlow.strokeColor = UIColor(palette.blue).cgColor; previewGlow.shadowColor = UIColor(palette.blue).cgColor
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size {
            previousSize = bounds.size; hidePreview(); setNeedsDisplay()
            ring.center = CGPoint(x: min(max(132, ring.center.x), max(132, bounds.width - 132)),
                                  y: min(max(safeAreaInsets.top + 132, ring.center.y), max(safeAreaInsets.top + 132, bounds.height - safeAreaInsets.bottom - 132)))
        }
        let path = UIBezierPath(ovalIn: ring.bounds.insetBy(dx: 5, dy: 5))
        path.append(UIBezierPath(ovalIn: ring.bounds.insetBy(dx: 15, dy: 15)))
        for index in 0..<24 {
            let angle = CGFloat(index) * .pi / 12
            let radius: CGFloat = index % 2 == 0 ? 113 : 116
            path.move(to: CGPoint(x: 124 + cos(angle) * radius, y: 124 + sin(angle) * radius))
            path.addLine(to: CGPoint(x: 124 + cos(angle) * 119, y: 124 + sin(angle) * 119))
        }
        ringBorder.frame = ring.bounds; ringBorder.path = path.cgPath
        if !candidate.isNull {
            let width: CGFloat = candidateImage.isHidden ? 184 : 248
            let x = min(max(12, candidate.midX - width / 2), max(12, bounds.width - width - 12))
            let y = min(max(safeAreaInsets.top + 64, candidate.maxY + 12), bounds.height - safeAreaInsets.bottom - 60)
            candidateImage.frame = CGRect(x: x, y: y, width: 56, height: 44)
            shareButton.frame = CGRect(x: x + (candidateImage.isHidden ? 0 : 64), y: y, width: 184, height: 44)
        }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden else { return nil }
        if !ring.isHidden { return ring.frame.contains(point) ? super.hitTest(point, with: event) : self }
        if !preview.isHidden && preview.frame.contains(point) { return super.hitTest(point, with: event) }
        if !shareButton.isHidden && shareButton.frame.contains(point) { return super.hitTest(point, with: event) }
        return nil
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { hideRing() }
    func showRing(at point: CGPoint) {
        hidePreview(); ring.center = CGPoint(x: min(max(132, point.x), max(132, bounds.width - 132)),
                                            y: min(max(safeAreaInsets.top + 132, point.y), max(safeAreaInsets.top + 132, bounds.height - safeAreaInsets.bottom - 132)))
        ring.isHidden = false; setNeedsLayout()
    }
    func hideRing() { ring.isHidden = true }
    func setInk(_ strokes: [PencilStroke]) { if ink.isEmpty && !strokes.isEmpty { inkSize = bounds.size }; ink = strokes; setNeedsDisplay() }
    func hideInkFromContent() { inkSize = .zero; setNeedsDisplay() }
    func clearInk() { ink = []; inkSize = .zero; candidate = .null; shareButton.isHidden = true; candidateImage.isHidden = true; candidateImage.image = nil; setNeedsDisplay() }
    func hideCandidate() { shareButton.isHidden = true; candidateImage.isHidden = true }
    func showCandidate(at rect: CGRect, ready: Bool, image: UIImage? = nil) {
        candidate = rect; shareButton.isHidden = false; shareButton.isEnabled = ready
        if let image { candidateImage.image = image }
        candidateImage.isHidden = candidateImage.image == nil
        shareButton.setTitle(ready ? "递给祥子看这段" : "正在收好圈画…", for: .normal)
        setNeedsLayout()
    }
    func showPreview(_ value: PencilPreview, at point: CGPoint) {
        previewTitle.text = value.title; previewText.text = String(value.text.prefix(1000))
        let width = min(340, bounds.width - 32), height: CGFloat = 210
        preview.frame = CGRect(x: min(max(16, point.x + 22), bounds.width - width - 16),
                               y: min(max(safeAreaInsets.top + 16, point.y - height - 16), bounds.height - height - 16), width: width, height: height)
        previewTitle.frame = CGRect(x: 16, y: 14, width: width - 88, height: 24)
        previewClose.frame = CGRect(x: width - 64, y: 4, width: 52, height: 44)
        previewText.frame = CGRect(x: 16, y: 48, width: width - 32, height: 146)
        preview.isHidden = false
    }
    func highlightPreviewSource(_ rect: CGRect?) {
        guard let rect, !rect.isNull, rect.width > 0, rect.height > 0 else { previewGlow.isHidden = true; return }
        previewGlow.frame = bounds
        previewGlow.path = UIBezierPath(roundedRect: rect.intersection(bounds).insetBy(dx: -2, dy: -2), cornerRadius: 7).cgPath
        previewGlow.isHidden = false
    }
    func hidePreview() { preview.isHidden = true; previewGlow.isHidden = true }
    func previewContains(_ point: CGPoint) -> Bool { !preview.isHidden && preview.frame.contains(point) }
    override func draw(_ rect: CGRect) { if inkSize == bounds.size, let context = UIGraphicsGetCurrentContext() { Self.render(ink, in: context) } }
    nonisolated static func render(_ strokes: [PencilStroke], in context: CGContext) {
        for stroke in strokes {
            guard let first = stroke.samples.first else { continue }
            context.saveGState()
            let color = CGColor(red: stroke.color[0], green: stroke.color[1], blue: stroke.color[2], alpha: stroke.color[3])
            context.setStrokeColor(color); context.setFillColor(color)
            context.setLineWidth(stroke.width); context.setLineCap(.round); context.setLineJoin(.round)
            if stroke.marker {
                context.setAlpha(stroke.color[3]); context.beginTransparencyLayer(auxiliaryInfo: nil)
                context.setFillColor(CGColor(red: stroke.color[0], green: stroke.color[1], blue: stroke.color[2], alpha: 1))
                var previous = first
                for point in stroke.samples {
                    let distance = hypot(point.x - previous.x, point.y - previous.y)
                    let count = max(1, min(2048, Int(ceil(distance / 2))))
                    let angle = atan2(sin(point.roll - previous.roll), cos(point.roll - previous.roll))
                    for index in 1...count {
                        let fraction = CGFloat(index) / CGFloat(count)
                        context.saveGState()
                        context.translateBy(x: previous.x + (point.x - previous.x) * fraction,
                                            y: previous.y + (point.y - previous.y) * fraction)
                        context.rotate(by: previous.roll + angle * fraction + .pi / 2)
                        context.fillEllipse(in: CGRect(x: -stroke.width / 2, y: -2, width: stroke.width, height: 4))
                        context.restoreGState()
                    }
                    previous = point
                }
                context.endTransparencyLayer()
            } else {
                context.beginPath(); context.move(to: first.point)
                for point in stroke.samples.dropFirst() { context.addLine(to: point.point) }
                context.strokePath()
            }
            context.restoreGState()
        }
    }
}

struct TheaterPencilBridge: UIViewRepresentable {
    let controller: TheaterPencilController
    let scope: String
    let conversationID: String?
    let contentContext: String
    let active: Bool
    let palette: TheaterPalette
    let onCommand: (PencilCommand) -> Void
    let onCapture: (URL, String?, String) -> Void
    func makeUIView(context: Context) -> PencilWindowAnchor {
        let view = PencilWindowAnchor(); view.isUserInteractionEnabled = false; view.controller = controller; return view
    }
    func updateUIView(_ view: PencilWindowAnchor, context: Context) {
        controller.configure(scope: scope, conversationID: conversationID, contentContext: contentContext, active: active, palette: palette,
                             onCommand: onCommand, onCapture: onCapture)
        if let window = view.window { controller.attach(to: window) }
    }
    static func dismantleUIView(_ view: PencilWindowAnchor, coordinator: ()) { view.controller?.detach() }
}

final class PencilWindowAnchor: UIView {
    weak var controller: TheaterPencilController?
    override func didMoveToWindow() { super.didMoveToWindow(); if let window { controller?.attach(to: window) } }
}

private final class PencilPreviewArea: UIView {
    static let areas = NSHashTable<PencilPreviewArea>.weakObjects()
    var preview = PencilPreview(title: "", text: "")
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false; Self.areas.add(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func at(_ point: CGPoint, in window: UIWindow) -> PencilPreviewArea? {
        areas.allObjects.filter { $0.window === window && !$0.isHidden && $0.alpha > 0 && $0.bounds.width > 0 &&
            $0.convert($0.bounds, to: window).contains(point) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
}

private struct PencilPreviewRegistration: UIViewRepresentable {
    var preview: PencilPreview
    func makeUIView(context: Context) -> PencilPreviewArea { PencilPreviewArea() }
    func updateUIView(_ view: PencilPreviewArea, context: Context) { view.preview = preview }
}

extension View {
    func pencilPreview(title: String, text: String) -> some View {
        background(PencilPreviewRegistration(preview: PencilPreview(title: title, text: text)))
    }
}
