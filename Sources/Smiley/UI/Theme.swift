import AppKit
import SwiftUI

/// Smiley's look: warm paper surfaces, soft charcoal ink and a dusty rose accent borrowed from the character's
/// felt. Rounded type, rounded corners, nothing loud.
enum Theme {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    static let accent = dynamic(light: rgb(190, 78, 100), dark: rgb(232, 138, 154))     // dusty rose
    /// The accent as a background for white text; the same in light and dark.
    static let accentFill = Color(nsColor: rgb(190, 78, 100))
    static let accentSoft = dynamic(light: rgb(251, 236, 238), dark: rgb(62, 38, 43))
    static let ink = dynamic(light: rgb(58, 48, 51), dark: rgb(244, 236, 236))           // warm charcoal
    static let muted = dynamic(light: rgb(140, 127, 130), dark: rgb(170, 156, 159))
    static let hairline = dynamic(light: rgb(238, 228, 226), dark: rgb(54, 46, 48))
    static let paper = dynamic(light: rgb(255, 252, 251), dark: rgb(28, 24, 25))
    static let wash = dynamic(light: rgb(250, 245, 243), dark: rgb(35, 30, 31))
    static let hover = dynamic(light: rgb(246, 238, 236), dark: rgb(46, 39, 41))
    /// Status colours: fine, needs attention, went wrong, neutral information.
    static let good = Color(nsColor: rgb(92, 160, 124))
    static let warn = Color(nsColor: rgb(206, 142, 66))
    static let bad = Color(nsColor: rgb(208, 86, 80))
    static let calm = Color(nsColor: rgb(84, 122, 176))
    /// The dark surface of the bottom popup and the pet's input bar.
    static let popup = Color(nsColor: rgb(40, 33, 35))

    static func title(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .rounded) }
    static func label(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .medium, design: .rounded).monospacedDigit() }
}

/// "● Label": a small section label.
struct SectionLabel: View {
    let text: String
    var color: Color = Theme.muted
    init(_ text: String, color: Color = Theme.muted) { self.text = text; self.color = color }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color.opacity(0.7)).frame(width: 6, height: 6)
            Text(text).font(Theme.label(12)).foregroundStyle(color)
        }
    }
}

/// Page title with its lead word in the accent colour, e.g. "*Your* week."
struct PageTitle: View {
    let accent: String
    let rest: String
    var size: CGFloat = 28
    var body: some View {
        (Text(accent).foregroundColor(Theme.accent) + Text(rest.isEmpty ? "" : " " + rest).foregroundColor(Theme.ink))
            .font(Theme.title(size))
    }
}

/// A soft rounded card.
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

struct PillButtonStyle: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .foregroundStyle(filled ? Color.white : Theme.ink)
            .background(Capsule().fill(filled ? Theme.accentFill : Color.clear))
            .overlay(Capsule().strokeBorder(filled ? Color.clear : Theme.accent.opacity(0.5), lineWidth: 1))
            .contentShape(Capsule())   // the whole pill is clickable, not just the label
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillOutline: PillButtonStyle { PillButtonStyle(filled: false) }
}

/// GroupBox as a soft card: a small label above a rounded box.
struct SoftGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }
}

extension GroupBoxStyle where Self == SoftGroupBoxStyle {
    static var soft: SoftGroupBoxStyle { SoftGroupBoxStyle() }
}
