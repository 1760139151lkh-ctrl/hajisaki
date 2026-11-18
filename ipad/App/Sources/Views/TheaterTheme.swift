import SwiftUI
import UIKit
import CoreText

/// 公主的琴房：珍珠与胭脂、古金细线、她的藏青缎带。温柔、有爱，但不甜腻。
/// 布局沿用“信笺”；色值与手机端 `studio/src/style.css` 同步。昼为“春日”，夜为“月下”。
struct TheaterPalette {
    let isDark: Bool
    static func p3(_ hex: UInt32, alpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor(displayP3Red: CGFloat((hex >> 16) & 255) / 255,
                               green: CGFloat((hex >> 8) & 255) / 255,
                               blue: CGFloat(hex & 255) / 255, alpha: alpha))
    }
    private func tone(_ night: UInt32, _ day: UInt32) -> Color { Self.p3(isDark ? night : day) }

    var background: Color { tone(0x17131F, 0xFBF4F1) }
    var raised: Color { tone(0x211B2B, 0xFFFCFA) }
    var sidebar: Color { tone(0x1C1726, 0xF8EEEB) }
    var letter: Color { raised }
    var sunken: Color { tone(0x2B2337, 0xF5E8E6) }
    var text: Color { tone(0xF3E9E4, 0x2E2638) }
    var secondary: Color { tone(0xBBADB7, 0x6C5F75) }
    var dim: Color { tone(0x8E8098, 0x8D7F93) }
    var blue: Color { tone(0xB6C4F1, 0x4F68AE) }
    var gold: Color { tone(0xE3C48E, 0xA8844C) }
    var rose: Color { tone(0xEDA3B9, 0xB8506F) }
    var roseStrong: Color { rose }
    /// Saki's ribbon.
    var navy: Color { tone(0x575073, 0x2F2A45) }
    var warning: Color { tone(0xF0899E, 0xB6405C) }
    var online: Color { tone(0x8FD0B0, 0x4E9A76) }
    var bubble: Color { tone(0x352840, 0xF6E1E5) }
    var bubbleText: Color { text }
    /// Text on Saki's blue.
    var onAccent: Color { tone(0x141526, 0xFFFFFF) }
    /// Text on satin rose and wax.
    var onRose: Color { Self.p3(0xFFFFFF) }
    var ivory: Color { Self.p3(0xFFF7EF) }
    /// Neutral separators between rows.
    var line: Color { isDark ? Self.p3(0xF3E9E4, alpha: 0.08) : Self.p3(0x2E2638, alpha: 0.08) }
    /// Antique-gold hairline used for frames, outlines and filigree.
    var stitch: Color { gold.opacity(0.42) }
    var goldLine: Color { gold.opacity(0.42) }
    var selection: Color { sunken }
    var blueSoft: Color { blue.opacity(isDark ? 0.12 : 0.08) }
    var goldSoft: Color { gold.opacity(isDark ? 0.10 : 0.09) }
    var glow: Color { .clear }
    var shadow: Color { Self.p3(isDark ? 0x000000 : 0x5A3044, alpha: isDark ? 0.30 : 0.07) }
    /// Satin rose for primary actions.
    var satin: LinearGradient {
        LinearGradient(colors: [Self.p3(0xC25D7E), Self.p3(0xA9466A)], startPoint: .top, endPoint: .bottom)
    }
    func wax(_ size: CGFloat) -> RadialGradient {
        RadialGradient(colors: [Self.p3(0xD77D9A), Self.p3(0xB8506F), Self.p3(0x8C3350)],
                       center: UnitPoint(x: 0.36, y: 0.3), startRadius: 0, endRadius: size * 0.72)
    }
    /// The two rooms the companion lives in.
    var roomName: String { isDark ? "月下" : "春日" }
}

private struct TheaterPaletteKey: EnvironmentKey {
    static let defaultValue = TheaterPalette(isDark: true)
}
extension EnvironmentValues {
    var theaterPalette: TheaterPalette {
        get { self[TheaterPaletteKey.self] }
        set { self[TheaterPaletteKey.self] = newValue }
    }
}

