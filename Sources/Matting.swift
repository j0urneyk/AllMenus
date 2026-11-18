import CoreGraphics
import Foundation
import simd

/// Separates a menu bar icon from the menu bar background it was captured on.
///
/// The capture is the status item's window, which is taller than anything drawn in it, so its
/// top and bottom rows are pure background. Per column we interpolate between them, then for every pixel find the smallest alpha that explains it as
/// "some foreground color composited over that background" (difference matting, as in
/// VFX keying). Monochrome glyphs (the usual white/black menu bar icons) are returned as
/// templates so the shelf can recolor them; colored icons keep their colors.
enum Matting {
    struct Result { let image: CGImage; let mono: Bool }

    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func pixels(_ img: CGImage) -> (px: [UInt8], w: Int, h: Int) {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (px, w, h)
    }

    static func image(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        var copy = px
        return copy.withUnsafeMutableBytes { buf -> CGImage? in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    static func matte(_ img: CGImage, edge k: Int = 2) -> Result? {
        let (px, w, h) = pixels(img)
        guard w > 2 * k + 4, h > 4 else { return nil }
        var obs = [SIMD3<Float>](repeating: .zero, count: w * h)   // observed pixel
        var bg = [SIMD3<Float>](repeating: .zero, count: w * h)    // estimated background under it
        var alpha = [Float](repeating: 0, count: w * h)

        // Background per column from the top and bottom rows: glyphs and the menu bar "pill" never
        // reach them (the item window is taller than both), while the wallpaper behind a translucent
        // menu bar mostly varies left to right.
        func px3(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * w + x) * 4
            return SIMD3(Float(px[i]), Float(px[i + 1]), Float(px[i + 2])) / 255
        }
        for x in 0..<w {
            var top = SIMD3<Float>(0, 0, 0), bottom = SIMD3<Float>(0, 0, 0)
            for r in 0..<k { top += px3(x, r); bottom += px3(x, h - 1 - r) }
            top /= Float(k); bottom /= Float(k)
            for y in 0..<h {
                let t = Float(y) / Float(h - 1)
                let b = top * (1 - t) + bottom * t
                let p = px3(x, y)
                var a: Float = 0
                for c in 0..<3 {
                    let d = p[c] - b[c]
                    let room = d > 0 ? 1 - b[c] : b[c]       // how far this channel could move from the background
                    if room > 0.04 { a = max(a, abs(d) / room) }
                }
                // Wallpaper texture and compression leave a little noise; treat it as background.
                a = a < 0.1 ? 0 : min((a - 0.1) / 0.9, 1)
                let j = y * w + x
                alpha[j] = a; obs[j] = p; bg[j] = b
            }
        }

        func color(_ j: Int) -> SIMD3<Float> {
            let a = max(alpha[j], 0.001)
            return simd_clamp(bg[j] + (obs[j] - bg[j]) / a, SIMD3(repeating: 0), SIMD3(repeating: 1))
        }
        // Monochrome or colored? Menu bar glyphs are white/black, but macOS draws them with vibrancy
        // (on inactive displays mostly an additive brighten), so test the *change* from the
        // background: a glyph changes all channels about equally; a colored icon shifts the hue.
        // A monochrome pixel moves the background toward white (d ∝ 1−b), toward black (d ∝ −b),
        // or brightens/darkens it evenly (vibrancy, d ∝ ±1). Anything else carries its own hue.
        var strong = 0, colored = 0
        func cosine(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let n = (a * a).sum().squareRoot() * (b * b).sum().squareRoot()
            return n > 0 ? (a * b).sum() / n : 0
        }
        for j in 0..<alpha.count {
            let d = obs[j] - bg[j]
            let mag = max(abs(d.x), abs(d.y), abs(d.z))
            guard mag > 0.1 else { continue }
            strong += 1
            let b = bg[j]
            let best = max(cosine(d, SIMD3(repeating: 1) - b), cosine(d, -b), abs(cosine(d, SIMD3(repeating: 1))))
            if best < 0.97 { colored += 1 }
        }
        guard strong > 0 else { return nil }
        let mono = Double(colored) / Double(strong) < 0.08

        if mono {
            // Coverage of a gray glyph is proportional to how far it moved the pixel, in any direction.
            for j in 0..<alpha.count {
                let d = obs[j] - bg[j]
                let m = abs(d.x + d.y + d.z) / 3
                alpha[j] = m < 0.03 ? 0 : m
            }
        }
        // macOS 26 draws some items (the clock, Control Center) on a faint "pill". That is a second,
        // uniform background layer: if a big share of the window sits at one low alpha level, peel it off.
        if mono {
            var hist = [Int](repeating: 0, count: 30)
            for a in alpha where a > 0.03 && a < 0.6 { hist[min(Int(a / 0.02), 29)] += 1 }
            if let peak = hist.indices.max(by: { hist[$0] < hist[$1] }) {
                let level = (Float(peak) + 0.5) * 0.02
                let near = alpha.filter { abs($0 - level) < 0.05 }.count
                if Double(near) / Double(alpha.count) > 0.25 {
                    let floor = level + 0.05
                    for j in 0..<alpha.count { alpha[j] = max(0, (alpha[j] - floor) / (1 - floor)) }
                }
            }
        }
        let covered = alpha.filter { $0 > 0 }.sorted()
        guard covered.count >= 4 else { return nil }
        func quantile(_ q: Double) -> Float { covered[min(covered.count - 1, Int(Double(covered.count) * q))] }

        // Normalize alpha so the solid interior is fully opaque. Two effects push it below 1:
        // the menu bar dims icons on inactive displays, and for colored pixels the difference
        // to the background is only a lower bound (pure-ish red over blue never reaches 1).
        // Icons are opaque inside and partly covered only at anti-aliased edges, so scale a high
        // percentile of covered pixels to 1 (colored icons have big flat interiors, so a lower
        // percentile already sits inside them). Color is then re-derived from the new alpha.
        let gain = min(1 / max(quantile(mono ? 0.9 : 0.6), 0.01), 8)
        for j in 0..<alpha.count { alpha[j] = min(alpha[j] * gain, 1) }
        // Anything touching the left or right edge belongs to a neighbor (its pill or glyph spilling
        // into this window), never to this item, which is padded on both sides: flood-fill it away.
        var stack: [Int] = []
        for y in 0..<h { for x in [0, w - 1] where alpha[y * w + x] > 0.05 { stack.append(y * w + x) } }
        while let j = stack.popLast() {
            guard alpha[j] > 0.05 else { continue }
            alpha[j] = 0
            let x = j % w, y = j / w
            if x > 0 { stack.append(j - 1) }
            if x < w - 1 { stack.append(j + 1) }
            if y > 0 { stack.append(j - w) }
            if y < h - 1 { stack.append(j + w) }
        }

        var rgb = [Float](repeating: 0, count: w * h * 3)
        for j in 0..<alpha.count where alpha[j] > 0 {
            let f = color(j)
            rgb[j * 3] = f.x; rgb[j * 3 + 1] = f.y; rgb[j * 3 + 2] = f.z
        }

        // Trim to the glyph, with a small margin.
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where alpha[y * w + x] > 0.15 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { return nil }
        let m = 2
        minX = max(minX - m, 0); minY = max(minY - m, 0); maxX = min(maxX + m, w - 1); maxY = min(maxY + m, h - 1)
        let ow = maxX - minX + 1, oh = maxY - minY + 1
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        for y in 0..<oh { for x in 0..<ow {
            let j = (y + minY) * w + (x + minX), o = (y * ow + x) * 4
            let a = alpha[j]
            let c: SIMD3<Float> = mono ? SIMD3(1, 1, 1) : SIMD3(rgb[j * 3], rgb[j * 3 + 1], rgb[j * 3 + 2])
            out[o] = UInt8((c.x * a * 255).rounded()); out[o + 1] = UInt8((c.y * a * 255).rounded())
            out[o + 2] = UInt8((c.z * a * 255).rounded()); out[o + 3] = UInt8((a * 255).rounded())
        } }
        guard let cg = image(out, ow, oh) else { return nil }
        return Result(image: cg, mono: mono)
    }

    /// Whether a stored (already matted) image is a monochrome template.
    static func isMono(_ img: CGImage) -> Bool {
        let (px, w, h) = pixels(img)
        var solid = 0, colored = 0
        for j in 0..<(w * h) where px[j * 4 + 3] > 128 {
            solid += 1
            let a = Float(px[j * 4 + 3])
            let r = Float(px[j * 4]) / a, g = Float(px[j * 4 + 1]) / a, b = Float(px[j * 4 + 2]) / a
            if max(r, g, b) - min(r, g, b) > 0.25 { colored += 1 }
        }
        return solid == 0 || Double(colored) / Double(solid) < 0.06
    }
}
