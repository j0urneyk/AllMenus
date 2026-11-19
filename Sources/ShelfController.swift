import Cocoa
import SwiftUI
import Combine
import QuartzCore

final class ShelfWindow: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var onKeyChange: ((Bool) -> Void)?
    override func becomeKey() { super.becomeKey(); onKeyChange?(true) }
    override func resignKey() { super.resignKey(); onKeyChange?(false) }
    override var canBecomeKey: Bool { true }
    // Allowed to sit over the menu bar, so the panel can grow out of the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func keyDown(with e: NSEvent) { if keyHandler?(e) != true { super.keyDown(with: e) } }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Owns the shelf window: where it appears, the open/close morph, keyboard, and auto-dismiss.
///
/// The morph runs entirely in Core Animation: the outline is one CGPath (ShelfPath) whose
/// closed and open forms have identical structure, so the render server interpolates it at the
/// display's refresh rate (up to 120 Hz) without touching the main thread or SwiftUI layout.
final class ShelfController: NSObject {
    let model = ShelfModel()
    private let window: ShelfWindow
    private let root = FlippedView()
    private let fill = CAShapeLayer()                 // notch style: black body + shadow
    private let glass = NSVisualEffectView()          // glass style: blurred body…
    private let glassMask = CAShapeLayer()            // …cut to the same outline
    private let glassRim = CAShapeLayer()
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    /// Holds the content and is masked by the same outline as the body, so while the shelf morphs out
    /// of the notch the content shows only inside it (otherwise the fading-in content, already laid
    /// out at full size, shows over the desktop outside the still-small body).
    private let clip = FlippedView()
    private let contentMask = CAShapeLayer()
    private let measurer = NSHostingView(rootView: AnyView(EmptyView()))

    private var outsideMonitor: Any?
    private var exitTimer: Timer?
    private var outsideSince: Date?
    private var openedByHover = false
    private var screen: NSScreen?
    private var anchorX: CGFloat = 0
    private var subs = Set<AnyCancellable>()
    private var closing = false
    var onSettings: (() -> Void)?
    /// Tests: open on this screen regardless of where the pointer is.
    var forcedScreen: NSScreen?
    /// Recording: show() stops after putting the closed shelf on screen and leaves the opening
    /// morph here, so a capture can be running before anything moves.
    var holdMorphForRecording = false
    private(set) var pendingMorph: (() -> Void)?
    /// Time from trigger to the window being on screen, for --measure.
    private(set) var lastShowLatency: TimeInterval = 0

    private let margin: CGFloat = 44
    // Experiment switches for the frame-rate investigation (environment variables, tests only).
    private let exp = ProcessInfo.processInfo.environment
    private var expNoShadow: Bool { exp["AM_NOSHADOW"] != nil }
    private var expNoContent: Bool { exp["AM_NOCONTENT"] != nil }
    private var expKeepOrdered: Bool { exp["AM_KEEPORDERED"] != nil }
    // Geometry of the current session (y-down, window coordinates).
    private var neckW: CGFloat = 0, neckH: CGFloat = 0, bodyTop: CGFloat = 0
    private var closedBodyW: CGFloat = 0
    private var bodyW: CGFloat = 0, bodyBottom: CGFloat = 0
    private var cx: CGFloat { root.bounds.width / 2 }

