import SwiftUI
import UIKit

/// A source-faithful window stage. The figure and its receiving material stay
/// together; a separately masked closed-eyelid image supplies the natural blink.
struct LivingStageView: View {
    let isNight: Bool
    var posture: StagePosture = .idle
    var closeUp = false
    var isPresented = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        LivingStageSurface(
            isNight: isNight,
            posture: posture,
            closeUp: closeUp,
            animate: isPresented && !reduceMotion && !lowPower && scenePhase == .active
        )
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .task(id: StageArtworkKey(night: isNight, posture: posture)) {
            await StageImageRenderer.shared.prewarm(night: isNight, preferred: posture)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private var accessibilityDescription: String {
        switch posture {
        case .idle: return isNight ? "夜色窗边的祥子" : "窗边的祥子"
        case .thinking: return "祥子托腮思考"
        case .reading: return "祥子在读乐谱"
        case .watching: return "祥子在看这页"
        case .tea: return "祥子捧着茶盏"
        }
    }
}

private struct LivingStageSurface: UIViewRepresentable {
    let isNight: Bool
    let posture: StagePosture
    let closeUp: Bool
    let animate: Bool

    func makeUIView(context: Context) -> LivingStageSurfaceView {
        LivingStageSurfaceView()
    }

    func updateUIView(_ view: LivingStageSurfaceView, context: Context) {
        view.configure(night: isNight, posture: posture, closeUp: closeUp, animate: animate)
    }

    static func dismantleUIView(_ view: LivingStageSurfaceView, coordinator: ()) { view.suspend() }
}

private final class LivingStageSurfaceView: UIView {
    private let roomLayer = CALayer()
    private let lightLayer = CAGradientLayer()
    private let figureLayer = CALayer()
    private let blinkLayer = CALayer()
    private let steamLayers = (0..<3).map { _ in CAShapeLayer() }
    private var desiredKey: StageArtworkKey?
    private var displayedKey: StageArtworkKey?
    private var hasLayeredScene = false
    private var loadTask: Task<Void, Never>?
    private var allowsAmbientMotion = false
    private var closeUp = false
    private var steamOrigin: CGPoint?
    private var blinkTimer: Timer?
    private var blinkGeneration: UInt = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        backgroundColor = UIColor(displayP3Red: 0x17 / 255.0, green: 0x13 / 255.0, blue: 0x1F / 255.0, alpha: 1)
        roomLayer.contentsGravity = .resize
        figureLayer.contentsGravity = .resize
        blinkLayer.contentsGravity = .resize
        blinkLayer.opacity = 0
        lightLayer.type = .radial
        lightLayer.isHidden = true
        lightLayer.startPoint = CGPoint(x: 0.38, y: 0.35)
        lightLayer.endPoint = CGPoint(x: 0.78, y: 0.88)
        layer.addSublayer(roomLayer)
        layer.addSublayer(lightLayer)
        layer.addSublayer(figureLayer)
        for steam in steamLayers {
            steam.fillColor = nil
            steam.strokeColor = UIColor(white: 1, alpha: 0.72).cgColor
            steam.lineCap = .round; steam.opacity = 0
            layer.addSublayer(steam)
        }
        layer.addSublayer(blinkLayer)
    }

    required init?(coder: NSCoder) { return nil }