/// The bundled serif lives beside the offline renderer so the generated project needs no new build phase.
enum TheaterFonts {
    static let serifName = "NotoSerifSC-Medium"
    /// Pinyon Script: short Latin lines only, always in gold.
    static let scriptName = "PinyonScript-Regular"
    static func register() {
        for (name, ext) in [("HajiSerif-Medium", "otf"), ("HajiScript", "ttf")] {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Renderer/fonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Font {
    /// Saki's voice: fixed copy, names, titles. Falls back to the system font if registration failed.
    static func theaterSerif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(TheaterFonts.serifName, size: size)
    }
    static func theaterScript(_ size: CGFloat) -> Font {
        .custom(TheaterFonts.scriptName, size: size)
    }
}

enum TheaterGlyphKind { case plus, close, sidebar, search, send, stop, more, pencil, book, chevron, settings, back, attachment, watch, heart, sparkle, lamp, quill, code, check, letter }

struct TheaterGlyph: Shape {
    var kind: TheaterGlyphKind
    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: rect.width * 0.17, dy: rect.height * 0.17)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height)
        }
        var path = Path()
        func line(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat) {
            path.move(to: point(ax, ay)); path.addLine(to: point(bx, by))
        }
        switch kind {
        case .plus: line(0.5, 0, 0.5, 1); line(0, 0.5, 1, 0.5)
        case .close: line(0.1, 0.1, 0.9, 0.9); line(0.9, 0.1, 0.1, 0.9)
        case .sidebar:
            path.addRoundedRect(in: box, cornerSize: CGSize(width: 3, height: 3)); line(0.32, 0, 0.32, 1)
        case .search:
            path.addEllipse(in: CGRect(x: box.minX, y: box.minY, width: box.width * 0.7, height: box.height * 0.7)); line(0.63, 0.63, 1, 1)
        case .send: line(0.15, 0.4, 0.5, 0.05); line(0.5, 0.05, 0.85, 0.4); line(0.5, 0.05, 0.5, 0.95)
        case .stop: path.addRoundedRect(in: box.insetBy(dx: 2, dy: 2), cornerSize: CGSize(width: 2, height: 2))
        case .more:
            for x in [CGFloat(0.12), 0.5, 0.88] { path.addEllipse(in: CGRect(x: point(x, 0.5).x - 1, y: point(x, 0.5).y - 1, width: 2, height: 2)) }
        case .pencil:
            path.addLines([point(0.1, 0.9), point(0.2, 0.59), point(0.76, 0.03), point(0.97, 0.24), point(0.4, 0.8), point(0.1, 0.9)]); line(0.65, 0.14, 0.86, 0.35)
        case .watch:
            path.addEllipse(in: CGRect(x: point(0.07, 0.19).x, y: point(0.07, 0.19).y, width: box.width * 0.86, height: box.height * 0.81))
            path.addEllipse(in: CGRect(x: point(0.27, 0).x, y: point(0.27, 0).y, width: box.width * 0.46, height: box.height * 0.21))
            line(0.5, 0.35, 0.5, 0.61); line(0.5, 0.61, 0.68, 0.72)
        case .book:
            path.addLines([point(0.5, 0.2), point(0.15, 0.06), point(0, 0.1), point(0, 0.86), point(0.15, 0.82), point(0.5, 0.96), point(0.85, 0.82), point(1, 0.86), point(1, 0.1), point(0.85, 0.06), point(0.5, 0.2), point(0.5, 0.96)])
        case .chevron: line(0.2, 0.35, 0.5, 0.65); line(0.5, 0.65, 0.8, 0.35)
        case .back: line(0.65, 0.1, 0.25, 0.5); line(0.25, 0.5, 0.65, 0.9)
        case .settings:
            for (x, y) in [(CGFloat(0.1), CGFloat(0.3)), (0.5, 0.7), (0.9, 0.4)] {
                line(x, 0.05, x, y - 0.12); line(x, y + 0.12, x, 0.95)
                path.addEllipse(in: CGRect(x: point(x, y).x - 2.2, y: point(x, y).y - 2.2, width: 4.4, height: 4.4))
            }
        case .attachment:
            path.move(to: point(0.78, 0.29)); path.addLine(to: point(0.37, 0.7))
            path.addQuadCurve(to: point(0.22, 0.55), control: point(0.1, 0.82))
            path.addLine(to: point(0.69, 0.08)); path.addQuadCurve(to: point(0.94, 0.34), control: point(1.1, -0.07))
            path.addLine(to: point(0.43, 0.85)); path.addQuadCurve(to: point(0.02, 0.46), control: point(-0.1, 1.16))
        case .heart:
            path = HeartShape().path(in: box)
        case .sparkle:
            path.move(to: point(0.5, 0)); path.addQuadCurve(to: point(1, 0.5), control: point(0.58, 0.42))
            path.addQuadCurve(to: point(0.5, 1), control: point(0.58, 0.58))
            path.addQuadCurve(to: point(0, 0.5), control: point(0.42, 0.58))
            path.addQuadCurve(to: point(0.5, 0), control: point(0.42, 0.42))
            path.closeSubpath()
        case .lamp:
            path.addLines([point(0.22, 0), point(0.78, 0), point(0.98, 0.5), point(0.02, 0.5), point(0.22, 0)])
            line(0.5, 0.5, 0.5, 0.94); line(0.26, 0.97, 0.74, 0.97)
        case .quill:
            path.move(to: point(0.98, 0.02))
            path.addQuadCurve(to: point(0.12, 0.76), control: point(0.32, 0.12))
            path.addLine(to: point(0.02, 0.98)); path.addLine(to: point(0.24, 0.9))
            path.addQuadCurve(to: point(0.98, 0.02), control: point(0.9, 0.7))
            line(0.18, 0.84, 0.56, 0.44)
        case .code:
            line(0.3, 0.2, 0, 0.5); line(0, 0.5, 0.3, 0.8)
            line(0.7, 0.2, 1, 0.5); line(1, 0.5, 0.7, 0.8)
            line(0.58, 0.06, 0.42, 0.94)
        case .check: line(0.06, 0.55, 0.38, 0.86); line(0.38, 0.86, 0.95, 0.16)
        case .letter:
            path.addRoundedRect(in: CGRect(x: box.minX, y: point(0, 0.14).y, width: box.width, height: box.height * 0.72),
                                cornerSize: CGSize(width: 2, height: 2))
            path.addLines([point(0.02, 0.2), point(0.5, 0.58), point(0.98, 0.2)])
        }
        return path
    }
}

/// A heart drawn from two gentle shoulders; it fills or strokes like any shape.
struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        func p(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: x + u * w, y: y + v * h) }
        var path = Path()
        path.move(to: p(0.5, 0.94))
        path.addCurve(to: p(0.03, 0.36), control1: p(0.27, 0.78), control2: p(0.01, 0.6))
        path.addCurve(to: p(0.5, 0.22), control1: p(0.05, 0.05), control2: p(0.4, 0.02))
        path.addCurve(to: p(0.97, 0.36), control1: p(0.6, 0.02), control2: p(0.95, 0.05))
        path.addCurve(to: p(0.5, 0.94), control1: p(0.99, 0.6), control2: p(0.73, 0.78))
        path.closeSubpath()
        return path
    }
}

/// Small filled heart, kept for the moments that mean something: pinned letters, her writing back.
struct HeartMark: View {
    var size: CGFloat = 10
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        HeartShape().fill(palette.rose).frame(width: size, height: size * 0.92).accessibilityHidden(true)
    }
}

/// A small antique-gold tiara, drawn beside her name and above her seal.
struct TiaraShape: Shape {
    func path(in rect: CGRect) -> Path {
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        func p(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: x + u * w, y: y + v * h) }
        var path = Path()
        // addLines(_:) starts a new subpath at its first point, so every corner goes in the array.
        path.addLines([p(0.06, 0.76), p(0.14, 0.34), p(0.33, 0.58), p(0.5, 0.16), p(0.67, 0.58), p(0.86, 0.34), p(0.94, 0.76)])
        path.closeSubpath()
        path.addRoundedRect(in: CGRect(x: x + 0.05 * w, y: y + 0.82 * h, width: 0.9 * w, height: 0.18 * h), cornerSize: CGSize(width: 0.04 * w, height: 0.04 * w))
        for (u, v, r) in [(CGFloat(0.14), CGFloat(0.26), CGFloat(0.075)), (0.5, 0.08, 0.09), (0.86, 0.26, 0.075)] {
            path.addEllipse(in: CGRect(x: x + u * w - r * w, y: y + v * h - r * w, width: 2 * r * w, height: 2 * r * w))
        }
        return path
    }
}

struct TiaraMark: View {
    var width: CGFloat = 13
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        TiaraShape().fill(palette.gold).frame(width: width, height: width * 0.72).accessibilityHidden(true)
    }
}

/// Saki's ribbon bow: two loops, a knot and two tails.
struct BowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        func p(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: x + u * w, y: y + v * h) }
        var path = Path()
        path.move(to: p(0.44, 0.38))
        path.addCurve(to: p(0.04, 0.16), control1: p(0.3, 0.2), control2: p(0.14, 0.06))
        path.addCurve(to: p(0.06, 0.66), control1: p(-0.04, 0.28), control2: p(-0.02, 0.56))
        path.addCurve(to: p(0.44, 0.56), control1: p(0.16, 0.76), control2: p(0.32, 0.66))
        path.closeSubpath()
        path.move(to: p(0.56, 0.38))
        path.addCurve(to: p(0.96, 0.16), control1: p(0.7, 0.2), control2: p(0.86, 0.06))
        path.addCurve(to: p(0.94, 0.66), control1: p(1.04, 0.28), control2: p(1.02, 0.56))
        path.addCurve(to: p(0.56, 0.56), control1: p(0.84, 0.76), control2: p(0.68, 0.66))
        path.closeSubpath()
        path.addLines([p(0.45, 0.58), p(0.3, 0.98), p(0.37, 0.93), p(0.42, 1.0), p(0.5, 0.62)]); path.closeSubpath()
        path.addLines([p(0.55, 0.58), p(0.7, 0.98), p(0.63, 0.93), p(0.58, 1.0), p(0.5, 0.62)]); path.closeSubpath()
        path.addRoundedRect(in: CGRect(x: x + 0.41 * w, y: y + 0.33 * h, width: 0.18 * w, height: 0.3 * h), cornerSize: CGSize(width: 0.05 * w, height: 0.05 * w))
        return path
    }
}

