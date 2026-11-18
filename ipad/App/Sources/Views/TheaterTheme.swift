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

enum TheaterGlyphKind { case plus, close, sidebar, search, send, stop, more, pencil, book, chevron, settings, back, attachment, watch, heart, sparkle, lamp, quill, code }

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
            .opacity(configuration.isPressed ? 0.75 : isEnabled ? 1 : 0.45)
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
    /// The gold script salutation above the Chinese greeting.
    static func salutation(_ date: Date = .now) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        if hour >= 23 || hour < 5 { return "Sweet dreams" }
        if hour < 11 { return "Good morning" }
        if hour < 18 { return "Good afternoon" }
        return "Good evening"
    }
    static func greeting(_ date: Date = .now) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 0..<3, 23...: return "这么晚还醒着呀。陪你一会儿，就去睡哦。"
        case 3..<5: return "天都快亮了。说完这句，就去睡吧？"
        case 5..<10: return "早安。今天，也请多指教了。"
        case 10..<14: return "午安。别忘了好好吃饭哦。"
        case 14..<18: return "红茶刚泡好。坐下来，歇一会儿吧。"
        default: return "回来了呢。今天也辛苦了。"
        }
    }
    static func dateLine(_ date: Date = .now) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let period = hour < 5 ? "深夜" : hour < 8 ? "清晨" : hour < 11 ? "上午" : hour < 13 ? "中午" : hour < 17 ? "午后" : hour < 19 ? "傍晚" : hour < 23 ? "夜里" : "深夜"
        let day = date.formatted(.dateTime.month(.defaultDigits).day())
        let weekday = date.formatted(.dateTime.weekday(.wide))
        return "\(day) · \(weekday) · \(period)"
    }
    static func starters(_ date: Date = .now) -> [(String, String)] {
        let hour = Calendar.current.component(.hour, from: date)
        var values: [(String, String)] = []
        if hour >= 23 || hour < 5 { values.append(("睡不着", "睡不着，想和你说说话。")) }
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
