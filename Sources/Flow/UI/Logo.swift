import AppKit
import SwiftUI

/// Liquid AI's mark (the drop in a diamond), traced from the official SVG at liquid.ai/logos/liquid-ai-black.svg.
/// One source for the app icon, the in-app logo and the menu bar icon.
struct LiquidMark: Shape {
    /// The mark's three paths, in its native 743.865 × 895.985 coordinate space.
    static let svgPaths = [
        "M386.801 319.037L386.474 319.22L503.32 515.258C518.989 538.504 528.132 566.18 528.132 595.93C528.132 624.104 519.97 650.452 505.782 672.918L743.865 598.585L371.425 0L281.732 144.536L386.801 319.037Z",
        "M186.582 895.985L373.628 744.663C373.473 744.663 373.301 744.663 373.146 744.663C287.552 744.663 218.178 678.078 218.178 595.946C218.178 566.279 227.27 538.669 242.87 515.457L353.396 329.673L261.535 177.106L0 598.601L186.272 895.985H186.582Z",
        "M452.697 723.591C452.697 723.591 452.68 723.591 452.662 723.607L239.977 895.985H555.596L715.557 643.301L452.697 723.607V723.591Z",
    ]
    static let size = CGSize(width: 743.865, height: 895.985)

    private static let unitPath: Path = {
        var p = Path()
        for d in svgPaths { p.addPath(SVGPath.parse(d)) }
        return p
    }()

    func path(in rect: CGRect) -> Path {
        // Fit, preserving aspect ratio, centered.
        let s = min(rect.width / Self.size.width, rect.height / Self.size.height)
        let w = Self.size.width * s, h = Self.size.height * s
        let t = CGAffineTransform(translationX: rect.midX - w / 2, y: rect.midY - h / 2).scaledBy(x: s, y: s)
        return Self.unitPath.applying(t)
    }
}

/// Minimal SVG path-data parser for the absolute commands the mark uses (M L H V C Z).
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var p = Path()
        let chars = Array(d)
        var i = 0
        var current = CGPoint.zero
        var command: Character = "M"

        func skipSeparators() { while i < chars.count, " ,\n\t".contains(chars[i]) { i += 1 } }
        func num() -> CGFloat {
            skipSeparators()
            var s = ""
            while i < chars.count, "-.0123456789eE".contains(chars[i]) {
                // A second "-" starts the next number.
                if chars[i] == "-" && !s.isEmpty && !s.hasSuffix("e") && !s.hasSuffix("E") { break }
                s.append(chars[i]); i += 1
            }
            return CGFloat(Double(s) ?? 0)
        }

        while i < chars.count {
            skipSeparators()
            guard i < chars.count else { break }
            if "MLHVCZ".contains(chars[i]) { command = chars[i]; i += 1 }
            switch command {
            case "M": current = CGPoint(x: num(), y: num()); p.move(to: current); command = "L"
            case "L": current = CGPoint(x: num(), y: num()); p.addLine(to: current)
            case "H": current.x = num(); p.addLine(to: current)
            case "V": current.y = num(); p.addLine(to: current)
            case "C":
                let c1 = CGPoint(x: num(), y: num()), c2 = CGPoint(x: num(), y: num())
                current = CGPoint(x: num(), y: num())
                p.addCurve(to: current, control1: c1, control2: c2)
            case "Z": p.closeSubpath()
            default: i += 1
            }
        }
        return p
    }
}

/// The app icon: Liquid's black mark on a white tile, as on liquid.ai's own app icon.
struct FlowLogo: View {
    var size: CGFloat
    /// App icons sit inside Apple's icon grid (824/1024) with a drop shadow; the in-app tile fills its frame.
    var iconGrid = false

    var body: some View {
        let tile = iconGrid ? size * 824 / 1024 : size
        ZStack {
            RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(iconGrid ? 0.25 : 0), radius: size * 0.02, y: size * 0.012)
            RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: max(0.5, tile * 0.004))
            LiquidMark()
                .fill(Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255))   // zinc-900, Liquid's ink
                .frame(width: tile * 0.5, height: tile * 0.6)
        }
        .frame(width: tile, height: tile)
        .frame(width: size, height: size)
    }
}

@MainActor
enum LogoRenderer {
    static func png(size: CGFloat, iconGrid: Bool) -> Data? {
        let r = ImageRenderer(content: FlowLogo(size: size, iconGrid: iconGrid))
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// Writes a complete .iconset (16–1024 px, @1x and @2x) for `iconutil`.
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = CGFloat(base * scale)
                guard let data = png(size: px, iconGrid: true) else { continue }
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try data.write(to: dir.appendingPathComponent(name))
            }
        }
    }

    /// Monochrome template image of the mark for the menu bar.
    static func menuBarImage() -> NSImage {
        let r = ImageRenderer(content: LiquidMark().fill(Color.black).frame(width: 14, height: 16).padding(.horizontal, 2).padding(.vertical, 1))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = r.nsImage ?? NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Flow")!
        img.isTemplate = true
        return img
    }
}