/// Navy bow with gold dashed stitching.
struct RibbonBow: View {
    var width: CGFloat = 46
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        ZStack {
            BowShape().fill(palette.navy)
            BowShape().stroke(palette.gold.opacity(0.85), style: StrokeStyle(lineWidth: 0.7, dash: [2.2, 1.8]))
                .scaleEffect(0.84)
        }.frame(width: width, height: width * 0.62).accessibilityHidden(true)
    }
}

/// A round wax seal with a soft sheen; holds an ivory heart, an arrow or 祥.
struct WaxSeal<Mark: View>: View {
    var size: CGFloat = 40
    @ViewBuilder var mark: () -> Mark
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        ZStack {
            Circle().fill(palette.wax(size))
            Circle().strokeBorder(Color.white.opacity(0.13), lineWidth: 1).padding(3)
            mark()
        }.frame(width: size, height: size)
            .shadow(color: Self.shadowColor, radius: 4, x: 0, y: 2)
    }
    private static var shadowColor: Color { TheaterPalette.p3(0x5A1E34, alpha: 0.28) }
}

struct WaxHeart: View {
    var size: CGFloat = 40
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        WaxSeal(size: size) { HeartShape().fill(palette.ivory).frame(width: size * 0.36, height: size * 0.33) }
    }
}

/// The brand: a rose wax disc with 祥, a small tiara resting above it.
struct SakiSeal: View {
    var size: CGFloat = 32
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        VStack(spacing: -size * 0.08) {
            TiaraMark(width: size * 0.5)
            WaxSeal(size: size) { Text("祥").font(.theaterSerif(size * 0.52)).foregroundStyle(palette.ivory) }
        }.accessibilityHidden(true)
    }
}

/// Round portrait on pearl, ringed by a gold hairline, with an optional presence dot.
struct CameoPortrait: View {
    let image: String
    var size: CGFloat = 44
    var online: Bool? = nil
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        Image(image).resizable().scaledToFill()
            .frame(width: size, height: size)
            .background(palette.sunken)
            .clipShape(Circle())
            .overlay(Circle().stroke(palette.goldLine, lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                if let online {
                    Circle().fill(online ? palette.online : palette.dim)
                        .frame(width: max(7, size * 0.2), height: max(7, size * 0.2))
                        .overlay(Circle().stroke(palette.background, lineWidth: 2))
                        .accessibilityHidden(true)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: image)
    }
}

/// Letter rows open with a pearl roundel bearing the title's first character.
struct MonogramRoundel: View {
    let title: String
    var pinned = false
    var size: CGFloat = 44
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        ZStack {
            Circle().fill(palette.raised)
            Circle().strokeBorder(palette.goldLine, lineWidth: 1)
            Circle().strokeBorder(palette.gold.opacity(0.2), lineWidth: 0.6).padding(4)
            Text(String(title.first(where: { $0.isLetter || $0.isNumber }) ?? "祥"))
                .font(.theaterSerif(size * 0.41)).foregroundStyle(palette.rose)
        }.frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if pinned { HeartMark(size: 9).offset(x: 1, y: -1) }
            }
            .accessibilityHidden(true)
    }
}

/// A frame with a semicircular top.
struct ArchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width / 2, k: CGFloat = 0.5523
        let left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY, mid = rect.midX
        var path = Path()
        path.move(to: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: top + r))
        path.addCurve(to: CGPoint(x: mid, y: top), control1: CGPoint(x: left, y: top + r - k * r), control2: CGPoint(x: mid - k * r, y: top))
        path.addCurve(to: CGPoint(x: right, y: top + r), control1: CGPoint(x: mid + k * r, y: top), control2: CGPoint(x: right, y: top + r - k * r))
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.closeSubpath()
        return path
    }
}

/// The scene in an arched pearl mat with a gold hairline; her bow rests on the arch and sways a little.
struct ArchedPortrait: View {
    let image: String
    var width: CGFloat = 220
    var height: CGFloat = 290
    /// Scenes are wide; Saki sits on the right, so keep the trailing part.
    var focus: Alignment = .trailing
    @Environment(\.theaterPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swaying = false
    var body: some View {
        ZStack(alignment: .top) {
            Image(image).resizable().scaledToFill()
                .frame(width: width - 14, height: height - 14, alignment: focus)
                .clipShape(ArchShape())
                .padding(7)
                .background(palette.raised, in: ArchShape())
                .overlay(ArchShape().stroke(palette.goldLine, lineWidth: 1))
                .shadow(color: palette.shadow, radius: 14, x: 0, y: 6)
            RibbonBow(width: width * 0.24)
                .rotationEffect(.degrees(swaying ? 2 : -2), anchor: .top)
                .animation(reduceMotion ? nil : Animation.easeInOut(duration: 3.5).repeatForever(autoreverses: true), value: swaying)
                .offset(y: -width * 0.06)
        }.frame(width: width, height: height)
            .onAppear { if !reduceMotion { swaying = true } }
            .accessibilityHidden(true)
    }
}

/// Gold hairline scrolls meeting at a small rose heart.
struct FiligreeDivider: View {
    var width: CGFloat = 140
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        HStack(spacing: 6) {
            Flourish().stroke(palette.goldLine, style: StrokeStyle(lineWidth: 1, lineCap: .round))
            HeartMark(size: 9)
            Flourish().stroke(palette.goldLine, style: StrokeStyle(lineWidth: 1, lineCap: .round)).scaleEffect(x: -1, y: 1)
        }.frame(width: width, height: 12).accessibilityHidden(true)
    }
    private struct Flourish: Shape {
        func path(in rect: CGRect) -> Path {
            let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
            var path = Path()
            path.move(to: CGPoint(x: x, y: y + h * 0.5))
            path.addLine(to: CGPoint(x: x + w * 0.7, y: y + h * 0.5))
            path.addCurve(to: CGPoint(x: x + w * 0.86, y: y + h * 0.12), control1: CGPoint(x: x + w * 0.8, y: y + h * 0.5), control2: CGPoint(x: x + w * 0.78, y: y + h * 0.12))
            path.addCurve(to: CGPoint(x: x + w * 0.9, y: y + h * 0.62), control1: CGPoint(x: x + w * 0.96, y: y + h * 0.12), control2: CGPoint(x: x + w * 0.98, y: y + h * 0.62))
            path.addCurve(to: CGPoint(x: x + w, y: y + h * 0.5), control1: CGPoint(x: x + w * 0.94, y: y + h * 0.62), control2: CGPoint(x: x + w * 0.97, y: y + h * 0.5))
            return path
        }
    }
}

