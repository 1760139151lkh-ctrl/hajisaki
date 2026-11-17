import Foundation
import CoreImage
import ImageIO
import Metal
import os

enum StagePosture: String, Sendable { case idle, thinking, reading, watching, tea }

struct StageArtworkKey: Hashable, Sendable {
    let night: Bool
    let posture: StagePosture
}

final class StagePlaneImages: @unchecked Sendable {
    let background: CGImage
    let foreground: CGImage?
    let closedEyes: CGImage?
    let steamOrigin: CGPoint?

    init(background: CGImage, foreground: CGImage?, closedEyes: CGImage? = nil, steamOrigin: CGPoint? = nil) {
        self.background = background; self.foreground = foreground
        self.closedEyes = closedEyes; self.steamOrigin = steamOrigin
    }
}

private struct StageSprite: Decodable {
    let theme: String
    let posture: StagePosture
    let file: String
    let closedFile: String?
    let closedOffset: [CGFloat]?
    let eyeRects: [[CGFloat]]
    let steamOrigin: [CGFloat]?
    let characterBounds: [CGFloat]
}

extension StagePosture: Decodable {}

/// Immutable, color-managed images are prepared away from the UI actor. Only
/// the active theme's small working set stays decoded; no per-frame raster work.
actor StageImageRenderer {
    static let shared = StageImageRenderer()
    private var cache: [StageArtworkKey: StagePlaneImages] = [:]
    private var order: [StageArtworkKey] = []
    private var rooms: [Bool: CGImage] = [:]
    private var catalog: [StageSprite]?
    private let outputSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    private let log = Logger(subsystem: "app.hajisaki.theater.ipad", category: "living-stage")
    private lazy var context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: outputSpace, .outputColorSpace: outputSpace, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options.merging([.useSoftwareRenderer: true]) { _, new in new })
    }()

    func images(for key: StageArtworkKey) -> StagePlaneImages? {
        if let existing = cache[key] { touch(key); return existing }
        let prefix = key.night ? "night" : "day"
        guard let mother = read(prefix + "-mother"), let background = room(night: key.night) else {
            log.error("The window-stage source image could not be loaded."); return nil
        }
        guard let figure = read(prefix + "-figure-mask"), let contact = read(prefix + "-contact-mask") else {
            return remember(StagePlaneImages(background: mother, foreground: nil), for: key)
        }
        let source = CIImage(cgImage: mother)
        let clear = CIImage(color: .clear).cropped(to: source.extent)
        let sprite = sprites().first { $0.theme == prefix && $0.posture == key.posture }
        let foreground: CIImage
        if let sprite, let candidate = read(sprite.file, directory: "poses"),
           candidate.width == mother.width, candidate.height == mother.height,
           let bounds = sourceRect(sprite.characterBounds, height: source.extent.height) {
            // Retain receiving material/shadows, but remove the old character.
            // The new complete RGBA pose owns every visible body pixel.
            let inverseFigure = CIImage(cgImage: figure).applyingFilter("CIColorInvert")
            let receiverMask = CIImage(cgImage: contact).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: inverseFigure])
            let receiver = source.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: receiverMask])
            let actor = CIImage(cgImage: candidate).cropped(to: bounds.intersection(source.extent))
            foreground = actor.composited(over: receiver)
        } else {
            if key.posture != .idle { log.error("The requested registered pose is unavailable; retaining the approved idle source.") }
            let mask = CIImage(cgImage: figure).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: CIImage(cgImage: contact)])
            foreground = source.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask])
        }
        guard let cutout = context.createCGImage(foreground, from: source.extent, format: .RGBA8, colorSpace: outputSpace) else {
            log.error("Window-stage composition failed; retaining the approved source.")
            return remember(StagePlaneImages(background: mother, foreground: nil), for: key)
        }
        let eyes = closedEyes(key: key, sprite: sprite, extent: source.extent)
        let steam: CGPoint?
        if let point = sprite?.steamOrigin, point.count == 2 { steam = CGPoint(x: point[0], y: point[1]) }
        else { steam = nil }
        return remember(StagePlaneImages(background: background, foreground: cutout, closedEyes: eyes, steamOrigin: steam), for: key)
    }

    func prewarm(night: Bool, preferred: StagePosture) async {
        let postures = [preferred] + [StagePosture.idle, .thinking, .reading, .watching, .tea].filter { $0 != preferred }
        for posture in postures {
            guard !Task.isCancelled else { return }
            _ = images(for: StageArtworkKey(night: night, posture: posture))
            await Task.yield()
        }
    }

    private func remember(_ images: StagePlaneImages, for key: StageArtworkKey) -> StagePlaneImages {
        cache[key] = images; touch(key)
        while order.count > 6 { cache.removeValue(forKey: order.removeFirst()) }
        return images
    }
    private func touch(_ key: StageArtworkKey) { order.removeAll { $0 == key }; order.append(key) }

    private func room(night: Bool) -> CGImage? {
        if let image = rooms[night] { return image }
        guard let raw = read((night ? "night" : "day") + "-background"),
              let image = context.createCGImage(CIImage(cgImage: raw), from: CGRect(x: 0, y: 0, width: raw.width, height: raw.height), format: .RGBA8, colorSpace: outputSpace) else { return nil }
        rooms[night] = image; return image
    }

    private func sprites() -> [StageSprite] {
        if let catalog { return catalog }
        struct Catalog: Decodable { let sprites: [StageSprite] }
        guard let url = assetURL("manifest.json", directory: "poses"),
              let data = try? Data(contentsOf: url), data.count <= 128 * 1024,
              let value = try? JSONDecoder().decode(Catalog.self, from: data) else {
            log.error("The registered pose catalog could not be read."); catalog = []; return []
        }
        catalog = value.sprites; return value.sprites
    }

    private func closedEyes(key: StageArtworkKey, sprite: StageSprite?, extent: CGRect) -> CGImage? {
        let name: String
        let directory: String
        let rects: [[CGFloat]]
        if key.posture == .idle {
            name = (key.night ? "night" : "day") + "-closed-v1.png"; directory = "blink"
            rects = key.night ? [[1118,209,37,30],[1170,187,35,28]] : [[1100,220,44,35],[1150,194,48,40]]
        } else {
            guard let sprite, let file = sprite.closedFile else { return nil }
            name = file; directory = "poses"; rects = sprite.eyeRects
        }
        guard let candidate = read(name, directory: directory), candidate.width == Int(extent.width), candidate.height == Int(extent.height) else { return nil }
        var mask = CIImage(color: .black).cropped(to: extent)
        for values in rects {
            guard let rect = sourceRect(values, height: extent.height) else { continue }
            for step in 1...12 {
                let progress = CGFloat(step) / 12
                let value = progress * progress * (3 - 2 * progress)
                let band = CIImage(color: CIColor(red: value, green: value, blue: value)).cropped(to: rect.insetBy(dx: 2 * progress, dy: 2 * progress))
                mask = band.composited(over: mask)
            }
        }
        var registered = CIImage(cgImage: candidate)
        if let offset = sprite?.closedOffset, offset.count == 2, offset.allSatisfy({ $0.isFinite && abs($0) <= 64 }) {
            // One uniform registration of the entire candidate canvas; the eye
            // masks stay fixed on the open pose. No independent feature warp.
            registered = registered.transformed(by: CGAffineTransform(translationX: offset[0], y: -offset[1]))
        }
        // Closed skin/lashes fully replace the iris inside the feathered mask.
        // Candidate alpha elsewhere is never used as a full character layer.
        let opaque = registered.unpremultiplyingAlpha().applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        let overlay = opaque.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent), kCIInputMaskImageKey: mask])
        return context.createCGImage(overlay, from: extent, format: .RGBA8, colorSpace: outputSpace)
    }

    private func sourceRect(_ values: [CGFloat], height: CGFloat) -> CGRect? {
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: height - values[1] - values[3], width: values[2], height: values[3])
    }
    private func read(_ name: String, directory: String? = nil) -> CGImage? {
        let file = name.hasSuffix(".png") ? name : name + ".png"
        guard let url = assetURL(file, directory: directory), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    private func assetURL(_ name: String, directory: String?) -> URL? {
        let suffix = directory.map { "/" + $0 } ?? ""
        return ["assets/living-stage" + suffix, "living-stage" + suffix].lazy.compactMap {
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: $0)
        }.first
    }
}
