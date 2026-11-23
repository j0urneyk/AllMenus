import Cocoa
import ScreenCaptureKit

/// End-to-end test on the MacBook's own (notched) display — the case All Menus exists for.
/// macOS positions menu bar items, and opens their menus, on the *active* menu bar: the display
/// that has focus. So the suite first puts a small window of ours on the built-in display and
/// activates it, checks that the items now report built-in positions, and then exercises the
/// shelf there with real clicks of the code path (open morph, flight, landing, real menu),
/// capturing the top of the built-in screen while it happens.
final class BuiltinSuite {
    let shelf: ShelfController
    let out: String
    let targets: [String]
    var measureFPS = false
    private let meter = FrameMeter()
    private var probe: NSWindow?
    private var previous: NSRunningApplication?
    private let screen: NSScreen

    init?(shelf: ShelfController, out: String, targets: [String]) {
        guard let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else { return nil }
        self.shelf = shelf; self.out = out; self.targets = targets; self.screen = s
    }

    func log(_ s: String) { print(s); fflush(stdout) }

    /// Region around the notch, global CG coordinates (top-left origin).
    var region: CGRect {
        let cg = MenuExtras.cgBounds(screen)
        let notch = NotchTrigger.notchRect(on: screen) ?? .zero
        return CGRect(x: max(cg.minX, notch.midX - 520), y: cg.minY, width: 1040, height: 360).intersection(cg)
    }