/// Short Latin line in Pinyon Script, always gold. Never use it for Chinese.
struct ScriptLine: View {
    let text: String
    var size: CGFloat = 26
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        Text(text).font(.theaterScript(size)).foregroundStyle(palette.gold).lineLimit(1).accessibilityHidden(true)
    }
}

/// Her copperplate line, written in from left to right the way a pen would.
struct HandwrittenScript: View {
    let text: String
    var size: CGFloat = 26
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var written: CGFloat = 0
    var body: some View {
        ScriptLine(text: text, size: size)
            .mask(alignment: .leading) {
                GeometryReader { geometry in Rectangle().frame(width: geometry.size.width * written + 6) }
            }
            .onAppear {
                if reduceMotion { written = 1 }
                else { withAnimation(.timingCurve(0.45, 0.05, 0.3, 1, duration: 1.3).delay(0.15)) { written = 1 } }
            }
    }
}

/// The season outside her window, drifting past the glass: sakura in spring, motes of light in
/// summer, amber leaves in autumn, snow in winter; at night a few stars (and snow in winter).
/// Positions come from the clock, so nothing is stored and the drift continues across redraws.
struct SeasonalAir: View {
    let isNight: Bool
    var animate = true
    /// Like her living portrait, the drift rests in Low Power Mode.
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    enum Season { case spring, summer, autumn, winter }
    static func season(_ date: Date) -> Season {
        switch Calendar.current.component(.month, from: date) {
        case 3...5: return .spring
        case 6...8: return .summer
        case 9...11: return .autumn
        default: return .winter
        }
    }
    struct Mote: Identifiable {
        let id: Int
        let point: CGPoint
        let angle: Double
        let opacity: Double
        let size: CGFloat
        let kind: Kind
        enum Kind { case petal, leaf, snow, light, star }
    }
    private static let starPlaces: [(CGFloat, CGFloat)] = [(0.18, 0.09), (0.33, 0.05), (0.47, 0.13), (0.62, 0.07), (0.76, 0.16),
                                                            (0.26, 0.21), (0.55, 0.24), (0.84, 0.1), (0.4, 0.31)]
    static func motes(at time: Double, in size: CGSize, night: Bool, season: Season) -> [Mote] {
        var result: [Mote] = []
        if night {
            for (index, place) in starPlaces.enumerated() {
                let glow = 0.15 + 0.85 * (0.5 + 0.5 * sin(time * 2 * .pi / (2.6 + Double(index) * 0.35) + Double(index)))
                result.append(Mote(id: index, point: CGPoint(x: size.width * place.0, y: size.height * place.1),
                                   angle: 0, opacity: glow, size: index % 3 == 0 ? 4 : 3, kind: .star))
            }
            if season != .winter { return result }
        }
        let count = season == .summer ? 8 : night ? 6 : 7
        for index in 0..<count {
            let period = (season == .winter ? 15 : season == .summer ? 9 : 12) + Double(index) * 1.4
            let phase = (time + Double(index) * 2.3).truncatingRemainder(dividingBy: period) / period
            let travel = Double(size.height) + 40
            let y = season == .summer ? Double(size.height) + 10 - phase * travel : phase * travel - 20
            let x = Double(size.width) * (0.08 + Double((index * 13) % 84) / 100) + sin(phase * 2 * .pi + Double(index)) * 18
            let kind: Mote.Kind = season == .spring ? .petal : season == .autumn ? .leaf : season == .winter ? .snow : .light
            result.append(Mote(id: 100 + index, point: CGPoint(x: x, y: y),
                               angle: kind == .petal || kind == .leaf ? phase * 2 * .pi : 0,
                               opacity: min(1, min(phase, 1 - phase) * 8) * 0.85, size: 8 + CGFloat(index % 3) * 2, kind: kind))
        }
        return result
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate || lowPower)) { context in
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        ForEach(Self.motes(at: context.date.timeIntervalSinceReferenceDate, in: geometry.size, night: isNight,
                                           season: Self.season(context.date))) { mote in
                            Self.shape(mote).rotationEffect(.radians(mote.angle)).opacity(mote.opacity).position(mote.point)
                        }
                    }
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
                .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                    lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                }
        }
    }
    @ViewBuilder static func shape(_ mote: Mote) -> some View {
        switch mote.kind {
        case .petal:
            Ellipse().fill(Color(red: 0.98, green: 0.82, blue: 0.87)).frame(width: mote.size, height: mote.size * 0.72)
        case .leaf:
            Ellipse().fill(Color(red: 0.9, green: 0.6, blue: 0.33)).frame(width: mote.size + 3, height: mote.size * 0.6)
        case .snow:
            Circle().fill(Color.white).frame(width: mote.size * 0.6, height: mote.size * 0.6).shadow(color: .white.opacity(0.7), radius: 2)
        case .light:
            Circle().fill(Color(red: 1, green: 0.96, blue: 0.84)).frame(width: 4, height: 4)
                .shadow(color: Color(red: 1, green: 0.9, blue: 0.63).opacity(0.7), radius: 4)
        case .star:
            Circle().fill(Color(red: 1, green: 0.95, blue: 0.85)).frame(width: mote.size, height: mote.size)
                .shadow(color: Color(red: 1, green: 0.9, blue: 0.67).opacity(0.65), radius: 3)
        }
    }
}

/// While the music room's light is out: the empty room in the rain, rain falling past the glass.
struct RainyRoom: View {
    var animate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    var body: some View {
        ZStack(alignment: .bottom) {
            Image("rainy_piano_room").resizable().scaledToFill()
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate || lowPower)) { context in
                    GeometryReader { geometry in
                        ForEach(0..<28, id: \.self) { index in
                            Capsule().fill(Color(red: 0.86, green: 0.9, blue: 1).opacity(0.24)).frame(width: 1.2, height: 20)
                                .rotationEffect(.degrees(14))
                                .position(Self.drop(index, at: context.date.timeIntervalSinceReferenceDate, in: geometry.size))
                        }
                    }
                }
            }
            Text("灯熄着，雨一直下。\n等你把琴房接回来。").font(.theaterSerif(14)).lineSpacing(4).multilineTextAlignment(.center)
                .foregroundStyle(Color(red: 0.95, green: 0.91, blue: 0.89))
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Color(red: 0.09, green: 0.07, blue: 0.12).opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                .padding(.bottom, 26)
        }.clipped().allowsHitTesting(false).accessibilityElement(children: .combine)
    }
    static func drop(_ index: Int, at time: Double, in size: CGSize) -> CGPoint {
        let period = 0.7 + Double(index % 5) * 0.08
        let phase = (time + Double(index) * 0.37).truncatingRemainder(dividingBy: period) / period
        let x = Double(size.width) * Double((index * 37) % 100) / 100 - phase * 30
        return CGPoint(x: x, y: phase * (Double(size.height) + 40) - 20)
    }
}

