import AppKit
import SwiftUI

/// Smiley, the app's face: the felt character from Resources/Pet/smiley.png.
/// One source for the app icon and the in-app logo; the menu bar uses its outline (`SmileyGlyph`).
struct SmileyPortrait: View {
    static let image: CGImage? = {
        guard let url = PetSprites.folder?.appendingPathComponent("smiley.png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()

    var body: some View {
        if let image = Self.image {
            Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            SmileyGlyph().fill(Theme.accent, style: FillStyle(eoFill: true)).aspectRatio(18 / 16, contentMode: .fit)
        }
    }
}

/// Smiley as a one-colour silhouette: cushion body with mitten arms and boots, eyes and smile cut out.
/// Fill it with `FillStyle(eoFill: true)` so the face shows through.
struct SmileyGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // Drawn on an 18 × 16 grid.
        let s = min(rect.width / 18, rect.height / 16)
        let t = CGAffineTransform(translationX: rect.midX - 9 * s, y: rect.midY - 8 * s).scaledBy(x: s, y: s)
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 2.5, y: 0.5, width: 13, height: 12), cornerSize: CGSize(width: 3.6, height: 3.6), style: .continuous)
        var limbs = Path()
        limbs.addEllipse(in: CGRect(x: 0, y: 6, width: 4, height: 4.6))        // mittens
        limbs.addEllipse(in: CGRect(x: 14, y: 6, width: 4, height: 4.6))
        limbs.addRoundedRect(in: CGRect(x: 4.6, y: 12, width: 3.9, height: 3.5), cornerSize: CGSize(width: 1.4, height: 1.4))   // boots
        limbs.addRoundedRect(in: CGRect(x: 9.5, y: 12, width: 3.9, height: 3.5), cornerSize: CGSize(width: 1.4, height: 1.4))
        p = p.union(limbs)
        p.addEllipse(in: CGRect(x: 5.3, y: 4.3, width: 2.5, height: 2.9))       // eyes
        p.addEllipse(in: CGRect(x: 10.2, y: 4.3, width: 2.5, height: 2.9))
        var smile = Path()
        smile.move(to: CGPoint(x: 7.4, y: 8.4))
        smile.addQuadCurve(to: CGPoint(x: 10.6, y: 8.4), control: CGPoint(x: 9, y: 10.3))
        p.addPath(smile.strokedPath(StrokeStyle(lineWidth: 1, lineCap: .round)))
        return p.applying(t)
    }
}

/// The app icon: Smiley on a soft white tile.
struct SmileyLogo: View {
    var size: CGFloat
    /// App icons sit inside Apple's icon grid (824/1024) with a drop shadow; the in-app tile fills its frame.
    var iconGrid = false

    var body: some View {
        let tile = iconGrid ? size * 824 / 1024 : size
        ZStack {
            RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(red: 1, green: 0.925, blue: 0.93)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(iconGrid ? 0.25 : 0), radius: size * 0.02, y: size * 0.012)
            RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: max(0.5, tile * 0.004))
            SmileyPortrait()
                .frame(width: tile * 0.74, height: tile * 0.74)
                .offset(y: tile * 0.015)
        }
        .frame(width: tile, height: tile)
        .frame(width: size, height: size)
    }
}

@MainActor
enum LogoRenderer {
    static func png(size: CGFloat, iconGrid: Bool) -> Data? {
        let r = ImageRenderer(content: SmileyLogo(size: size, iconGrid: iconGrid))
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

    /// Monochrome template image of Smiley for the menu bar.
    static func menuBarImage() -> NSImage {
        let r = ImageRenderer(content: SmileyGlyph().fill(Color.black, style: FillStyle(eoFill: true)).frame(width: 18, height: 16).padding(.horizontal, 1).padding(.vertical, 1))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = r.nsImage ?? NSImage(systemSymbolName: "face.smiling.inverse", accessibilityDescription: "Smiley")!
        img.isTemplate = true
        return img
    }
}
