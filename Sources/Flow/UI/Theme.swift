import AppKit
import SwiftUI

/// Liquid AI's visual language: paper-white surfaces, zinc ink, a single violet accent, serif display type
/// (Iowan Old Style) with italic violet emphasis, uppercase mono labels with square bullets, hairline panels.
enum Theme {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    static let violet = Color(nsColor: rgb(124, 58, 237))                        // #7C3AED
    static let violetSoft = dynamic(light: rgb(237, 233, 254), dark: rgb(46, 16, 101))
    static let ink = dynamic(light: rgb(24, 24, 27), dark: rgb(250, 250, 250))      // zinc-900 / zinc-50
    static let muted = dynamic(light: rgb(113, 113, 122), dark: rgb(161, 161, 170)) // zinc-500 / zinc-400
    static let hairline = dynamic(light: rgb(228, 228, 231), dark: rgb(39, 39, 42)) // zinc-200 / zinc-800
    static let paper = dynamic(light: .white, dark: rgb(9, 9, 11))                  // white / zinc-950
    static let wash = dynamic(light: rgb(250, 250, 250), dark: rgb(24, 24, 27))     // zinc-50 / zinc-900
    static let hover = dynamic(light: rgb(244, 244, 245), dark: rgb(39, 39, 42))    // zinc-100 / zinc-800

    static func serif(_ size: CGFloat) -> Font { .custom("Iowan Old Style", size: size) }
    static func serifItalic(_ size: CGFloat) -> Font { .custom("Iowan Old Style", size: size).italic() }
    static func mono(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
}

/// "■ LABEL" — Liquid's small uppercase mono section label.
struct MonoLabel: View {
    let text: String
    var color: Color = Theme.muted
    init(_ text: String, color: Color = Theme.muted) { self.text = text; self.color = color }
    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(color.opacity(0.6)).frame(width: 6, height: 6)
            Text(text.uppercased()).font(Theme.mono(10.5)).tracking(0.8).foregroundStyle(color)
        }
    }
}

/// Serif page title with an optional italic violet lead word, e.g. "*Your* week".
struct PageTitle: View {
    let accent: String
    let rest: String
    var size: CGFloat = 30
    var body: some View {
        (Text(accent).font(Theme.serifItalic(size)).foregroundColor(Theme.violet)
         + Text(rest.isEmpty ? "" : " " + rest).font(Theme.serif(size)).foregroundColor(Theme.ink))
    }
}

/// Hairline-bordered panel, like the cards on liquid.ai.
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.paper)
            .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

struct PillButtonStyle: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .foregroundStyle(filled ? Color.white : Theme.ink)
            .background(Capsule().fill(filled ? Theme.violet : Color.clear))
            .overlay(Capsule().strokeBorder(filled ? Color.clear : Theme.violet.opacity(0.5), lineWidth: 1))
            .contentShape(Capsule())   // the whole pill is clickable, not just the label
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillOutline: PillButtonStyle { PillButtonStyle(filled: false) }
}

/// GroupBox as a Liquid panel: mono label above a white, hairline-bordered box.
struct LiquidGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.paper)
                .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }
}

extension GroupBoxStyle where Self == LiquidGroupBoxStyle {
    static var liquid: LiquidGroupBoxStyle { LiquidGroupBoxStyle() }
}