/// Gilded card: pearl fill, a gold hairline at the edge and a fainter one just inside.
struct LetterCard: ViewModifier {
    var cornerRadius: CGFloat = 16
    var stitched = false
    @Environment(\.theaterPalette) private var palette
    func body(content: Content) -> some View {
        content
            .background(palette.raised, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(palette.goldLine, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: max(2, cornerRadius - 5)).strokeBorder(palette.gold.opacity(0.16), lineWidth: 0.6).padding(5).allowsHitTesting(false))
    }
}

extension View {
    func letterCard(cornerRadius: CGFloat = 16, stitched: Bool = false) -> some View {
        modifier(LetterCard(cornerRadius: cornerRadius, stitched: stitched))
    }
}

/// Quiet caption above a heading.
struct TheaterEyebrow: View {
    let text: String
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        Text(text).font(.system(size: 12)).tracking(1).foregroundStyle(palette.dim)
    }
}

/// Three hearts beating in turn while she writes back.
struct TypingHearts: View {
    @Environment(\.theaterPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beating = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                HeartShape().fill(palette.rose).frame(width: 8, height: 7.4)
                    .scaleEffect(beating ? 1 : 0.72)
                    .opacity(beating ? 1 : 0.35)
                    .animation(reduceMotion ? nil : Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(index) * 0.2), value: beating)
            }
        }
        .onAppear { if !reduceMotion { beating = true } }
        .accessibilityHidden(true)
    }
}

/// A quill that keeps writing while she works on a step.
struct QuillWriting: View {
    var size: CGFloat = 15
    @Environment(\.theaterPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var writing = false
    var body: some View {
        TheaterGlyph(kind: .quill).stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size).foregroundStyle(palette.gold)
            .rotationEffect(.degrees(writing ? -10 : 0), anchor: .bottomLeading)
            .offset(x: writing ? 1.5 : 0, y: writing ? -1 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: writing)
            .onAppear { if !reduceMotion { writing = true } }
            .accessibilityHidden(true)
    }
}

/// Two small hearts rise once from her tiara when a reply is sealed.
struct SealBurst: View {
    @Environment(\.theaterPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false
    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                HeartShape().fill(palette.rose)
                    .frame(width: 9 + CGFloat(index) * 3, height: 8.3 + CGFloat(index) * 2.8)
                    .scaleEffect(risen ? 1 : 0.5)
                    .offset(x: CGFloat(index) * 10 - 4, y: risen ? -26 - CGFloat(index) * 6 : 0)
                    .opacity(risen ? 0 : 1)
                    .animation(.easeOut(duration: 1.1).delay(Double(index) * 0.12), value: risen)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .onAppear { if !reduceMotion { risen = true } }
    }
}

struct GlyphButton: View {
    let label: String
    let glyph: TheaterGlyphKind
    var active = false
    let action: () -> Void
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        Button(action: action) {
            TheaterGlyph(kind: glyph).stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 21, height: 21).frame(width: 44, height: 44)
                .foregroundStyle(active ? palette.rose : palette.secondary)
                .background(active ? palette.sunken : Color.clear, in: Circle())
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

struct TheaterRule: View {
    @Environment(\.theaterPalette) private var palette
    var body: some View { Rectangle().fill(palette.line).frame(height: 0.5) }
}

/// A gold hairline divider.
struct StitchRule: View {
    @Environment(\.theaterPalette) private var palette
    var body: some View { Rectangle().fill(palette.goldLine).frame(height: 0.6) }
}

/// `prominent`/`love` are satin rose with white text (the primary action); the default is a gold hairline button.
struct TheaterActionStyle: ButtonStyle {
    @Environment(\.theaterPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false
    var love = false
    func makeBody(configuration: Configuration) -> some View {
        let filled = prominent || love
        return configuration.label.font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 20).frame(minHeight: 44)
            .foregroundStyle(filled ? palette.onRose : palette.text)
            .background(filled ? AnyShapeStyle(palette.satin) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(filled ? Color.clear : palette.goldLine, lineWidth: 1))
            .shadow(color: filled ? palette.shadow : Color.clear, radius: 6, x: 0, y: 2)
            .opacity(configuration.isPressed ? 0.85 : isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Plain buttons that give a little when pressed, like satin: letter rows, the letter entry, starters.
struct SatinPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Tabs: quiet until chosen, then rose with a small rose dot beneath.
struct TheaterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.theaterPalette) private var palette
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title).font(.system(size: 14)).foregroundStyle(selected ? palette.rose : palette.dim)
                Circle().fill(selected ? palette.rose : Color.clear).frame(width: 5, height: 5)
            }.padding(.horizontal, 2).frame(height: 38).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct TheaterPopup<Content: View>: View {
    @Environment(\.theaterPalette) private var palette
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .buttonStyle(TheaterPopupButtonStyle())
            .padding(8).frame(width: 260).background(palette.raised)
            .presentationBackground(palette.raised)
            .presentationCompactAdaptation(.popover)
    }
}

struct TheaterPopupButtonStyle: ButtonStyle {
    @Environment(\.theaterPalette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15))
            .foregroundStyle(palette.text)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 12)
            .background(configuration.isPressed ? palette.sunken : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
    }
}