    func capture(_ name: String) {
        let display = CGMainDisplayID()
        let rect = region
        let path = "\(out)/\(name).png"
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let d = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(CGPoint(x: rect.midX, y: rect.midY)) }) ?? content.displays.first(where: { $0.displayID == display }) else { return }
            let db = CGDisplayBounds(d.displayID)
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = rect.offsetBy(dx: -db.minX, dy: -db.minY)
            cfg.width = Int(rect.width); cfg.height = Int(rect.height)
            cfg.showsCursor = false
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

    func run() {
        previous = NSWorkspace.shared.frontmostApplication
        // 1) Focus the built-in display with a small window of ours, bottom-right corner.
        let f = screen.frame
        let w = NSWindow(contentRect: NSRect(x: f.maxX - 260, y: f.minY + 60, width: 220, height: 60),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "All Menus test running…"
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        probe = w
        after(1.2) { self.checkActive() }
    }

    private var clicked = false

    func checkActive() {
        let items = MenuExtras.enumerate(viewDisplay: MenuExtras.cgBounds(screen))
        let cg = MenuExtras.cgBounds(screen)
        let onBuiltin = items.filter { cg.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }.count
        log("active app is us: \(NSApp.isActive) · items reporting built-in positions: \(onBuiltin)/\(items.count)\(clicked ? " (after a click on the built-in display)" : "")")
        if onBuiltin == 0 && !clicked, let w = probe {
            // Focus alone doesn't move the active menu bar; a click on that display does.
            clicked = true
            let h = NSScreen.screens[0].frame.maxY
            MenuExtras.click(at: CGPoint(x: w.frame.midX, y: h - (w.frame.maxY - 12)))
            after(1.0) { self.checkActive() }
            return
        }
        for i in items { log(String(format: "   %-34@ x=%5.0f %@", i.displayName as NSString, i.frame.minX, i.hidden ? "HIDDEN" : "visible")) }
        guard onBuiltin > 0 else { log("RESULT built-in menu bar did not become active — cannot test there"); finish(); return }
        shelf.forcedScreen = screen
        if measureFPS {
            log("display: \(screen.localizedName), up to \(screen.maximumFramesPerSecond) Hz")
            // Count only what is visible: below the menu bar (the notch area has no pixels on a real MacBook).
            let cg = MenuExtras.cgBounds(screen)
            var r = region
            r.origin.y = cg.minY + screen.safeAreaInsets.top
            r.size.height -= screen.safeAreaInsets.top
            meter.start(region: r, screen: screen) { self.after(1.0) { self.fpsRun() } }
            return
        }
        openProbe()
    }

    // Frame-rate run: open, close, then flights to each target, each window timed precisely.
    private func fpsRun() {
        // Calibration: a plain Core Animation square sliding for 0.5 s — the best this setup can show.
        let n = NotchTrigger.notchRect(on: screen) ?? screen.frame
        let cw = NSPanel(contentRect: NSRect(x: n.midX - 200, y: n.minY - 120, width: 400, height: 60),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        cw.level = .popUpMenu; cw.isOpaque = false; cw.backgroundColor = .clear; cw.ignoresMouseEvents = true
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 60)); v.wantsLayer = true; cw.contentView = v
        let sq = CALayer(); sq.frame = CGRect(x: 0, y: 10, width: 40, height: 40); sq.backgroundColor = NSColor.systemOrange.cgColor
        v.layer?.addSublayer(sq)
        cw.orderFrontRegardless()
        let c0 = CACurrentMediaTime()
        let slide = CABasicAnimation(keyPath: "position.x"); slide.fromValue = 20; slide.toValue = 380; slide.duration = 0.5
        sq.position.x = 380; sq.add(slide, forKey: "slide")
        after(0.7) {
            self.log(self.meter.report("calibration (CA square)", from: c0 + 0.03, to: c0 + 0.5))
            cw.orderOut(nil)
            self.after(0.3) { self.fpsPanel() }
        }
    }

    /// Opens and closes the shelf three times in a row, measuring each opening separately.
    private func fpsPanel(round: Int = 1) {
        // Main-thread watchdog: a 2 ms timer; any late tick = the main thread was busy that long.
        var stalls: [String] = []
        var last = CACurrentMediaTime()
        let t = CACurrentMediaTime()
        let dog = Timer(timeInterval: 0.002, repeats: true) { _ in
            let now = CACurrentMediaTime()
            if now - last > 0.008 { stalls.append(String(format: "%.0f–%.0f ms", (last - t) * 1000, (now - t) * 1000)) }
            last = now
        }
        RunLoop.main.add(dog, forMode: .common)
        shelf.show(byHover: true)
        shelf.keepOpenForTest()
        after(0.65) {
            dog.invalidate()
            self.log(self.meter.report("panel open #\(round)", from: t, to: t + 0.6))
            self.log("      main thread busy >8 ms at: " + (stalls.isEmpty ? "none" : stalls.joined(separator: ", ")))
            let c = CACurrentMediaTime()
            self.shelf.close(animated: true)
            self.after(0.45) {
                if round == 1 { self.log(self.meter.report("panel close", from: c, to: c + 0.35)) }
                if round < 3 { self.after(0.3) { self.fpsPanel(round: round + 1) } }
                else { self.fpsFlights(self.targets) }
            }
        }
    }

    private func fpsFlights(_ left: [String]) {
        guard let name = left.first else { meter.stop(); finish(); return }
        let items = MenuExtras.enumerate(viewDisplay: MenuExtras.cgBounds(screen))
        guard let item = items.first(where: { $0.displayName.lowercased().contains(name.lowercased()) }) else { fpsFlights(Array(left.dropFirst())); return }
        shelf.show(byHover: true)
        shelf.keepOpenForTest()
        after(0.7) {
            let t = CACurrentMediaTime()
            self.shelf.pickForTest(item)
            self.after(0.55) {
                self.log(self.meter.report("flight → \(item.hidden ? "notch" : "bar") (\(item.shortName))", from: t, to: t + FlyTo.duration + 0.05))
                SelfTest.closePopups()
                self.after(0.7) { self.fpsFlights(Array(left.dropFirst())) }
            }
        }
    }

    // 2) Open/close morph on the built-in display.
    func openProbe() {
        shelf.show(byHover: true)
        shelf.keepOpenForTest()
        let t0 = CACurrentMediaTime()
        for (ms, name) in [(60, "open_060"), (160, "open_160"), (300, "open_300"), (650, "open_650")] {
            after(Double(ms) / 1000) {
                let r = self.shelf.presentedOutline
                self.log(String(format: "open %4d ms  outline %3.0f x %3.0f  content α %.2f", Int((CACurrentMediaTime() - t0) * 1000), r.width, r.height, self.shelf.presentedContentOpacity))
                self.capture(name)
            }
        }
        after(0.9) { self.shelf.close(animated: true) }
        after(1.5) { self.flights(self.targets) }
    }

    // 3) For each target: open the shelf, pick it, watch the flight land and the real menu open.
    func flights(_ left: [String]) {
        guard let name = left.first else { finish(); return }
        let items = MenuExtras.enumerate(viewDisplay: MenuExtras.cgBounds(screen))
        guard let item = items.first(where: { $0.displayName.lowercased().contains(name.lowercased()) }) else {
            log("-- \(name): not found"); flights(Array(left.dropFirst())); return
        }
        log("-- \(item.displayName) (\(item.hidden ? "hidden on the built-in menu bar" : "visible"), x=\(Int(item.frame.minX)))")
        shelf.show(byHover: true)
        shelf.keepOpenForTest()
        let tag = name.lowercased().replacingOccurrences(of: " ", with: "_")
        after(0.6) {
            let before = MenuExtras.popupWindowIDs()
            let t0 = Date()
            self.shelf.pickForTest(item)
            let wn = FlyTo.lastWindowNumber
            var opened: Double? = nil
            Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { t in
                if opened == nil, !MenuExtras.popupWindowIDs(of: item.isSystem ? nil : [item.pid]).subtracting(before).isEmpty { opened = Date().timeIntervalSince(t0) }
                if Date().timeIntervalSince(t0) > 2 { t.invalidate() }
            }
            for ms in [150, 280, 380, 470, 750, 1500] {
                self.after(Double(ms) / 1000) {
                    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                    let on = info.contains { ($0[kCGWindowNumber as String] as? Int) == wn }
                    self.log(String(format: "   t=%4d ms  flying icon window: %@", ms, on ? "on screen" : "gone"))
                    self.capture("\(tag)_\(ms)")
                }
            }
            self.after(1.6) {
                self.log(opened.map { String(format: "   real menu opened after %.0f ms", $0 * 1000) } ?? "   real menu did NOT open")
                if opened != nil {
                    SelfTest.closePopups()
                    // Popovers that ignore Escape close on a click elsewhere: on our own test window.
                    if let w = self.probe {
                        let h = NSScreen.screens[0].frame.maxY
                        MenuExtras.click(at: CGPoint(x: w.frame.midX, y: h - (w.frame.maxY - 12)))
                    }
                }
                self.after(2.0) { self.flights(Array(left.dropFirst())) }
            }
        }
    }

    func finish() {
        probe?.orderOut(nil)
        previous?.activate()
        after(0.5) { exit(0) }
    }
}
