import Cocoa
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let shelf = ShelfController()
    var notch: NotchTrigger?
    var subs = Set<AnyCancellable>()
    var suite: BuiltinSuite?
    var recorder: DemoRecorder?

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        let s = Settings.shared
        if let i = args.firstIndex(of: "--style"), i + 1 < args.count, let st = PanelStyle(rawValue: args[i + 1]) { s.panelStyle = st }

        shelf.onSettings = { SettingsWindow.shared.show() }
        HotKey.shared.handler = { [weak self] in self?.shelf.toggle() }
        s.$hotkey.combineLatest(s.$hotkeyEnabled)
            .sink { combo, on in HotKey.shared.register(on ? combo : nil) }
            .store(in: &subs)
        notch = NotchTrigger { [weak self] byHover in self?.shelf.show(byHover: byHover) }
        ItemsCache.shared.startPeriodicRefresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.shelf.prewarm() }

        // Warm the icon cache, then refresh it every few minutes while idle.
        IconCache.shared.refresh(MenuExtras.enumerate()) {}
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in IconCache.shared.refresh(MenuExtras.enumerate()) {} }

        if args.contains("--onboarding") || !s.onboardingDone || !Permissions.accessibility {
            OnboardingWindow.shared.show()
        }
        if let i = args.firstIndex(of: "--settings") {
            let pane = i + 1 < args.count ? SettingsPane(rawValue: args[i + 1]) : nil
            SettingsWindow.shared.show(pane: pane)
        }
        if args.contains("--show") { shelf.show(byHover: false) }
        if let i = args.firstIndex(where: { $0 == "--flytest" || $0 == "--clickthrough" }), i + 1 < args.count {
            // Judge for the fly-to path: open the shelf (hover mode, keyboard untouched), screenshot it,
            // then either pick an item (screenshot the flight, time until the real menu shows) or click
            // the real menu bar item beside the neck (does the click pass through our window?).
            let name = args[i + 1].lowercased(), out = i + 2 < args.count ? args[i + 2] : NSTemporaryDirectory()
            func shot(_ win: Int, _ file: String) {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", String(win), "\(out)/\(file)"]; try? p.run(); p.waitUntilExit()
            }
            func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.shelf.show(byHover: true)
                // Act before the hover-opened shelf auto-closes (pointer is elsewhere during tests).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                    shot(self.shelf.windowNumber, "panel.png")
                    // "auto": a visible menu bar item that sits under the shelf window's (transparent) top strip.
                    let under = FlyTo.appKitRect
                    let wf = NSApp.windows.first { $0.windowNumber == self.shelf.windowNumber }?.frame ?? .zero
                    let pick = name == "auto"
                        ? self.shelf.model.items.first(where: { !$0.hidden && !$0.isSystem && wf.contains(NSPoint(x: under($0.frame).midX, y: under($0.frame).midY)) })
                        : self.shelf.model.items.first(where: { $0.displayName.lowercased().contains(name) })
                    guard let item = pick else { log("no item \(name) (window \(wf))"); exit(1) }
                    log("target \(item.displayName) at \(under(item.frame)) inside shelf window \(wf)")
                    let before = MenuExtras.popupWindowIDs()
                    let t0 = Date()
                    if args[i] == "--flytest" {
                        log("tile frame tracked: \(self.shelf.model.tileFrames[item.id] != nil)")
                        self.shelf.pickForTest(item)
                        // Route judge: sample the flying icon every 15 ms; count samples inside any notch.
                        var samples = 0, inNotch = 0, maxY = -CGFloat.infinity
                        let notches = NSScreen.screens.compactMap { NotchTrigger.notchRect(on: $0) }
                        let route = FlyTo.route(to: item, glyph: FlyTo.glyph(for: IconCache.shared.cached(item) ?? IconCache.fallback(item)))
                        Timer.scheduledTimer(withTimeInterval: 0.015, repeats: true) { t in
                            guard let p = FlyTo.livePosition else { if samples > 0 { t.invalidate() }; return }
                            samples += 1; maxY = max(maxY, p.y)
                            if notches.contains(where: { $0.contains(p) }) { inNotch += 1 }
                            if samples >= 26 {
                                t.invalidate()
                                log(String(format: "route: %d samples, %d inside the notch, %@ (landing y=%.0f, menu bar bottom %.0f, item hidden=%@)",
                                           samples, inNotch, route.intoNotch ? "absorbed into the notch" : (route.intoBar ? "rises into the bar" : "lands under the bar"),
                                           route.landing.midY, route.barBottom, item.hidden ? "yes" : "no"))
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { shot(FlyTo.lastWindowNumber, "flight.png") }
                    } else {
                        MenuExtras.click(at: CGPoint(x: item.frame.midX, y: item.frame.midY))
                    }
                    Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { t in
                        let opened = !MenuExtras.popupWindowIDs().subtracting(before).isEmpty
                        let el = Date().timeIntervalSince(t0)
                        if opened || el > 2 {
                            t.invalidate()
                            log(String(format: "%@ %@ — menu %@ after %.0f ms", args[i], item.displayName, opened ? "OPENED" : "did NOT open", el * 1000))
                            if opened { SelfTest.closePopups() }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(opened ? 0 : 1) }
                        }
                    }
                }
            }
        }
        if let i = args.firstIndex(of: "--landtest"), i + 1 < args.count {
            // Fly to an item as if it were hidden (lands under the menu bar), let its menu stay open,
            // and check that the flying icon is gone shortly after landing.
            let name = args[i + 1].lowercased()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let it = MenuExtras.enumerate().first(where: { $0.displayName.lowercased().contains(name) }) else { print("no item"); exit(1) }
                let hidden = MenuExtra(pid: it.pid, appName: it.appName, bundleID: it.bundleID, appIcon: it.appIcon, element: it.element,
                                       index: it.index, title: it.title, detail: it.detail, frame: it.frame, hidden: true, hiddenHere: true,
                                       captureRect: it.captureRect, captureDimmed: it.captureDimmed)
                let m = NSEvent.mouseLocation
                FlyTo.fly(icon: IconCache.shared.cached(it) ?? IconCache.fallback(it), tinted: true,
                          from: NSRect(x: m.x - 24, y: m.y - 19, width: 48, height: 38), to: hidden) { MenuExtras.press(hidden) }
                let wn = FlyTo.lastWindowNumber
                for ms in [300, 420, 500, 700, 1200] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                        let on = info.contains { ($0[kCGWindowNumber as String] as? Int) == wn }
                        let w = info.first { ($0[kCGWindowNumber as String] as? Int) == wn }
                        let layer = w?[kCGWindowLayer as String].map { "\($0)" } ?? "-"
                        let glyph = FlyTo.liveNode?.sublayers?.last?.presentation()?.opacity ?? -1
                        print(String(format: "t=%4dms icon window on screen: %@  window level: %@  glyph opacity: %.2f", ms, on ? "yes" : "no ", layer, glyph))
                        if ms == 1200 { SelfTest.closePopups(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) } }
                    }
                }
            }
        }
        if let i = args.firstIndex(of: "--builtin-suite"), i + 1 < args.count {
            let targets = Array(args[(i + 2)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.suite = BuiltinSuite(shelf: self.shelf, out: args[i + 1], targets: targets.filter { $0 != "--fps" })
                self.suite?.measureFPS = targets.contains("--fps")
                self.suite?.run() ?? { print("no notched display"); exit(1) }()
            }
        }
        if args.contains("--repro-search") {
            // Bug repro: type "rex", close (animated), reopen immediately; does the shelf size match its content?
            func check(_ label: String) {
                let c = self.shelf.sizeCheck
                let ok = abs(c.laidOut.width - c.actual.width) < 1 && abs(c.laidOut.height - c.actual.height) < 1
                print(String(format: "%-22@ laid out %3.0f x %3.0f · content needs %3.0f x %3.0f · %@", label as NSString,
                             c.laidOut.width, c.laidOut.height, c.actual.width, c.actual.height, ok ? "OK" : "MISMATCH"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.shelf.show(byHover: true); self.shelf.keepOpenForTest()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    check("opened")
                    self.shelf.typeForTest("rex")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        check("after typing rex")
                        self.shelf.close(animated: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            self.shelf.show(byHover: true); self.shelf.keepOpenForTest()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check("reopened +0.05s") }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { check("reopened +0.8s"); exit(0) }
                        }
                    }
                }
            }
        }
        if let i = args.firstIndex(of: "--record-demo"), i + 1 < args.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.recorder = DemoRecorder(shelf: self.shelf, out: args[i + 1])
                self.recorder?.run()
            }
        }
        if args.contains("--search-probe") {
            // Judge for "the shelf must not resize while searching": type step by step and compare the
            // drawn outline and the window frame with the moment the shelf finished opening.
            let steps: [(String, () -> Void)] = [
                ("d", { self.shelf.typeForTest("d") }), ("de", { self.shelf.typeForTest("e") }), ("dee", { self.shelf.typeForTest("e") }),
                ("deep", { self.shelf.typeForTest("p") }), ("dee (backspace)", { self.shelf.backspaceForTest() }), ("zzz (no match)", { self.shelf.clearSearchForTest(); self.shelf.typeForTest("zzz") }),
                ("cleared", { self.shelf.clearSearchForTest() })]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.shelf.show(byHover: true); self.shelf.keepOpenForTest()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let base = self.shelf.presentedOutline, baseWin = self.shelf.windowFrame
                    print(String(format: "%-16@ outline %3.0f x %3.0f · window %3.0f x %3.0f", "opened" as NSString, base.width, base.height, baseWin.width, baseWin.height))
                    var bad = 0
                    func step(_ i: Int) {
                        guard i < steps.count else { print(bad == 0 ? "RESULT PASS (size never changed)" : "RESULT FAIL (\(bad) steps changed size)"); exit(bad == 0 ? 0 : 1) }
                        steps[i].1()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            let o = self.shelf.presentedOutline, w = self.shelf.windowFrame
                            let same = abs(o.width - base.width) < 0.5 && abs(o.height - base.height) < 0.5 && w == baseWin
                            if !same { bad += 1 }
                            let m = self.shelf.model
                            print(String(format: "%-16@ outline %3.0f x %3.0f · window %3.0f x %3.0f · %ld match(es), %ld dimmed · %@",
                                         steps[i].0 as NSString, o.width, o.height, w.width, w.height, m.flat.count,
                                         m.items.filter { m.isDimmed($0) }.count, same ? "same" : "CHANGED"))
                            step(i + 1)
                        }
                    }
                    step(0)
                }
            }
        }
        if args.contains("--openprobe") {
            // Samples the outline the render server is actually drawing, every 30 ms, through open and close.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.shelf.show(byHover: true)
                self.shelf.keepOpenForTest()
                let t0 = CACurrentMediaTime()
                var closed = false
                Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { t in
                    let ms = Int((CACurrentMediaTime() - t0) * 1000)
                    let r = self.shelf.presentedOutline
                    print(String(format: "%@ %4d ms  outline %4.0f x %4.0f   content α %.2f", closed ? "close" : "open ", ms, r.width, r.height, self.shelf.presentedContentOpacity))
                    let limit = ProcessInfo.processInfo.environment["AM_PROBE_MS"].flatMap(Int.init) ?? 700
                    if !closed && ms > limit { closed = true; self.shelf.close(animated: true) }
                    if ms > limit + 400 { t.invalidate(); exit(0) }
                }
            }
        }
        if let i = args.firstIndex(of: "--openframes"), i + 1 < args.count {
            // Screenshots of the shelf window at fixed moments of the opening animation.
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.shelf.show(byHover: true)
                for ms in [40, 110, 180, 260, 360, 700] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        p.arguments = ["-x", "-o", "-l", String(self.shelf.windowNumber), "\(out)/open_\(ms).png"]; try? p.run()
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { exit(0) }
            }
        }
        if args.contains("--measure") {
            // Opens the shelf the way a notch hover does (never takes the keyboard), 5 times, and reports timings.
            var samples: [Double] = []
            func once(_ n: Int) {
                guard n > 0 else {
                    samples.sort()
                    FileHandle.standardError.write(String(format: "MEASURE show() median %.1f ms, max %.1f ms (n=%d)\n",
                                                          samples[samples.count / 2], samples.last!, samples.count).data(using: .utf8)!)
                    if !args.contains("--keep") { exit(0) }
                    return
                }
                shelf.show(byHover: true)
                samples.append(shelf.lastShowLatency * 1000)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    // Alternate instant and animated closes, so reopening after an animated close is exercised too.
                    if n > 1 { self.shelf.close(animated: n % 2 == 0) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { once(n - 1) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { once(5) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (Finder, Spotlight) shows the settings, since there is no Dock icon or menu bar item.
        SettingsWindow.shared.show()
        return false
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-ui"), i + 1 < args.count {
    // Renders every screen into PNGs without showing anything or taking focus: an off-screen window
    // per view, drawn with cacheDisplay. Language follows -AppleLanguages, e.g. -AppleLanguages "(en)".
    _ = NSApplication.shared
    let out = args[i + 1]
    func render(_ view: some View, _ size: CGSize, _ name: String, dark: Bool = false) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }
    let nav = SettingsNav()
    for pane in SettingsPane.allCases {
        nav.pane = pane
        render(SettingsView(nav: nav), CGSize(width: 720, height: 500), "settings_\(pane.rawValue)")
    }
    for step in 0..<4 {
        setenv("ALLMENUS_ONBOARDING_STEP", String(step), 1)
        render(OnboardingView(done: {}), CGSize(width: 560, height: 480), "onboarding_\(step)", dark: true)
    }
    for layout in ShelfLayout.allCases {
        let m = ShelfModel()
        let saved = Settings.shared.layout
        Settings.shared.layout = layout
        m.items = MenuExtras.enumerate(viewDisplay: NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }).map(MenuExtras.cgBounds))
        m.closedSize = CGSize(width: 185, height: 32); m.topInset = 32; m.open = true
        m.contentSize = NSHostingView(rootView: ShelfContent(model: m, settings: Settings.shared).fixedSize().modifier(DarkIf(on: true))).fittingSize
        let size = CGSize(width: m.contentSize.width + 80, height: m.contentSize.height + 30)
        render(ZStack(alignment: .top) { Color(white: 0.93); ShelfRoot(model: m, settings: Settings.shared) }, size, "shelf_\(layout.rawValue)")
        Settings.shared.layout = saved
    }
    print("rendered to \(out) in", Bundle.main.preferredLocalizations.first ?? "?")
    exit(0)
}
if let i = args.firstIndex(of: "--render-docs"), i + 1 < args.count {
    // Screenshots for the README/docs, made from demo items (never the machine's own apps) on a
    // drawn backdrop (wallpaper, menu bar, notch), off screen. English UI: -AppleLanguages "(en)".
    _ = NSApplication.shared
    DemoContent.enabled = true
    let out = args[i + 1]
    func render(_ view: some View, _ size: CGSize, _ name: String, dark: Bool = false) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }
    let notch = CGSize(width: 185, height: 32)
    func shelf(_ layout: ShelfLayout, keys: String = "", select: Int? = nil, name: String) {
        let saved = Settings.shared.layout
        Settings.shared.layout = layout
        let m = ShelfModel()
        m.items = DemoContent.items()
        m.iconSnapshot = DemoContent.icons(for: m.items)
        m.closedSize = notch; m.topInset = notch.height; m.open = true
        let natural = NSHostingView(rootView: ShelfContent(model: m, settings: Settings.shared).fixedSize().modifier(DarkIf(on: true))).fittingSize
        m.contentSize = natural; m.lockedSize = natural
        if !keys.isEmpty { m.keys = keys.map(String.init); m.searchFocused = true; m.lastTyped = Date() }
        m.selectedID = select.map { m.flat[$0].id } ?? m.flat.first?.id
        let size = CGSize(width: max(natural.width + 220, 820), height: natural.height + 70)
        render(ZStack(alignment: .top) { DemoBackdrop(notch: notch); ShelfRoot(model: m, settings: Settings.shared) }, size, name)
        Settings.shared.layout = saved
    }
    shelf(.grid, name: "shelf-grid")
    shelf(.list, select: 3, name: "shelf-list")
    shelf(.grid, keys: "vpn", name: "shelf-search-grid")
    render(AppearancePane(), CGSize(width: 560, height: 800), "settings-appearance")
    setenv("ALLMENUS_ONBOARDING_STEP", "0", 1)
    render(OnboardingView(done: {}), CGSize(width: 560, height: 480), "onboarding", dark: true)
    print("docs images written to \(out)")
    exit(0)
}
if args.contains("--route-test") {
    // Route judge on the real notch geometry of this Mac (built-in display), independent of which
    // display is active: for each start tile × destination, does the flying glyph ever overlap the notch?
    _ = NSApplication.shared
    guard let scr = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }), let notch = NotchTrigger.notchRect(on: scr) else { print("no notch"); exit(1) }
    let H = NSScreen.screens[0].frame.maxY
    func item(_ x: CGFloat, _ w: CGFloat, hidden: Bool) -> MenuExtra {
        MenuExtra(pid: 0, appName: "t", bundleID: nil, appIcon: nil, element: AXUIElementCreateApplication(0), index: 0, title: "", detail: "",
                  frame: CGRect(x: x, y: H - scr.frame.maxY + 4.5, width: w, height: 24), hidden: hidden, hiddenHere: hidden,
                  captureRect: nil, captureDimmed: false)
    }
    let dests: [(String, MenuExtra)] = [
        ("visible, right of notch", item(notch.maxX + 56, 38, hidden: false)),
        ("visible, touching notch", item(notch.maxX + 1, 40, hidden: false)),
        ("visible, far right", item(scr.frame.maxX - 170, 167, hidden: false)),
        ("hidden behind notch", item(notch.minX + 70, 92, hidden: true)),
        ("hidden, left of notch", item(notch.minX - 460, 92, hidden: true))]
    let barBottom = scr.frame.maxY - scr.safeAreaInsets.top
    let starts = [CGPoint(x: notch.midX - 220, y: barBottom - 60), CGPoint(x: notch.midX, y: barBottom - 110), CGPoint(x: notch.midX + 220, y: barBottom - 160)]
    let glyph = CGSize(width: 24, height: 20)
    func hits(_ c0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ c3: CGPoint, quad: Bool) -> Int {
        var n = 0
        for i in 0...100 {
            let t = CGFloat(i) / 100, u = 1 - t
            let p = quad ? CGPoint(x: u*u*c0.x + 2*u*t*c1.x + t*t*c3.x, y: u*u*c0.y + 2*u*t*c1.y + t*t*c3.y)
                         : CGPoint(x: u*u*u*c0.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*c3.x, y: u*u*u*c0.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*c3.y)
            if notch.intersects(NSRect(x: p.x - glyph.width / 2, y: p.y - glyph.height / 2, width: glyph.width, height: glyph.height)) { n += 1 }
        }
        return n
    }
    var newTotal = 0, fails = 0
    for (name, it) in dests {
        let r = FlyTo.route(to: it, glyph: glyph)
        var newHits = 0, entryOK = true
        for p0 in starts {
            let p1 = CGPoint(x: r.landing.midX, y: r.landing.midY)
            let c = FlyTo.curve(from: p0, to: p1, barBottom: r.barBottom, intoBar: r.intoBar)
            if r.intoNotch {
                // Absorbed items must stay clear of the notch for the whole glide and enter it only
                // in the final vertical rise, from straight below (x within the notch).
                var early = 0
                for i in 0...100 {
                    let t = CGFloat(i) / 100, u = 1 - t
                    let p = CGPoint(x: u*u*u*p0.x + 3*u*u*t*c.0.x + 3*u*t*t*c.1.x + t*t*t*p1.x, y: u*u*u*p0.y + 3*u*u*t*c.0.y + 3*u*t*t*c.1.y + t*t*t*p1.y)
                    let inside = notch.intersects(NSRect(x: p.x - glyph.width / 2, y: p.y - glyph.height / 2, width: glyph.width, height: glyph.height))
                    if inside && t < 0.8 { early += 1 }
                    if inside && !(p.x > notch.minX && p.x < notch.maxX) { entryOK = false }
                }
                newHits += early
                if !notch.contains(p1) { entryOK = false }
            } else {
                newHits += hits(p0, c.0, c.1, p1, quad: false)
            }
        }
        newTotal += newHits
        if !entryOK { fails += 1 }
        let kind = r.intoNotch ? "absorbed into the notch" : (r.intoBar ? "rises into the bar" : "lands under the bar")
        print(String(format: "%-26@ %-24@ notch overlap during the glide: %d/303%@", name as NSString, kind as NSString, newHits,
                     r.intoNotch ? (entryOK ? " · enters from straight below, ends inside" : " · BAD ENTRY") : ""))
    }
    print("TOTAL glide overlap \(newTotal), bad entries \(fails)")
    exit(newTotal == 0 && fails == 0 ? 0 : 1)
}
if let i = args.firstIndex(of: "--render-notch"), i + 1 < args.count {
    // Off-screen render of the shelf as it looks under a 185×32 pt notch (no window, no focus change).
    _ = NSApplication.shared
    let m = ShelfModel()
    m.items = MenuExtras.enumerate(viewDisplay: NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }).map(MenuExtras.cgBounds))
    m.closedSize = CGSize(width: 185, height: 32); m.topInset = 32; m.open = true
    let env = ProcessInfo.processInfo.environment
    // Like the live shelf: size fixed at opening (no search), then the search applies inside it.
    m.lockedSize = NSHostingView(rootView: ShelfContent(model: m, settings: Settings.shared).fixedSize().modifier(DarkIf(on: true))).fittingSize
    if let q = env["AM_RENDER_KEYS"] { m.keys = q.map(String.init) }
    m.searchFocused = env["AM_RENDER_FOCUS"] != nil
    m.lastTyped = Date()
    m.selectedID = m.flat.first?.id
    let measure = NSHostingView(rootView: ShelfContent(model: m, settings: Settings.shared).fixedSize().modifier(DarkIf(on: true)))
    m.contentSize = measure.fittingSize
    let size = CGSize(width: m.contentSize.width + 120, height: m.contentSize.height + 40)
    // A fake menu bar strip behind it, to see that the body starts below the menu bar.
    let view = ZStack(alignment: .top) {
        Color(white: 0.93)
        Rectangle().fill(Color(red: 0.25, green: 0.45, blue: 0.75)).frame(height: 32)
        ShelfRoot(model: m, settings: Settings.shared)
    }.frame(width: size.width, height: size.height)
    MainActor.assumeIsolated {
        let r = ImageRenderer(content: view); r.scale = 2
        if let cg = r.cgImage { try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1])) }
    }
    exit(0)
}
if args.contains("--list") || args.contains("--selftest") || args.contains("--matte-test") || args.contains("--hangul-test") {
    _ = NSApplication.shared
    SelfTest.run(args)
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