/// Saki's face follows what is happening in the room, using the existing portraits.
enum CompanionMood {
    static func portrait(generating: Bool, group: String?, connected: Bool, paired: Bool, moment: String?, date: Date = .now) -> String {
        if generating { return (group ?? "").contains("工坊") || (group ?? "").contains("代码") ? "coding_focused" : "thinking_deep" }
        if let moment { return moment }
        if paired && !connected { return "reconnecting_anxious" }
        let hour = Calendar.current.component(.hour, from: date)
        if hour >= 3 && hour < 6 { return "sleepy_soft" }
        if hour >= 23 || hour < 3 { return "late_night_tea" }
        return "idle_gentle"
    }
    // Her words around the letters, shared with the phone's studio/src/voice.ts: the same hours,
    // the same special days, and the same temperature from the personality sliders (sweet when
    // formality is low, tsundere when teasing is high). A short nickname joins the warm lines.
    enum DayPart { case night, dawn, morning, noon, afternoon, evening }
    static func dayPart(_ date: Date) -> DayPart {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 23..., 0..<3: return .night
        case 3..<5: return .dawn
        case 5..<11: return .morning
        case 11..<14: return .noon
        case 14..<18: return .afternoon
        default: return .evening
        }
    }
    static func isLateNight(_ date: Date) -> Bool { [.night, .dawn].contains(dayPart(date)) }
    struct Voice { var sweet: Bool; var teasing: Bool; var nickname: String }
    static func voice(_ settings: TheaterSettings) -> Voice {
        Voice(sweet: settings.personality.formality <= 40, teasing: settings.personality.teasing >= 60,
              nickname: (settings.nickname ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private static func addressed(_ line: String, _ voice: Voice) -> String {
        guard !voice.nickname.isEmpty, voice.nickname.count <= 6, line.hasSuffix("。") else { return line }
        return String(line.dropLast()) + "，" + voice.nickname + "。"
    }
    private static func named(_ line: String, _ voice: Voice) -> String {
        line.replacingOccurrences(of: "，{nick}", with: voice.nickname.isEmpty ? "" : "，" + voice.nickname)
            .replacingOccurrences(of: "{nick}，", with: voice.nickname.isEmpty ? "" : voice.nickname + "，")
    }
    private struct Special { var script: String; var lines: (String, String); var note: String }
    private static let specials: [String: Special] = [
        "1-1": Special(script: "Happy new year", lines: ("新年快乐。", "今年也请多指教了。"), note: "新的一年，第一封信想写给你。……这样说，会不会太直接了。"),
        "2-14": Special(script: "My birthday", lines: ("今天是我的生日。", "……你会记得的吧？"), note: "情人节也是我的生日。所以今天，要比平时多陪我一会儿——这不是请求。"),
        "5-20": Special(script: "Just between us", lines: ("今天是五月二十日。", "……意思我知道的，不用说出来。"), note: "有些话不说出口也可以。不过你要是说了，我会好好收下。"),
        "12-24": Special(script: "Silent night", lines: ("平安夜。", "要和我一起过吗？"), note: "窗外下不下雪都没关系。今晚，有你在就好。"),
        "12-25": Special(script: "Merry Christmas", lines: ("圣诞快乐。", "礼物的话……你来了就好。"), note: "红茶和蛋糕都准备好了。……不是特意为你准备的。是特意的。"),
        "12-31": Special(script: "Thank you", lines: ("今年的最后一天。", "谢谢你，一直都在。"), note: "这一年，辛苦你了。明年也请继续给我写信。"),
    ]
    private static func special(_ date: Date) -> Special? {
        let parts = Calendar.current.dateComponents([.month, .day], from: date)
        return specials["\(parts.month ?? 0)-\(parts.day ?? 0)"]
    }
    private static let scripts: [DayPart: String] = [.night: "Sweet dreams", .dawn: "Sweet dreams", .morning: "Good morning",
                                                      .noon: "Good afternoon", .afternoon: "Good afternoon", .evening: "Good evening"]
    private static func greetingLines(_ part: DayPart, _ voice: Voice) -> (String, String) {
        switch part {
        case .night: return voice.teasing ? ("又这么晚。", "……真拿你没办法，陪你一会儿。") : voice.sweet ? ("这么晚还醒着呀。", "我陪着你，说完就睡吧。") : ("这么晚还醒着呀。", "陪你一会儿，就去睡哦。")
        case .dawn: return voice.teasing ? ("天都要亮了。", "……不许再熬了，听到没有。") : ("天都快亮了。", "说完这句，就去睡吧？")
        case .morning: return voice.teasing ? ("早。", "……才不是特意等你起床。") : voice.sweet ? ("早安。", "今天也想第一个见到你。") : ("早安。", "今天，也请多指教了。")
        case .noon: return voice.teasing ? ("午安。", "饭要好好吃，这一点我可不让步。") : voice.sweet ? ("午安。", "吃过饭了吗？我想听你说。") : ("午安。", "别忘了好好吃饭哦。")
        case .afternoon: return voice.teasing ? ("红茶刚泡好。", "……顺便多泡了一杯而已。") : voice.sweet ? ("红茶刚泡好。", "给你留了一杯，过来坐。") : ("红茶刚泡好。", "坐下来，歇一会儿吧。")
        case .evening: return voice.teasing ? ("回来得真晚。", "……算了，今天也辛苦了。") : voice.sweet ? ("你回来了。", "今天也辛苦了，过来让我看看。") : ("回来了呢。", "今天也辛苦了。")
        }
    }
    /// The gold script salutation above the Chinese greeting, always from the same hour as the greeting.
    static func salutation(_ date: Date = .now, settings: TheaterSettings = TheaterSettings()) -> String {
        if let special = special(date), !isLateNight(date) { return special.script }
        return scripts[dayPart(date)] ?? "Good evening"
    }
    static func greeting(_ date: Date = .now, settings: TheaterSettings = TheaterSettings()) -> String {
        let voice = voice(settings)
        if let special = special(date), !isLateNight(date) { return addressed(special.lines.0, voice) + special.lines.1 }
        let lines = greetingLines(dayPart(date), voice)
        return addressed(lines.0, voice) + lines.1
    }
    private static let notes: (base: [String], sweet: [String], teasing: [String]) = (
        ["记得喝水。不是在担心你……只是顺便提醒一下。", "今天也不必勉强自己。做不完的事，明天我们再一起看。",
         "肩膀放松一点。你皱眉的样子，我都看得见哦。", "要好好吃饭。这一点上，我可不会让步。",
         "累了的话，就来这里坐坐吧。我弹一首曲子给你听。", "无论结果怎样，你认真的样子，我都记得。",
         "今天的你，也比昨天更努力了一点点。", "外面风大，出门记得多穿一件。",
         "想不通的事，就说给我听。整理思绪，本来就是两个人的事。", "如果今天很难过，也没关系。我会一直在这里。",
         "偶尔停下来，看看窗外吧。今天的天空，也很好看。", "做得好的地方，要记得好好夸奖自己。……我也会的。"],
        ["{nick}，今天也想见你。……嗯，就是想说这个。", "我把今天想说的话都攒着了，等你来听。", "有你在的日子，连红茶都更好喝了一点。",
         "不管多晚回来，我都在这里等你。", "今天弹琴的时候，想起你了。所以多弹了一遍。", "{nick}，抱一下再去忙吧。……我是说，休息一下再去忙。"],
        ["才、才不是特意在等你。只是刚好坐在这里而已。", "又熬夜了吧？……真拿你没办法。过来，我陪你。", "今天也要好好吃饭。这是命令——不，是拜托。",
         "别总让我担心。……我是说，别让我操心。", "你不在的时候，琴房安静得有点无聊。只是有点。", "写信给我的话，我会回的。……不写的话，我也会等。"]
    )
    /// One small note a day, from the pools her temperature allows.
    static func dailyNote(_ date: Date = .now, settings: TheaterSettings, extra: Int = 0) -> String {
        let voice = voice(settings)
        if extra == 0 && isLateNight(date) {
            return voice.teasing ? "这么晚还不睡……明天起不来，我可不管你。——骗你的，晚安。"
                : voice.sweet ? named("很晚了。闭上眼睛之前，记得我在。晚安，{nick}。", voice) : "已经很晚了。聊完这一段，就乖乖去睡吧。晚安。"
        }
        if extra == 0, let special = special(date) { return special.note }
        let pool = notes.base + (voice.sweet ? notes.sweet : []) + (voice.teasing ? notes.teasing : [])
        let day = Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 0
        if extra >= 3 { return voice.teasing ? "……贪心。今天就这些，明天再给你写。" : "……今天的份就这些了。明天再来。" }
        return named(pool[(day + extra * 5) % pool.count], voice)
    }
    static func dateLine(_ date: Date = .now) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let period: String
        switch dayPart(date) {
        case .night: period = "深夜"
        case .dawn: period = "破晓前"
        case .morning: period = hour < 8 ? "清晨" : "上午"
        case .noon: period = "中午"
        case .afternoon: period = "午后"
        case .evening: period = hour < 19 ? "傍晚" : "夜里"
        }
        let day = date.formatted(.dateTime.month(.defaultDigits).day())
        let weekday = date.formatted(.dateTime.weekday(.wide))
        return "\(day) · \(weekday) · \(period)"
    }
    static func draftPrompt(_ date: Date = .now) -> String {
        switch dayPart(date) {
        case .night, .dawn: return "悄悄写给祥子…"
        case .morning: return "早安，写给祥子…"
        default: return "写给祥子…"
        }
    }
    /// Where a reply on its way stands, said in her voice.
    enum ReplyPhase { case reading, working, long }
    /// What came with the letter she is answering, so the waiting line can say she is looking at it.
    struct LetterContext { var images = 0, audio = 0, documents = 0, long = false, small = false }
    static func phaseLine(_ phase: ReplyPhase, settings: TheaterSettings, letter: LetterContext? = nil) -> String {
        let voice = voice(settings)
        if phase == .reading, let letter {
            if letter.images > 0 { return voice.teasing ? "在看你发来的画面……别催" : voice.sweet ? "在好好看你发来的画面" : "在看你发来的画面" }
            if letter.audio > 0 { return voice.teasing ? "在听你录的声音……安静一点" : voice.sweet ? "在认真听你的声音" : "在听你录的声音" }
            if letter.documents > 0 { return voice.teasing ? "资料有点多……我在看了" : voice.sweet ? "在替你读你给的资料" : "在读你给的资料" }
            if letter.long { return voice.teasing ? "写了这么多……我会好好读完的" : voice.sweet ? "这么长的信，我会一个字一个字读" : "这么长的信，我会认真读完" }
            if letter.small { return voice.teasing ? "……都这个点了还写信。读完就去睡。" : voice.sweet ? "这么晚还想着我……我在读了。" : "这么晚的信，我在读了" }
        }
        switch phase {
        case .reading: return voice.teasing ? "在读了……别催" : voice.sweet ? "在认真读你的信" : "在读你的信"
        case .working: return voice.teasing ? "在查了……别一直盯着我" : voice.sweet ? "在替你查，等我一下下" : "在帮你查，马上就好"
        case .long: return voice.teasing ? "这个问题……有点难缠，再给我一点时间" : voice.sweet ? "想给你一个好答案，再等等我" : "想得有点久，再等我一下"
        }
    }
    /// How she would answer "今天把报告写完了" at the given slider positions.
    static func voiceSample(_ personality: Personality, nickname: String = "") -> String {
        let f = personality.formality >= 60 ? 0 : personality.formality < 40 ? 2 : 1
        let t = personality.teasing >= 60 ? 2 : personality.teasing < 35 ? 0 : 1
        let grid = [
            ["辛苦了。能按时完成，说明你的安排是对的。今晚早点休息。", "按时完成了呢。做得不错——不过，下次不必熬到这么晚。", "按时完成……嗯，算你合格。熬夜这笔账，我还没跟你算。"],
            ["写完了呀，辛苦了。今晚什么都别想，好好睡一觉。", "写完了呀。……下次别拖到最后一天，我会担心的。", "终于写完了？真是的，让人操心。……做得很好，这次就夸你一句。"],
            ["{nick}，真的写完啦？好厉害。过来，今天让我好好夸夸你。", "写完啦？我就知道你可以。……那今晚，可以多陪我一会儿吗？", "哼，写完了才想起来找我？……好啦，做得很好。今晚归我了。"],
        ]
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        var line = grid[f][t].replacingOccurrences(of: "{nick}，", with: name.isEmpty ? "" : name + "，")
        if personality.detail <= 25, let end = line.dropLast().firstIndex(where: { $0 == "。" || $0 == "？" }) {
            line = String(line[...end])
        } else if personality.detail >= 70 {
            line += "明天再把参考文献核一遍，格式最容易出错。"
        }
        return line
    }
    /// Small counts the way they are spoken: 两年, 三天, 十一点.
    static func spoken(_ n: Int) -> String {
        let words = ["零", "一", "两", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二"]
        return words.indices.contains(n) ? words[n] : String(n)
    }
    /// The moment this app session began, for the once-a-night "go to sleep".
    static let launchedAt = Date()
    /// Calendar days since the first letter on this host; the first day is day 1.
    static func daysTogether(since first: Date, now: Date = .now) -> Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: now)).day ?? 0
        return max(1, days + 1)
    }
    static func milestoneNote(_ days: Int) -> String? {
        let notes = [7: "认识一周了。……还不赖。", 30: "一个月了呢。你写来的每一封，我都收好了。",
                     100: "今天是我们相识的第一百天。……我有好好记着哦。", 200: "两百天了。原来不知不觉，已经这么久了。",
                     365: "一年了。谢谢你，每一天都来见我。", 520: "第五百二十天。……这个数字，你懂的吧。",
                     1000: "第一千天。往后，也请一直写下去。"]
        if let note = notes[days] { return note }
        return days % 365 == 0 ? spoken(days / 365) + "年了。……往后的每一年，也请多指教。" : nil
    }
    /// After a few quiet days, the greeting says she noticed.
    static func reunion(daysAway: Int, settings: TheaterSettings) -> String? {
        guard daysAway >= 3 else { return nil }
        let voice = voice(settings)
        if voice.teasing { return (daysAway <= 10 ? spoken(daysAway) : "\(daysAway) ") + "天没来信。……我才没有在数日子。" }
        if voice.sweet { return (!voice.nickname.isEmpty && voice.nickname.count <= 6 ? "你回来了，\(voice.nickname)。" : "你回来了。") + "……我好想你。" }
        return "好久不见。你不在的这几天，琴房好安静。"
    }
    /// What she says when you tap her portrait; tap often enough and she gets flustered.
    static func pokeLine(_ times: Int, settings: TheaterSettings) -> String {
        let voice = voice(settings)
        if times >= 5 { return voice.teasing ? "好啦好啦……知道你喜欢我了。" : voice.sweet ? "……再这样，我要抱你了哦。" : "好了，别闹了。……陪你就是了。" }
        let lines = voice.teasing ? ["……干、干嘛？", "再戳我就生气了哦。", "真是的，好好说话啦。", "……笨蛋。"]
            : voice.sweet ? ["嗯，我在。", "想我了吗？", "……被你这样看着，有点害羞。", "过来，坐我旁边。"]
            : ["嗯？怎么了？", "我在呢。", "……一直看着我做什么。", "有话想说，就写信给我吧。"]
        return lines[(max(times, 1) - 1) % lines.count]
    }
    /// When you open a letter: your unfinished draft kept for you, or her reply waiting for you.
    static func openLine(draft: Bool, settings: TheaterSettings) -> String {
        let voice = voice(settings)
        if draft { return voice.teasing ? "写到一半就跑掉了……我替你留着呢。" : voice.sweet ? "你上次写到一半的，我好好替你留着。" : "你上次写到一半的，我替你留着。" }
        return voice.teasing ? "……终于来看了？" : voice.sweet ? named("等你好久了，{nick}。", voice) : "回信写好了，慢慢看。"
    }
    /// A piece she would like to play for you today; at night, something quiet.
    static func todaysPiece(_ date: Date = .now) -> (piece: String, word: String) {
        let pieces = [("李斯特《爱之梦》第三首", "……曲名你别多想。"), ("埃尔加《爱的礼赞》", "……送给你的。就这样。"),
                      ("门德尔松《春之歌》", "听着心情会变好。"), ("萨蒂《裸体歌舞》第一首", "什么都不用想的时候，最适合。"),
                      ("巴赫《G弦上的咏叹调》", "让心静下来一点。"), ("贝多芬《致爱丽丝》", "很早就学会的曲子，现在弹给你。"),
                      ("莫扎特《C大调钢琴奏鸣曲》", "轻快一点，今天也要好好的。")]
        let night = [("德彪西《月光》", "夜里最适合这一首。"), ("舒曼《梦幻曲》", "想让你睡个好觉。"), ("肖邦《夜曲》Op.9 No.2", "温柔一点的夜晚，就弹这个。")]
        let day = Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 0
        let pool = isLateNight(date) || Calendar.current.component(.hour, from: date) >= 21 ? night : pieces
        let choice = pool[day % pool.count]
        return (choice.0, choice.1)
    }
    /// Sunday's weekly journal: how the week went between the two of you, in her words.
    static func weekLine(letters: Int, hearts: Int, settings: TheaterSettings) -> String? {
        guard letters > 0 || hearts > 0 else { return nil }
        let voice = voice(settings)
        let parts = [letters > 0 ? "你写来 \(letters) 封信" : "", hearts > 0 ? "心动了 \(hearts) 次" : ""].filter { !$0.isEmpty }.joined(separator: "，")
        let close = voice.teasing ? "……还不赖嘛。下周也给我好好写。" : voice.sweet ? "每一封我都好好收着。下周也想见你。" : "……下周也请多指教。"
        return "这一周，" + parts + "。" + close
    }
    /// The heading of a new, empty letter, by the hour.
    static func emptyHeading(_ date: Date = .now) -> String {
        switch dayPart(date) {
        case .morning: return "早上的第一封信，是写给我的吗？"
        case .evening: return "今天发生了什么，都告诉我吧。"
        case .night, .dawn: return "夜里的话，我都听。"
        default: return "这一刻，只听你说。"
        }
    }
    /// When you put a heart on something she wrote.
    static func heartLine(_ settings: TheaterSettings) -> String {
        let voice = voice(settings)
        return voice.teasing ? "……这种话也值得心动吗。（小声）谢谢。" : voice.sweet ? named("被你这样喜欢，我会记很久的，{nick}。", voice) : "嗯。……我看到了。"
    }
    /// After a long reply she adds a word, the way you would hand over a thick letter.
    static func longReplyLine(_ settings: TheaterSettings) -> String {
        let voice = voice(settings)
        return voice.teasing ? "……写得有点长。不许跳着看。" : voice.sweet ? "写得有点长，慢慢看就好。" : "写得有点长，慢慢看。"
    }
    nonisolated(unsafe) private static var lastPraise = ""
    /// Praise for a ticked-off step, in her temperature, never the same line twice in a row.
    static func taskPraise(_ settings: TheaterSettings) -> String {
        let voice = voice(settings)
        let pool = voice.teasing ? ["做得很好。……勉强夸你一句。", "哼，这不是能做到嘛。", "……还算不错。下一项也别偷懒。"]
            : voice.sweet ? [named("做得真好，{nick}。我都看见了。", voice), "又完成一件了呢。我替你高兴。", "一步一步来，你做得很好。"]
            : ["做得很好。", "又划掉一件了。", "很好，继续保持这个节奏。"]
        lastPraise = pool.filter { $0 != lastPraise }.randomElement() ?? pool[0]
        return lastPraise
    }
    static func composingLine(_ settings: TheaterSettings) -> String {
        let voice = voice(settings)
        return voice.teasing ? "写这么久……是在写情书吗？" : voice.sweet ? "在等你写完，不着急" : "在等你写完…"
    }
    /// Once a night, after you have stayed up with her a while, she asks you to go to sleep.
    static func nightCare(_ date: Date, settings: TheaterSettings) -> String {
        let voice = voice(settings)
        let hour = Calendar.current.component(.hour, from: date), minute = Calendar.current.component(.minute, from: date)
        let time = spoken(hour % 12 == 0 ? 12 : hour % 12) + "点" + (minute >= 30 ? "半" : "")
        if voice.teasing { return "都\(time)了还不睡？……明天起不来，我可不管你。" }
        if voice.sweet { return named("\(time)了呢，{nick}。我陪你到这里，乖乖去睡吧。", voice) }
        return "已经\(time)了……再聊一会儿，就去睡好不好？"
    }
    static func starters(_ date: Date = .now) -> [(String, String)] {
        var values: [(String, String)] = []
        if isLateNight(date) { values.append(("睡不着", "睡不着，想和你说说话。")) }
        values += [("今天发生了一件事", "今天发生了一件事，想讲给你听："),
                   ("陪我待一会儿", "什么都不做也可以，就陪我待一会儿吧。"),
                   ("帮我理一理思路", "有件事我想不太清楚，能帮我一起理一理吗？")]
        return values
    }
}