    func configure(night: Bool, posture: StagePosture, closeUp: Bool, animate: Bool) {
        allowsAmbientMotion = animate
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.cornerRadius = closeUp ? 16 : 0
        layer.borderWidth = closeUp ? 0.8 : 0
        layer.borderColor = (night ? UIColor(displayP3Red: 0xE3 / 255.0, green: 0xC4 / 255.0, blue: 0x8E / 255.0, alpha: 0.42)
                                   : UIColor(displayP3Red: 0xA8 / 255.0, green: 0x84 / 255.0, blue: 0x4C / 255.0, alpha: 0.42)).cgColor
        backgroundColor = night ? UIColor(displayP3Red: 0x17 / 255.0, green: 0x13 / 255.0, blue: 0x1F / 255.0, alpha: 1)
                                : UIColor(displayP3Red: 0xF5 / 255.0, green: 0xE8 / 255.0, blue: 0xE6 / 255.0, alpha: 1)
        CATransaction.commit()
        if self.closeUp != closeUp { self.closeUp = closeUp; setNeedsLayout() }
        let key = StageArtworkKey(night: night, posture: posture)
        if desiredKey != key {
            desiredKey = key
            loadTask?.cancel()
            cancelBlink()
            layer.removeAnimation(forKey: "daylight")
            roomLayer.removeAnimation(forKey: "daylight")
            figureLayer.removeAnimation(forKey: "daylight")
            blinkLayer.contents = nil
            // The asset-catalog image is byte-identical to the source mother.
            // Show it immediately using the same layer geometry, while the
            // masked foreground is prepared away from the UI actor.
            if displayedKey?.night != night,
               let source = UIImage(named: night ? "night-room" : "day-room")?.cgImage {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                roomLayer.contents = source
                figureLayer.contents = nil
                hasLayeredScene = false
                lightLayer.isHidden = true
                displayedKey = StageArtworkKey(night: night, posture: .idle)
                setNeedsLayout()
                layoutIfNeeded()
                CATransaction.commit()
            }
            loadTask = Task { @MainActor [weak self] in
                let images = await StageImageRenderer.shared.images(for: key)
                guard !Task.isCancelled, let self, self.desiredKey == key, let images else { return }
                // Swap the registered complete pose and its own eyelids in one
                // transaction; do not crossfade two different faces or hands.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.roomLayer.contents = images.background
                self.figureLayer.contents = images.foreground
                self.blinkLayer.contents = images.closedEyes
                self.steamOrigin = images.steamOrigin
                self.hasLayeredScene = images.foreground != nil
                self.lightLayer.isHidden = !self.hasLayeredScene
                self.displayedKey = key
                self.setNeedsLayout()
                self.layoutIfNeeded()
                CATransaction.commit()
                self.updateAmbientMotion()
            }
        }
        let tint = posture == .thinking
            ? UIColor(red: 0.54, green: 0.71, blue: 0.98, alpha: 0.035)
            : UIColor(red: 1, green: 0.83, blue: 0.56, alpha: night ? 0.035 : 0.022)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lightLayer.colors = [tint.cgColor, UIColor.clear.cgColor]
        CATransaction.commit()
        updateAmbientMotion()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        // All layers share a single crop. A rightward focal point keeps her face
        // and supported seated pose visible in the narrow 11-inch side stage.
        let scale = closeUp ? max(bounds.width / 240, bounds.height / 260) : max(bounds.width / 1536, bounds.height / 1024)
        let width = 1536 * scale
        let height = 1024 * scale
        let x = closeUp ? bounds.midX - 1155 * scale : min(0, max(bounds.width - width, bounds.width * 0.5 - width * 0.735))
        let y = closeUp ? bounds.midY - 230 * scale : (bounds.height - height) * 0.5
        let canvas = CGRect(x: x, y: y, width: width, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        roomLayer.frame = canvas
        figureLayer.frame = canvas
        lightLayer.frame = canvas
        blinkLayer.frame = canvas
        for (index, steam) in steamLayers.enumerated() {
            steam.frame = canvas
            if let origin = steamOrigin {
                let start = CGPoint(x: (origin.x + CGFloat(index - 1) * 9) * scale, y: origin.y * scale)
                let path = UIBezierPath(); path.move(to: start)
                path.addCurve(to: CGPoint(x: start.x + 2 * scale, y: start.y - 49 * scale),
                              controlPoint1: CGPoint(x: start.x - 11 * scale, y: start.y - 17 * scale),
                              controlPoint2: CGPoint(x: start.x + 12 * scale, y: start.y - 32 * scale))
                steam.path = path.cgPath; steam.lineWidth = 1.4 * scale
            } else { steam.path = nil }
        }
        CATransaction.commit()
        updateAmbientMotion()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAmbientMotion()
    }

    func suspend() {
        loadTask?.cancel(); allowsAmbientMotion = false
        updateAmbientMotion()
    }

    private func updateAmbientMotion() {
        let visible = isMountedInWindow
        let canAnimate = hasLayeredScene && allowsAmbientMotion && visible && displayedKey == desiredKey
        if canAnimate && blinkLayer.contents != nil {
            scheduleBlinkIfNeeded()
        } else {
            cancelBlink()
        }
        updateSteam(animate: canAnimate && !closeUp && steamOrigin != nil)
        let shouldAnimate = canAnimate && displayedKey?.posture != .reading
        guard shouldAnimate else {
            lightLayer.removeAnimation(forKey: "ambient-light")
            lightLayer.opacity = 0.65
            return
        }
        guard lightLayer.animation(forKey: "ambient-light") == nil else { return }
        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [0.55, 0.85, 0.65, 0.55]
        glow.keyTimes = [0, 0.4, 0.76, 1]
        glow.duration = 13
        glow.repeatCount = .infinity
        glow.calculationMode = .cubic
        lightLayer.add(glow, forKey: "ambient-light")
    }

    private func updateSteam(animate: Bool) {
        for (index, steam) in steamLayers.enumerated() {
            guard animate else { steam.removeAnimation(forKey: "tea-steam"); steam.opacity = 0; continue }
            guard steam.animation(forKey: "tea-steam") == nil else { continue }
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 0.21, 0.13, 0]; opacity.keyTimes = [0, 0.25, 0.68, 1]
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 0; rise.toValue = -11 * figureLayer.frame.height / 1024
            let group = CAAnimationGroup(); group.animations = [opacity, rise]
            group.duration = 3.7 + Double(index) * 0.23
            group.beginTime = CACurrentMediaTime() + Double(index) * 1.15
            group.repeatCount = .infinity
            steam.add(group, forKey: "tea-steam")
        }
    }

    private var isMountedInWindow: Bool {
        // These surfaces occupy fixed inspector/header slots. UIKit hosting
        // ancestor flags do not describe the composited SwiftUI header slot.
        // Presentation/scene/power flags and dismantling own suspension.
        window != nil && !bounds.isEmpty
    }

    private func scheduleBlinkIfNeeded() {
        guard blinkTimer == nil else { return }
        // Every wait is newly sampled; this is not a repeating metronome.
        let generation = blinkGeneration
        let timer = Timer(timeInterval: Double.random(in: 3.4...7.8), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.blinkGeneration == generation else { return }
                self.performBlink()
            }
        }
        timer.tolerance = 0.12
        blinkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func performBlink() {
        blinkTimer = nil
        guard hasLayeredScene, allowsAmbientMotion, isMountedInWindow,
              displayedKey == desiredKey, blinkLayer.contents != nil else {
            cancelBlink()
            return
        }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [0, 1, 1, 0]
        blink.keyTimes = [0, 0.265, 0.588, 1]
        blink.duration = 0.17
        blink.calculationMode = .linear
        blink.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeOut)]
        blinkLayer.add(blink, forKey: "natural-blink")
        scheduleBlinkIfNeeded()
    }

    private func cancelBlink() {
        blinkGeneration &+= 1
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkLayer.removeAnimation(forKey: "natural-blink")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blinkLayer.opacity = 0
        CATransaction.commit()
    }

    deinit {
        blinkTimer?.invalidate()
        loadTask?.cancel()
    }
}
