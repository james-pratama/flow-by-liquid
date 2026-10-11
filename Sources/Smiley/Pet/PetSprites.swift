import AppKit
import ImageIO

/// Smiley's animations, cut from the sprite atlas in Resources/Pet (spritesheet.png + manifest.json).
struct PetSprites {
    struct Frame {
        /// Cropped to the drawn pixels, so the empty margin of its cell stays click-through.
        let image: CGImage
        /// Where the crop sits in the cell, in points from the top-left.
        let box: CGRect
        var duration: TimeInterval = 0
    }

    enum Clip: String {
        case idle, waving, jumping, failed, waiting, running, review
        case runningRight = "running-right", runningLeft = "running-left"
    }

    /// One cell of the atlas, in points: half its pixel size, so it is pixel-exact on a Retina display.
    static let size = CGSize(width: 96, height: 104)

    private let clips: [String: [Frame]]
    /// 16 still poses looking around the clock: 0 = up, 4 = right, 8 = down, 12 = left.
    let looks: [Frame]

    func frames(_ clip: Clip) -> [Frame] { clips[clip.rawValue] ?? [] }

    /// The pose facing a point `dx` to the right of and `dy` above the pet.
    func look(dx: CGFloat, dy: CGFloat) -> Int {
        let degrees = atan2(dx, dy) * 180 / .pi
        return ((Int((degrees / 22.5).rounded()) % looks.count) + looks.count) % looks.count
    }

    private struct Manifest: Decodable {
        struct Rect: Decodable { let x, y, width, height: Int }
        struct Frame: Decodable { let rect: Rect; let durationMs: Double? }
        struct Frames: Decodable { let frames: [Frame] }
        struct Sheet: Decodable { let file: String }
        let spritesheet: Sheet
        let animations: [String: Frames]
        let lookDirections: Frames
    }

    static func load() -> PetSprites? {
        guard let dir = folder,
              let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              let source = CGImageSourceCreateWithURL(dir.appendingPathComponent(manifest.spritesheet.file) as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // Alpha of every pixel, top row first, to find what is actually drawn in each cell.
        let w = atlas.width, h = atlas.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(atlas, in: CGRect(x: 0, y: 0, width: w, height: h))
        func cut(_ r: Manifest.Rect) -> Frame? {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in max(0, r.y)..<min(h, r.y + r.height) {
                for x in max(0, r.x)..<min(w, r.x + r.width) where pixels[(y * w + x) * 4 + 3] > 8 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, let image = atlas.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return nil }
            let scale = CGFloat(r.width) / size.width
            return Frame(image: image, box: CGRect(x: CGFloat(minX - r.x) / scale, y: CGFloat(minY - r.y) / scale,
                                                   width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        }
        let clips = manifest.animations.mapValues { animation in
            animation.frames.compactMap { f -> Frame? in
                guard var frame = cut(f.rect) else { return nil }
                frame.duration = (f.durationMs ?? 140) / 1000
                return frame
            }
        }
        let looks = manifest.lookDirections.frames.compactMap { cut($0.rect) }
        guard clips[Clip.idle.rawValue]?.isEmpty == false else { return nil }
        return PetSprites(clips: clips, looks: looks)
    }

    /// Smiley's artwork: inside the app bundle, or the repo's Resources/Pet when running a bare `swift build` binary.
    static var folder: URL? {
        let fm = FileManager.default
        func has(_ dir: URL) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Pet"), has(bundled) { return bundled }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            guard let d = dir else { break }
            let candidate = d.appendingPathComponent("Resources/Pet")
            if has(candidate) { return candidate }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }
}