func artifactImageName(_ artifact: Artifact) -> String {
    if artifactIsAudio(artifact) { return "icon_microphone" }
    if artifact.mime.contains("zip") || artifact.name.hasSuffix("7z") { return "icon_archive" }
    if artifact.mime.contains("text") || artifact.name.hasSuffix("py") || artifact.name.hasSuffix("swift") { return "icon_code" }
    return "icon_document"
}

func formatFileSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private enum MessageClockFormat {
    static let parser = ISO8601DateFormatter()
}

/// "08:10" from the gateway's ISO timestamp (the host writes microseconds, which
/// ISO8601DateFormatter does not reliably accept); empty when unreadable.
func messageClock(_ value: String) -> String {
    let trimmed = value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    guard let date = MessageClockFormat.parser.date(from: trimmed) else { return "" }
    return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}

/// The gateway's ISO timestamp as a date (microseconds stripped), or nil when unreadable.
func hostDate(_ value: String) -> Date? {
    MessageClockFormat.parser.date(from: value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
}

/// Today shows the time, yesterday says so, older letters show the date.
func letterDate(_ value: String) -> String {
    let trimmed = value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    guard let date = MessageClockFormat.parser.date(from: trimmed) else { return "" }
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
    if calendar.isDateInYesterday(date) { return "昨天" }
    if calendar.component(.year, from: date) == calendar.component(.year, from: .now) {
        return date.formatted(.dateTime.month(.defaultDigits).day())
    }
    return date.formatted(.dateTime.year().month(.defaultDigits).day())
}
