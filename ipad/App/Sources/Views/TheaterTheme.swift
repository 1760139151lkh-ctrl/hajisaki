import SwiftUI
import UIKit

struct TheaterPalette {
    let isDark: Bool
    static func p3(_ hex: UInt32) -> Color {
        Color(uiColor: UIColor(displayP3Red: CGFloat((hex >> 16) & 255) / 255,
                               green: CGFloat((hex >> 8) & 255) / 255,
                               blue: CGFloat(hex & 255) / 255, alpha: 1))
    }
    var background: Color { Self.p3(isDark ? 0x080D1B : 0xF6F7FA) }
    var raised: Color { Self.p3(isDark ? 0x0E162B : 0xFFFFFF) }
    var sidebar: Color { Self.p3(isDark ? 0x101A2D : 0xEAEFF8) }
    var text: Color { Self.p3(isDark ? 0xECF0FA : 0x1A233A) }
    var secondary: Color { Self.p3(isDark ? 0xAAB7CF : 0x596880) }
    var blue: Color { Self.p3(isDark ? 0xB8D2FC : 0x345E96) }
    var gold: Color { Self.p3(isDark ? 0xD6B269 : 0x8A672C) }
    var warning: Color { Self.p3(isDark ? 0xF09CB0 : 0xA73450) }
    var line: Color { gold.opacity(isDark ? 0.23 : 0.22) }
    var selection: Color { blue.opacity(isDark ? 0.12 : 0.09) }
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

enum TheaterGlyphKind { case plus, close, sidebar, search, send, stop, more, pencil, book, chevron, settings, back, attachment, watch }

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
            path.addRoundedRect(in: box, cornerSize: CGSize(width: 2, height: 2)); line(0.32, 0, 0.32, 1)
        case .search:
            path.addEllipse(in: CGRect(x: box.minX, y: box.minY, width: box.width * 0.7, height: box.height * 0.7)); line(0.63, 0.63, 1, 1)
        case .send: line(0.15, 0.4, 0.5, 0.05); line(0.5, 0.05, 0.85, 0.4); line(0.5, 0.05, 0.5, 0.95)
        case .stop: path.addRoundedRect(in: box.insetBy(dx: 2, dy: 2), cornerSize: CGSize(width: 2, height: 2))
        case .more:
            for x in [CGFloat(0.12), 0.5, 0.88] { path.addEllipse(in: CGRect(x: point(x, 0.5).x - 1, y: point(x, 0.5).y - 1, width: 2, height: 2)) }
        case .pencil:
            path.move(to: point(0.1, 0.9)); path.addLines([point(0.2, 0.59), point(0.76, 0.03), point(0.97, 0.24), point(0.4, 0.8), point(0.1, 0.9)]); line(0.65, 0.14, 0.86, 0.35)
        case .watch:
            path.addEllipse(in: CGRect(x: point(0.07, 0.19).x, y: point(0.07, 0.19).y, width: box.width * 0.86, height: box.height * 0.81))
            path.addEllipse(in: CGRect(x: point(0.27, 0).x, y: point(0.27, 0).y, width: box.width * 0.46, height: box.height * 0.21))
            line(0.5, 0.35, 0.5, 0.61); line(0.5, 0.61, 0.68, 0.72)
        case .book:
            path.move(to: point(0.5, 0.2)); path.addLines([point(0.15, 0.06), point(0, 0.1), point(0, 0.86), point(0.15, 0.82), point(0.5, 0.96), point(0.85, 0.82), point(1, 0.86), point(1, 0.1), point(0.85, 0.06), point(0.5, 0.2), point(0.5, 0.96)])
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
        }
        return path
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
                .frame(width: 23, height: 23).frame(width: 44, height: 44)
                .foregroundStyle(active ? palette.blue : palette.secondary)
                .background(active ? palette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

struct TheaterRule: View {
    @Environment(\.theaterPalette) private var palette
    var body: some View { Rectangle().fill(palette.line).frame(height: 0.5) }
}

struct TheaterActionStyle: ButtonStyle {
    @Environment(\.theaterPalette) private var palette
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 15).frame(minHeight: 40)
            .foregroundStyle(prominent ? palette.background : palette.blue)
            .background(prominent ? palette.blue : palette.selection, in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.7 : 1)
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
            .background(configuration.isPressed ? palette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
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
