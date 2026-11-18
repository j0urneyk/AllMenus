// Renders the All Menus app icon (an .iconset) — run by build.sh when Resources/AppIcon.icns is missing.
import Cocoa

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Body on the macOS icon grid: 824pt squircle with a soft shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.shadowBlurRadius = 24; sh.shadowOffset = NSSize(width: 0, height: -10)
    sh.set()
    NSColor.black.setFill(); squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.43, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.70, green: 0.36, blue: 0.95, alpha: 1)])!
        .draw(in: body, angle: -60)
    // Menu bar strip with a few glyphs.
    NSColor.white.withAlphaComponent(0.2).setFill()
    NSRect(x: 100, y: 836, width: 824, height: 88).fill()
    NSColor.white.withAlphaComponent(0.85).setFill()
    for (i, x) in [170, 222, 274].enumerated() { NSBezierPath(roundedRect: NSRect(x: CGFloat(x), y: 872, width: i == 0 ? 30 : 40, height: 14), xRadius: 7, yRadius: 7).fill() }
    for x in [770, 820, 868] { NSBezierPath(ovalIn: NSRect(x: CGFloat(x), y: 866, width: 26, height: 26)).fill() }
    // The shelf: hangs from the notch, with concave flares at the top.
    let w: CGFloat = 560, h: CGFloat = 420, t: CGFloat = 36, b: CGFloat = 92
    let minX = 512 - w / 2, maxX = 512 + w / 2, top: CGFloat = 924, bot = top - h
    let p = NSBezierPath()
    p.move(to: NSPoint(x: minX, y: top))
    p.curve(to: NSPoint(x: minX + t, y: top - t), controlPoint1: NSPoint(x: minX + t * 0.6, y: top), controlPoint2: NSPoint(x: minX + t, y: top - t * 0.4))
    p.line(to: NSPoint(x: minX + t, y: bot + b))
    p.curve(to: NSPoint(x: minX + t + b, y: bot), controlPoint1: NSPoint(x: minX + t, y: bot + b * 0.45), controlPoint2: NSPoint(x: minX + t + b * 0.45, y: bot))
    p.line(to: NSPoint(x: maxX - t - b, y: bot))
    p.curve(to: NSPoint(x: maxX - t, y: bot + b), controlPoint1: NSPoint(x: maxX - t - b * 0.45, y: bot), controlPoint2: NSPoint(x: maxX - t, y: bot + b * 0.45))
    p.line(to: NSPoint(x: maxX - t, y: top - t))
    p.curve(to: NSPoint(x: maxX, y: top), controlPoint1: NSPoint(x: maxX - t, y: top - t * 0.4), controlPoint2: NSPoint(x: maxX - t * 0.6, y: top))
    p.close()
    NSGraphicsContext.saveGraphicsState()
    let sh2 = NSShadow(); sh2.shadowColor = NSColor.black.withAlphaComponent(0.35); sh2.shadowBlurRadius = 40; sh2.shadowOffset = NSSize(width: 0, height: -18)
    sh2.set()
    NSColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 1).setFill(); p.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Tiles on the shelf: 2 rows x 3, two of them with the orange "hidden" dot.
    let tile: CGFloat = 104, gap: CGFloat = 26
    let gridW = tile * 3 + gap * 2
    for r in 0..<2 { for c in 0..<3 {
        let x = 512 - gridW / 2 + CGFloat(c) * (tile + gap), y = top - 150 - CGFloat(r) * (tile + gap)
        let rect = NSRect(x: x, y: y - tile, width: tile, height: tile)
        NSColor.white.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26).fill()
        NSColor.white.withAlphaComponent(0.92).setFill()
        let g = rect.insetBy(dx: 32, dy: 32)
        switch (r * 3 + c) % 3 {
        case 0: NSBezierPath(ovalIn: g).fill()
        case 1: NSBezierPath(roundedRect: g, xRadius: 10, yRadius: 10).fill()
        default:
            let tri = NSBezierPath(); tri.move(to: NSPoint(x: g.midX, y: g.maxY)); tri.line(to: NSPoint(x: g.maxX, y: g.minY)); tri.line(to: NSPoint(x: g.minX, y: g.minY)); tri.close(); tri.fill()
        }
        if r == 0 && c < 2 {
            NSColor(srgbRed: 1, green: 0.6, blue: 0.1, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 30, y: rect.maxY - 30, width: 20, height: 20)).fill()
        }
    } }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try! render(pt * scale).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
