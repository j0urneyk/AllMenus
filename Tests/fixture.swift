// Test fixture for All Menus.
//   fixture overflow N      – N wide text status items with static menus (forces menu bar overflow)
//   fixture icons <outdir>  – status items with known images; writes the exact images (@2x) as ground truth
import Cocoa
let args = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var items: [NSStatusItem] = []

func menu(_ name: String) -> NSMenu {
    let m = NSMenu()
    m.addItem(withTitle: "\(name) – Alpha", action: nil, keyEquivalent: "")
    m.addItem(.separator())
    m.addItem(withTitle: "\(name) – Beta", action: nil, keyEquivalent: "b")
    return m
}

func writePNG(_ img: NSImage, _ path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(img.size.width * 2), pixelsHigh: Int(img.size.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = img.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(origin: .zero, size: img.size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

if args.count > 1 && args[1] == "icons" {
    let out = args.count > 2 ? args[2] : "."
    // 1) Template glyph (how most menu bar icons are made).
    let star = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "FIXTURE-STAR")!
        .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
    star.isTemplate = true
    // 2) Colored icon: red rounded square with a white ring and a yellow dot.
    let color = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
        NSColor(srgbRed: 0.90, green: 0.15, blue: 0.20, alpha: 1).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 5, dy: 5)); ring.lineWidth = 2; ring.stroke()
        NSColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 7.5, y: 7.5, width: 3, height: 3)).fill()
        return true
    }
    color.accessibilityDescription = "FIXTURE-COLOR"
    for (img, name) in [(star, "star"), (color, "color")] {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.image = img
        it.button?.setAccessibilityLabel("FIXTURE-\(name.uppercased())")
        it.menu = menu("Fixture \(name)")
        items.append(it)
        writePNG(img, "\(out)/\(name).png")
    }
} else {
    let n = args.count > 2 ? Int(args[2]) ?? 6 : 6
    for i in 0..<n {
        let it = NSStatusBar.system.statusItem(withLength: 90)
        it.button?.title = "TEST\(i)"
        it.menu = menu("Fixture \(i)")
        items.append(it)
    }
}
app.run()