    override init() {
        window = ShelfWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                             styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        super.init()
        window.level = .popUpMenu
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.keyHandler = { [weak self] in self?.handleKey($0) ?? false }

        root.wantsLayer = true
        root.layer?.masksToBounds = false
        window.contentView = root

        fill.fillColor = NSColor.black.cgColor
        fill.shadowColor = NSColor.black.cgColor
        fill.shadowOpacity = 0.45
        fill.shadowRadius = 22
        fill.shadowOffset = CGSize(width: 0, height: 10)
        root.layer?.addSublayer(fill)

        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.mask = glassMask
        glass.isHidden = true
        root.addSubview(glass)
        glassRim.fillColor = nil
        glassRim.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        glassRim.lineWidth = 1
        root.layer?.addSublayer(glassRim)

        host.sizingOptions = []
        host.wantsLayer = true
        clip.wantsLayer = true
        contentMask.fillColor = NSColor.black.cgColor
        clip.layer?.mask = contentMask
        clip.addSubview(host)
        root.addSubview(clip)

        model.onPick = { [weak self] in self?.pick($0) }
        window.onKeyChange = { [weak self] key in
            self?.model.lastTyped = Date()
            self?.model.searchFocused = key
        }
        // Clicking the search box gives the shelf the keyboard (e.g. after opening it by hovering the notch).
        model.onFocusSearch = { [weak self] in
            guard let self else { return }
            self.openedByHover = false
            self.window.makeKey()
        }
        model.onSettings = { [weak self] in
            self?.close(animated: false)
            self?.onSettings?()
        }
        // Settings changed while open (layout, labels, grouping…): re-measure. Searching never
        // re-measures: results change inside the size the shelf opened with.
        Settings.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.model.objectWillChange.send()
                self?.relayout(animated: true)
            }
        }.store(in: &subs)
    }

    /// Pays the one-time costs (SwiftUI layout of the shelf, the window's first appearance) at launch,
    /// invisibly, so the first real opening is as smooth as every later one.
    func prewarm() {
        guard !model.open else { return }
        let display = NSScreen.main.map(MenuExtras.cgBounds)
        model.items = ItemsCache.shared.items(for: display).items
        host.rootView = content()
        _ = measure()
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrame(NSRect(x: -4000, y: -4000, width: 600, height: 300), display: true)
        window.orderFrontRegardless()
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.model.open else { return }
            self.window.orderOut(nil)
            self.window.alphaValue = 1
            self.window.ignoresMouseEvents = false
        }
    }

    var isOpen: Bool { model.open }
    var windowNumber: Int { window.windowNumber }

    func toggle() { model.open ? close(animated: true) : show(byHover: false) }

    private func content() -> AnyView {
        AnyView(ShelfContent(model: model, settings: Settings.shared).fixedSize().modifier(DarkIf(on: !model.glass)))
    }

    /// Measures the content for the model as it is *now*. A fresh view identity each time: reusing
    /// the old one let SwiftUI answer with the size from before the latest model change (e.g. the
    /// filtered "rex" results right after the search was cleared on reopening — the panel came out
    /// sized for one item while showing all of them).
    private var measureGeneration = 0
    private func measure() -> CGSize {
        measureGeneration += 1
        measurer.rootView = AnyView(content().id(measureGeneration))
        measurer.layoutSubtreeIfNeeded()
        return measurer.fittingSize
    }

    func show(byHover: Bool) {
        guard !model.open else { return }
        let t0 = Date()
        let mouse = NSEvent.mouseLocation
        let scr = forcedScreen ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        screen = scr
        let st = Settings.shared
        let notch = NotchTrigger.notchRect(on: scr)
        let barH = max(scr.frame.maxY - scr.visibleFrame.maxY, scr.safeAreaInsets.top, NSStatusBar.system.thickness)
        let useNotch = st.placement == .notch && notch != nil
        anchorX = useNotch ? notch!.midX : mouse.x
        model.glass = st.panelStyle == .glass
        model.topInset = notch?.height ?? barH
        model.closedSize = useNotch ? notch!.size : .zero
        var marks: [(String, CFTimeInterval)] = [("start", CACurrentMediaTime())]
        let display = MenuExtras.cgBounds(scr)
        if DemoContent.enabled {
            model.items = DemoContent.items()
        } else {
            let (prefetched, fresh) = ItemsCache.shared.items(for: display)
            model.items = prefetched
            if fresh { ItemsCache.shared.prefetch(for: display) }   // re-read for next time, off the main thread
        }
        marks.append(("enumerate", CACurrentMediaTime()))
        model.keys = []
        model.selectedID = nil
        model.iconSnapshot = DemoContent.enabled ? DemoContent.icons(for: model.items) : Dictionary(model.items.compactMap { i in
            (IconCache.shared.cached(i) ?? IconCache.fallback(i)).map { (i.id, $0) } }, uniquingKeysWith: { a, _ in a })
        openedByHover = byHover
        closing = false

        // Geometry: a neck as wide as the notch (none in glass style or without a notch).
        neckW = (!model.glass && useNotch) ? notch!.width : 0
        neckH = model.glass ? barH + 6 : model.topInset
        bodyTop = neckH
        model.lockedSize = nil
        let cs = measure()
        marks.append(("measure", CACurrentMediaTime()))
        model.contentSize = cs
        model.lockedSize = cs
        bodyW = cs.width
        bodyBottom = model.glass ? neckH + cs.height : cs.height
        closedBodyW = neckW > 0 ? neckW : min(cs.width, 140)

        let w = max(bodyW, neckW) + 2 * margin, h = bodyBottom + margin
        var x = anchorX - w / 2
        x = min(max(x, scr.frame.minX - margin + 6), scr.frame.maxX - w + margin - 6)
        window.setFrame(NSRect(x: x, y: scr.frame.maxY - h, width: w, height: h), display: false)
        root.frame = NSRect(origin: .zero, size: NSSize(width: w, height: h))
        glass.frame = root.bounds
        clip.frame = root.bounds; contentMask.frame = clip.bounds

        // Full mode: tiles start hidden and cascade in just after the drop stage of the morph.
        let full = st.effectiveAnimation == .full
        var noAnim = Transaction(); noAnim.disablesAnimations = true
        withTransaction(noAnim) { model.revealed = !full }
        host.rootView = content()
        marks.append(("rootView", CACurrentMediaTime()))
        host.frame = NSRect(x: cx - cs.width / 2, y: model.glass ? neckH : 0, width: cs.width, height: cs.height)
        model.open = true

        fill.isHidden = model.glass
        glass.isHidden = !model.glass
        glassRim.isHidden = !model.glass

        if expNoShadow { fill.shadowOpacity = 0 }
        host.isHidden = expNoContent
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        // Opened on purpose (hotkey, click) → take the keyboard for search and arrows right away.
        // Opened by the pointer brushing the notch → don't steal typing; take the keyboard only
        // once the pointer is actually over the shelf (see checkMouseExit).
        if !byHover { window.makeKey() }
        marks.append(("orderFront", CACurrentMediaTime()))
        lastShowLatency = Date().timeIntervalSince(t0)
        openedAt = Date()

        switch Settings.shared.effectiveAnimation {
        case .full:
            // Warm-up: commit the window at its closed, notch-sized state (invisible under the notch)
            // so the first-frame cost of a newly shown window is paid before anything moves; the
            // morph starts on the next run-loop turn.
            setShape(closedPath())
            host.layer?.opacity = 0
            CATransaction.flush()
            let start = { [weak self] in
                guard let self, self.model.open, !self.closing else { return }
                self.morph(from: self.closedPath(), to: self.openPath(), opening: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.model.revealed = true }
            }
            if holdMorphForRecording { pendingMorph = start } else { DispatchQueue.main.async(execute: start) }
        case .reduced:
            setShape(openPath())
            fadeWindow(in: true)
        case .off:
            setShape(openPath())
        }
        marks.append(("morph", CACurrentMediaTime()))
        if exp["AM_TIMING"] != nil {
            CATransaction.flush()
            marks.append(("commit", CACurrentMediaTime()))
            DispatchQueue.main.async {
                marks.append(("next runloop", CACurrentMediaTime()))
                var line = "show timing:"
                for i in 1..<marks.count { line += String(format: " %@ %.1f ms ·", marks[i].0, (marks[i].1 - marks[i - 1].1) * 1000) }
                FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
            }
        }
        Settings.shared.tap(.levelChange)
        installMonitors()
        NotificationCenter.default.post(name: .shelfDidOpen, object: nil)
        // No icon re-capture while the shelf is open: text-like icons (the clock, timers) change width
        // between captures, which used to resize the open panel ~0.7 s after it appeared. Icons are
        // refreshed before opening (notch hover) and after a plain close instead.
    }

    private func openPath() -> CGPath {
        ShelfPath.make(cx: cx, neckWidth: neckW, neckHeight: neckH, bodyWidth: bodyW, bodyBottom: bodyBottom)
    }

    private func closedPath() -> CGPath {
        ShelfPath.make(cx: cx, neckWidth: neckW, neckHeight: neckH, bodyWidth: closedBodyW, bodyBottom: bodyTop)
    }

    /// The in-between pose of the two-stage morph: the notch first drops down (still narrow),
    /// then widens into the shelf — the way the Dynamic Island grows.
    private func dropPath() -> CGPath {
        let drop = min(58, (bodyBottom - bodyTop) * 0.4)
        return ShelfPath.make(cx: cx, neckWidth: neckW, neckHeight: neckH,
                              bodyWidth: max(neckW, closedBodyW) + 26, bodyBottom: bodyTop + drop)
    }

    private var shapeLayers: [CAShapeLayer] { (model.glass ? [glassMask, glassRim] : [fill]) + [contentMask] }

    /// Puts the outline in place with no motion, content fully visible.
    private func setShape(_ path: CGPath) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in shapeLayers {
            l.removeAllAnimations()
            l.path = path
            if l === fill { l.shadowPath = path }
        }
        host.layer?.removeAllAnimations()
        host.layer?.opacity = 1
        CATransaction.commit()
    }

    /// Simple mode: a short cross-fade of the whole shelf, no shape change.
    private func fadeWindow(in: Bool, completion: (() -> Void)? = nil) {
        if `in` { window.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = `in` ? 0.16 : 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: `in` ? .easeOut : .easeIn)
            window.animator().alphaValue = `in` ? 1 : 0
        }, completionHandler: completion)
    }

    /// Animates the outline (and its shadow) between two paths, plus the content fade.
    private func morph(from: CGPath, to: CGPath, opening: Bool, completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        for l in shapeLayers {
            l.removeAllAnimations()
            let current = (opening && !closing ? nil : l.presentation()?.path) ?? from
            l.path = to
            if l === fill { l.shadowPath = to }
            let keys = l === fill ? ["path", "shadowPath"] : ["path"]
            for k in keys {
                // Two stages: drop (narrow) → widen with a soft overshoot; closing runs it backwards, quicker.
                let a = CAKeyframeAnimation(keyPath: k)
                let mid = dropPath()
                if opening && exp["AM_SIMPLEMORPH"] != nil {
                    a.values = [current, to]
                    a.keyTimes = [0, 1]
                    a.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)]
                    a.duration = 0.45
                } else if opening {
                    a.values = [current, mid, to]
                    a.keyTimes = [0, 0.32, 1]
                    a.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.3, 0.0, 0.4, 1.0),
                                         CAMediaTimingFunction(controlPoints: 0.2, 1.18, 0.35, 1.0)]
                    a.duration = 0.52
                } else {
                    a.values = [current, mid, to]
                    a.keyTimes = [0, 0.55, 1]
                    a.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.6, 1.0),
                                         CAMediaTimingFunction(controlPoints: 0.5, 0.0, 0.8, 0.3)]
                    a.duration = 0.3
                }
                l.add(a, forKey: k)
            }
        }
        if let layer = host.layer {
            layer.removeAnimation(forKey: "fade")
            let fade = CABasicAnimation(keyPath: "opacity")
            // Opening always fades in from nothing; closing starts from whatever is on screen now.
            fade.fromValue = opening ? Float(0) : (layer.presentation()?.opacity ?? 1)
            fade.toValue = opening ? 1 : 0
            fade.duration = opening ? 0.24 : 0.1
            fade.beginTime = opening ? CACurrentMediaTime() + 0.12 : 0
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: opening ? .easeOut : .easeIn)
            layer.opacity = opening ? 1 : 0
            layer.add(fade, forKey: "fade")
        }
        CATransaction.commit()
    }

    func close(animated: Bool, picked: Bool = false) {
        guard model.open || window.isVisible else { return }
        removeMonitors()
        model.open = false
        if !picked {
            // The menu bar is in its normal state now: a good moment to refresh icons for next time.
            let items = model.items
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { IconCache.shared.refresh(items) {} }
        }
        let mode = Settings.shared.effectiveAnimation
        if animated && mode == .full {
            closing = true
            morph(from: openPath(), to: closedPath(), opening: false) { [weak self] in
                guard let self, self.closing else { return }
                self.closing = false
                self.hideWindow()
            }
        } else if animated && mode == .reduced {
            closing = true
            fadeWindow(in: false) { [weak self] in
                guard let self, self.closing else { return }
                self.closing = false
                self.window.orderOut(nil)
                self.window.alphaValue = 1
            }
        } else {
            closing = false
            for l in [fill, glassMask, glassRim] { l.removeAllAnimations() }
            host.layer?.removeAllAnimations()
            hideWindow()
        }
    }

    /// Search / settings changed while open: re-measure and glide the outline to the new size.
    private var openedAt = Date.distantPast

    private func relayout(animated: Bool) {
        guard model.open, !closing, screen != nil else { return }
        // Only settings changes get here. Search keeps the frame the shelf opened with.
        model.lockedSize = nil
        let cs = measure()
        model.lockedSize = cs
        guard cs != model.contentSize else { return }
        model.contentSize = cs
        bodyW = cs.width
        bodyBottom = model.glass ? neckH + cs.height : cs.height
        // Grow the window if needed (rare: e.g. labels turned on while open). Shrinking keeps the window.
        let needW = max(bodyW, neckW) + 2 * margin, needH = bodyBottom + margin
        if needW > root.bounds.width || needH > root.bounds.height {
            let w = max(needW, root.bounds.width), h = max(needH, root.bounds.height)
            let f = window.frame
            window.setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h), display: false)
            root.frame = NSRect(origin: .zero, size: NSSize(width: w, height: h))
            glass.frame = root.bounds
        clip.frame = root.bounds; contentMask.frame = clip.bounds
            for l in shapeLayers { l.removeAllAnimations(); l.path = openPath(); if l === fill { l.shadowPath = l.path } }
        }
        host.frame = NSRect(x: cx - cs.width / 2, y: model.glass ? neckH : 0, width: cs.width, height: cs.height)
        let to = openPath()
        guard Settings.shared.effectiveAnimation == .full else {
            for l in shapeLayers { CATransaction.begin(); CATransaction.setDisableActions(true); l.path = to; if l === fill { l.shadowPath = to }; CATransaction.commit() }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in shapeLayers {
            let from = l.presentation()?.path ?? l.path ?? to
            l.path = to
            if l === fill { l.shadowPath = to }
            for k in (l === fill ? ["path", "shadowPath"] : ["path"]) {
                let sp = CASpringAnimation(keyPath: k)
                sp.stiffness = 420; sp.damping = 34
                sp.duration = sp.settlingDuration
                sp.fromValue = from; sp.toValue = to
                l.add(sp, forKey: k)
            }
        }
        CATransaction.commit()
    }

    private func hideWindow() {
        if expKeepOrdered {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        } else {
            window.orderOut(nil)
        }
    }

    func pickForTest(_ item: MenuExtra) { pick(item) }
    /// Tests: the window's frame on screen.
    var windowFrame: NSRect { window.frame }
    /// Tests: delete the last typed key / clear the search, as backspace and esc would.
    func backspaceForTest() { if !model.keys.isEmpty { model.keys.removeLast() }; model.selectedID = model.flat.first?.id }
    func clearSearchForTest() { model.keys = []; model.selectedID = nil }
    /// Tests: type into the search as the keyboard would.
    func typeForTest(_ s: String) { model.keys += s.map(String.init); model.selectedID = model.flat.first?.id }
    /// Tests: the size the shelf was laid out for vs. what its content actually needs right now.
    var sizeCheck: (laidOut: CGSize, actual: CGSize) {
        // Independent judge: a brand-new hosting view of the same content (same frozen icons).
        (model.contentSize, NSHostingView(rootView: content()).fittingSize)
    }

    /// Test hook: keep a hover-opened shelf open, and read what the render server is drawing.
    func keepOpenForTest() { openedByHover = false }
    var presentedOutline: CGRect {
        let l = model.glass ? glassMask : fill
        return (l.presentation()?.path ?? l.path)?.boundingBoxOfPath ?? .zero
    }
    var presentedContentOpacity: Float { host.layer?.presentation()?.opacity ?? host.layer?.opacity ?? 0 }

    private func pick(_ item: MenuExtra) {
        if DemoContent.enabled { close(animated: true, picked: true); return }
        let st = Settings.shared
        guard st.flyToMenuBar, st.effectiveAnimation == .full else {
            close(animated: st.effectiveAnimation == .reduced, picked: true)
            MenuExtras.press(item)
            return
        }
        let start = tileScreenRect(item) ?? {
            let m = NSEvent.mouseLocation
            return NSRect(x: m.x - 24, y: m.y - 19, width: 48, height: 38)
        }()
        let icon = IconCache.shared.cached(item) ?? IconCache.fallback(item)
        close(animated: true, picked: true)
        FlyTo.fly(icon: icon, tinted: icon?.mono == true || st.iconStyle == .monochrome, from: start, to: item) {
            st.tap(.alignment)
            MenuExtras.press(item)
        }
    }

    /// A tile's rect on screen, from the frame SwiftUI last reported (top-left origin in the hosting view).
    private func tileScreenRect(_ item: MenuExtra) -> NSRect? {
        guard let f = model.tileFrames[item.id], f.width > 0 else { return nil }
        let wf = window.frame
        return NSRect(x: wf.minX + host.frame.minX + f.minX, y: wf.maxY - (host.frame.minY + f.maxY), width: f.width, height: f.height)
    }

    /// The visible body, in screen coordinates.
    private var bodyScreenRect: NSRect {
        let wf = window.frame
        return NSRect(x: wf.minX + cx - bodyW / 2, y: wf.maxY - bodyBottom, width: bodyW, height: bodyBottom)
    }

    private func installMonitors() {
        removeMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close(animated: true)
        }
        outsideSince = nil
        exitTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkMouseExit() }
    }

    private func removeMonitors() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        exitTimer?.invalidate(); exitTimer = nil
    }

    /// Opened by hovering the notch → leaving the panel closes it again, like a Dynamic Island.
    private func checkMouseExit() {
        guard openedByHover, model.open else { return }
        let p = NSEvent.mouseLocation
        let inside = bodyScreenRect.insetBy(dx: -14, dy: -14).contains(p)
        let belowNotch = p.y < (screen?.frame.maxY ?? 0) - model.topInset
        if inside && belowNotch && !window.isKeyWindow { window.makeKey() }
        guard Settings.shared.closeOnMouseExit else { return }
        if inside { outsideSince = nil; return }
        if outsideSince == nil { outsideSince = Date() }
        if Date().timeIntervalSince(outsideSince!) > 0.45 { close(animated: true) }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command) {
            if e.charactersIgnoringModifiers == "," { model.onSettings?(); return true }
            return false
        }
        // Using the keyboard means the user is here on purpose: don't auto-close on mouse exit.
        openedByHover = false
        switch Int(e.keyCode) {
        case 53:  // esc
            if model.keys.isEmpty { close(animated: true) } else { model.keys = []; model.selectedID = nil }
        case 123, 126: model.move(-1)
        case 124, 125: model.move(1)
        case 36, 76:
            if let s = model.selected ?? model.flat.first { pick(s) }
        case 51:  // delete
            if !model.keys.isEmpty { model.keys.removeLast(); model.selectedID = model.flat.first?.id }
            model.lastTyped = Date()
        default:
            guard let ch = e.characters, !ch.isEmpty,
                  ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
            model.keys += Hangul.typed(ch).map(String.init)
            model.lastTyped = Date()
            model.selectedID = model.flat.first?.id
        }
        return true
    }
}
