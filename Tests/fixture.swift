// Test fixture for All Menus.
//   fixture overflow N      – N wide text status items with static menus (forces menu bar overflow)
//   fixture icons <outdir>  – status items with known images; writes the exact images (@2x) as ground truth
//   fixture clicktypes <log> [type...] – one item per way of handling clicks found in real apps that ignore
//                             Accessibility "press"; every event they get and every open/close goes to <log>.
//                             Types: menu (ordinary, control), monitor, event, view, gesture. See ClickTypes.
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

/// Ways apps handle a click on their status item. Only "menu" reacts to AXPress for certain; each of the others
/// depends on something a press doesn't provide.
enum ClickTypes {
    nonisolated(unsafe) static var keep: [AnyObject] = []
    nonisolated(unsafe) static var logURL = URL(fileURLWithPath: "/dev/null")
    static func log(_ s: String) {
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, s)
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    }

    final class Pop: NSObject {
        let name: String; weak var anchor: NSView?
        let popover = NSPopover()
        init(_ name: String, _ anchor: NSView) {
            self.name = name; self.anchor = anchor
            popover.behavior = .transient; popover.animates = false
            NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: nil) { _ in ClickTypes.log("CLOSED \(name)") }
            let vc = NSViewController(); vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 90))
            let t = NSTextField(labelWithString: name); t.frame = NSRect(x: 20, y: 35, width: 140, height: 20); vc.view.addSubview(t)
            popover.contentViewController = vc
        }
        func toggle() {
            if popover.isShown { popover.close(); ClickTypes.log("CLOSE \(name)"); return }
            guard let a = anchor else { return }
            popover.show(relativeTo: a.bounds, of: a, preferredEdge: .minY)
            ClickTypes.log("OPEN \(name) shown=\(popover.isShown)")
        }
        @objc func act(_ s: Any?) {
            let t = NSApp.currentEvent?.type
            ClickTypes.log("ACTION \(name) currentEvent=\(t.map { "\($0.rawValue)" } ?? "nil")")
            if t == .leftMouseUp || t == .rightMouseUp { toggle() }
        }
        @objc func flip(_ s: Any?) { guard let b = anchor as? NSStatusBarButton else { return }
            b.title = b.title == "OFF" ? "ON " : "OFF"; b.setAccessibilityTitle("switch"); ClickTypes.log("FLIP to \(b.title)") }
        @objc func gesture(_ g: NSGestureRecognizer) { toggle() }
    }
    final class MouseView: NSView {
        var pop: Pop?
        override func draw(_ r: NSRect) { ("VIEW" as NSString).draw(at: NSPoint(x: 2, y: 3), withAttributes: [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.labelColor]) }
        override func mouseDown(with e: NSEvent) { ClickTypes.log("MOUSEDOWN shown=\(pop?.popover.isShown ?? false)"); pop?.toggle() }
    }

    static func start(log path: String, types: [String]) {
        FileManager.default.createFile(atPath: path, contents: nil)
        logURL = URL(fileURLWithPath: path)
        for t in types {
            let it = NSStatusBar.system.statusItem(withLength: 46)
            it.autosaveName = "clicktypes-\(t)"
            items.append(it)
            let b = it.button!
            b.title = t.prefix(4).uppercased()
            b.setAccessibilityLabel("FIXTURE-\(t)")
            switch t {
            case "menu": it.menu = menu("Fixture menu")
            case "monitor":   // opens from a local event monitor on mouse-down in the button's window, unless Command is held
                let p = Pop(t, b); keep.append(p)
                keep.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak b] e in
                    if !NSEvent.modifierFlags.contains(.command), let w = e.window, w == b?.window { DispatchQueue.main.async { p.toggle() } }
                    return e
                } as AnyObject)
            case "toggle":    // the action only switches the icon: opens nothing, and a second click switches it back
                let p = Pop(t, b); keep.append(p)
                b.target = p; b.action = #selector(Pop.flip(_:)); b.title = "OFF"; b.setAccessibilityTitle("switch")
            case "timer":     // like "monitor", with a title that changes all the time
                let p = Pop(t, b); keep.append(p)
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak b] _ in MainActor.assumeIsolated { b?.image = nil; b?.title = String(format: "%04d", Int(Date().timeIntervalSince1970 * 2) % 10000); b?.setAccessibilityTitle("T") } }
                keep.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak b] e in
                    if let w = e.window, w == b?.window { DispatchQueue.main.async { p.toggle() } }
                    return e
                } as AnyObject)
            case "event":     // the action runs, but only acts when the current event is a mouse-up
                let p = Pop(t, b); keep.append(p)
                b.target = p; b.action = #selector(Pop.act(_:)); b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            case "view":      // a view of its own on top of the button
                let v = MouseView(frame: b.bounds); v.autoresizingMask = [.width, .height]; v.pop = Pop(t, v); b.title = ""; b.addSubview(v); keep.append(v)
            case "gesture":
                let p = Pop(t, b); keep.append(p)
                b.addGestureRecognizer(NSClickGestureRecognizer(target: p, action: #selector(Pop.gesture(_:))))
            default: break
            }
        }
        keep.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]) { e in
            if ProcessInfo.processInfo.environment["FIXTURE_DUMP"] != nil {
                log("RAW \(e)")
                if let c = e.cgEvent {
                    log("FIELDS " + (0..<256).compactMap { i in CGEventField(rawValue: UInt32(i)).map { (i, c.getIntegerValueField($0)) } }.filter { $0.1 != 0 }.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
                }
            }
            log("EVENT type=\(e.type.rawValue) windowNumber=\(e.windowNumber) window=\(e.window.map { "\(type(of: $0))" } ?? "nil") at=\(NSStringFromPoint(e.locationInWindow))")
            return e
        } as AnyObject)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for (t, it) in zip(types, items) {
                log("ITEM \(t) windowNumber=\(it.button?.window?.windowNumber ?? -1) class=\(it.button?.window.map { "\(type(of: $0))" } ?? "-") frame=\(it.button?.window.map { NSStringFromRect($0.frame) } ?? "-") visible=\(it.button?.window?.isVisible ?? false) occl=\(it.button?.window?.occlusionState.contains(.visible) ?? false)")
            }
            for w in NSApp.windows { log("WINDOW \(w.windowNumber) \(type(of: w)) \(NSStringFromRect(w.frame))") }
        }
    }
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
} else if args.count > 1 && args[1] == "clicktypes" {
    ClickTypes.start(log: args[2], types: args.count > 3 ? Array(args[3...]) : ["menu", "monitor", "event", "view", "gesture"])
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
