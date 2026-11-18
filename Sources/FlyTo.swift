import Cocoa
import QuartzCore

/// The visual bridge for "this menu opens up there": a copy of the clicked icon lifts off the
/// shelf, travels to the real item and the real menu opens as it lands. Everything is Core
/// Animation on one overlay window (render server, display refresh rate).
///
/// The route never crosses the notch (a physical cut-out, so anything flying through it blinks out):
/// the icon travels *below* the menu bar and only rises into the bar straight under a visible item.
/// Items macOS isn't drawing (behind the notch / overflowed) have no visible spot in the bar, so the
/// icon lands just under the menu bar where their menu actually opens.
enum FlyTo {
    static let duration: CFTimeInterval = 0.42
    /// Window number of the last flight (for tests/screenshots).
    private(set) static var lastWindowNumber = 0
    /// The flying layer and its window origin, so tests can sample the route on screen.
    private(set) static weak var liveNode: CALayer?
    private(set) static var liveOrigin: CGPoint = .zero
    private static var live: [NSWindow] = []

    /// AX/CG rect (top-left origin) → AppKit screen rect (bottom-left origin).
    static func appKitRect(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// Where the flying icon is right now, in AppKit screen coordinates (tests).
    static var livePosition: CGPoint? {
        guard let n = liveNode, let p = n.presentation()?.position else { return nil }
        return CGPoint(x: p.x + liveOrigin.x, y: p.y + liveOrigin.y)
    }

    static func glyph(for icon: IconImage?) -> CGSize {
        guard let icon else { return CGSize(width: 18, height: 18) }
        let sz = icon.image.size
        let h = min(sz.height, 20), w = sz.height > 0 ? sz.width * h / sz.height : h
        return CGSize(width: min(w, 170), height: h)
    }

    struct Route {
        let landing: NSRect       // where the glyph ends (AppKit screen coordinates)
        let barBottom: CGFloat    // the menu bar's lower edge on that screen
        let intoBar: Bool         // ends with a vertical rise into the menu bar band
        let notch: NSRect?        // set when the icon is absorbed into the notch (hidden item)
        var intoNotch: Bool { notch != nil }
    }

    static func route(to item: MenuExtra, glyph: CGSize) -> Route {
        let end = appKitRect(item.frame)
        let scr = NSScreen.screens.first { $0.frame.contains(NSPoint(x: end.midX, y: end.midY)) }
            ?? NSScreen.screens.min { abs($0.frame.maxY - end.maxY) < abs($1.frame.maxY - end.maxY) } ?? NSScreen.screens[0]
        let barH = max(scr.frame.maxY - scr.visibleFrame.maxY, scr.safeAreaInsets.top, NSStatusBar.system.thickness)
        let barBottom = scr.frame.maxY - barH
        let notch = NotchTrigger.notchRect(on: scr)
        let behindNotch = notch.map { $0.insetBy(dx: -4, dy: 0).intersects(end) } ?? false
        let size = CGSize(width: glyph.width + 6, height: glyph.height + 6)
        if item.hidden || behindNotch {
            if let n = notch {
                // The item really lives behind the notch: fly up into it and get absorbed there.
                let landing = NSRect(x: n.midX - size.width / 2, y: n.minY + n.height * 0.4 - size.height / 2, width: size.width, height: size.height)
                return Route(landing: landing, barBottom: barBottom, intoBar: true, notch: n)
            }
            // No notch on that display: stop just under the bar, where the item's menu drops down.
            let x = min(max(end.midX, scr.frame.minX + size.width / 2 + 4), scr.frame.maxX - size.width / 2 - 4)
            let landing = NSRect(x: x - size.width / 2, y: barBottom - size.height - 3, width: size.width, height: size.height)
            return Route(landing: landing, barBottom: barBottom, intoBar: false, notch: nil)
        }
        let landing = NSRect(x: end.midX - size.width / 2, y: end.midY - size.height / 2, width: size.width, height: size.height)
        return Route(landing: landing, barBottom: barBottom, intoBar: true, notch: nil)
    }

    /// Cubic control points of the route (any coordinate space with y up): a small lift, a glide
    /// sideways that stays below `barBottom`, then — for a visible item — a straight vertical rise
    /// into the bar right under it, so the curve can't clip the notch next to it.
    static func curve(from p0: CGPoint, to p1: CGPoint, barBottom bar: CGFloat, intoBar: Bool) -> (CGPoint, CGPoint) {
        let cruise = min(bar - 22, max(p0.y + 16, intoBar ? p0.y + 16 : p1.y))
        if intoBar {
            return (CGPoint(x: p0.x + (p1.x - p0.x) * 0.55, y: min(p0.y + 18, cruise)), CGPoint(x: p1.x, y: cruise))
        }
        return (CGPoint(x: p0.x + (p1.x - p0.x) * 0.5, y: min(p0.y + 18, cruise)), CGPoint(x: p1.x, y: p1.y - 10))
    }

    static func fly(icon: IconImage?, tinted: Bool, from start: NSRect, to item: MenuExtra, landed: @escaping () -> Void) {
        let glyphSize = glyph(for: icon)
        let r = route(to: item, glyph: glyphSize)
        let area = start.union(r.landing).insetBy(dx: -90, dy: -90)
        let win = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: area.size))
        view.wantsLayer = true
        win.contentView = view
        guard let rootLayer = view.layer else { return }
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2

        // Local coordinates (bottom-left origin, like AppKit).
        let s = start.offsetBy(dx: -area.minX, dy: -area.minY)
        let e = r.landing.offsetBy(dx: -area.minX, dy: -area.minY)
        let bar = r.barBottom - area.minY
        let p0 = CGPoint(x: s.midX, y: s.midY), p1 = CGPoint(x: e.midX, y: e.midY)

        var image: CGImage?
        if let icon {
            let img = tinted ? tintedWhite(icon.image) : icon.image
            image = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        let node = CALayer()                       // moves along the route
        node.bounds = CGRect(origin: .zero, size: s.size)
        node.position = p1                         // model value = landing spot
        let card = CALayer()                       // the tile: shrinks to the glyph and melts away
        card.frame = node.bounds
        card.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        card.cornerRadius = 12
        card.cornerCurve = .continuous
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0.5
        card.shadowRadius = 12
        card.shadowOffset = CGSize(width: 0, height: -6)
        let glyph = CALayer()
        glyph.bounds = CGRect(origin: .zero, size: glyphSize)
        glyph.position = CGPoint(x: s.width / 2, y: s.height / 2)
        glyph.contents = image
        glyph.contentsGravity = .resizeAspect
        glyph.contentsScale = scale
        node.addSublayer(card)
        node.addSublayer(glyph)
        rootLayer.addSublayer(node)

        // Landing spot glows softly as the icon takes off, so the eye knows where it is heading.
        // Into the notch: its lower lip lights up instead.
        let beacon = CAShapeLayer()
        let br: CGRect
        if let n = r.notch {
            let ln = n.offsetBy(dx: -area.minX, dy: -area.minY)
            br = CGRect(x: ln.midX - ln.width * 0.32, y: ln.minY - 2, width: ln.width * 0.64, height: 4)
        } else {
            br = e.insetBy(dx: -4, dy: -3)
        }
        beacon.bounds = CGRect(origin: .zero, size: br.size)
        beacon.position = CGPoint(x: br.midX, y: br.midY)
        beacon.path = CGPath(roundedRect: beacon.bounds, cornerWidth: min(br.height / 2, 9), cornerHeight: min(br.height / 2, 9), transform: nil)
        beacon.fillColor = NSColor.white.withAlphaComponent(r.intoNotch ? 0.55 : 0.16).cgColor
        beacon.strokeColor = r.intoNotch ? nil : NSColor.white.withAlphaComponent(0.35).cgColor
        beacon.lineWidth = 1
        beacon.shadowColor = NSColor.white.cgColor
        beacon.shadowOpacity = 0.9
        beacon.shadowRadius = 8
        beacon.shadowOffset = .zero
        beacon.opacity = 0
        rootLayer.insertSublayer(beacon, below: node)

        win.orderFrontRegardless()
        // Safety net: whatever happens, the overlay is gone shortly after the flight.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 1.2) {
            win.orderOut(nil)
            live.removeAll { $0 === win }
        }
        lastWindowNumber = win.windowNumber
        liveNode = node
        liveOrigin = area.origin
        live.append(win)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 1) Route (see `curve`): stays under the menu bar, enters it only vertically under a visible item.
        let c = curve(from: p0, to: p1, barBottom: bar, intoBar: r.intoBar)
        let path = CGMutablePath()
        path.move(to: p0)
        path.addCurve(to: p1, control1: c.0, control2: c.1)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.duration = duration
        move.calculationMode = .paced
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.12, 1.0)
        node.add(move, forKey: "move")

        // 2) Node shrinks from the tile to the glyph's own size; card and glyph stay centered in it.
        let endBounds = CGRect(origin: .zero, size: e.size)
        node.bounds = endBounds
        let size = CABasicAnimation(keyPath: "bounds")
        size.fromValue = NSValue(rect: CGRect(origin: .zero, size: s.size))
        size.toValue = NSValue(rect: endBounds)
        size.duration = duration
        size.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
        node.add(size, forKey: "size")
        let endCenter = CGPoint(x: endBounds.midX, y: endBounds.midY)
        let center = CABasicAnimation(keyPath: "position")
        center.fromValue = NSValue(point: CGPoint(x: s.width / 2, y: s.height / 2))
        center.toValue = NSValue(point: endCenter)
        center.duration = duration
        center.timingFunction = size.timingFunction
        card.bounds = endBounds
        card.position = endCenter
        card.add(size, forKey: "size")
        card.add(center, forKey: "center")
        glyph.position = endCenter
        glyph.add(center, forKey: "center")

        // 3) A small lift on take-off.
        let lift = CAKeyframeAnimation(keyPath: "transform.scale")
        lift.values = [1.0, 1.12, 1.0]
        lift.keyTimes = [0, 0.25, 1]
        lift.duration = duration
        lift.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        glyph.add(lift, forKey: "lift")

        // 4) The tile melts away on the way, so only the glyph arrives.
        card.opacity = 0
        let melt = CABasicAnimation(keyPath: "opacity")
        melt.fromValue = 1; melt.toValue = 0
        melt.duration = duration * 0.8
        melt.timingFunction = CAMediaTimingFunction(name: .easeIn)
        card.add(melt, forKey: "melt")

        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [0, 1, 1, 0]
        let quiet = !r.intoBar || r.intoNotch
        glow.keyTimes = quiet ? [0, 0.35, 0.85, 1] : [0, 0.4, 0.85, 1]
        glow.duration = quiet ? duration + 0.05 : duration + 0.12
        glow.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeIn)]
        beacon.add(glow, forKey: "glow")

        if !r.intoBar || r.intoNotch {
            // Hidden item: dissolve on arrival. Into the notch it is also swallowed (shrinks into it).
            glyph.opacity = 0
            let dissolve = CAKeyframeAnimation(keyPath: "opacity")
            dissolve.values = [1, 1, 0]
            dissolve.keyTimes = [0, r.intoNotch ? 0.72 : 0.68, 1]
            dissolve.duration = duration
            glyph.add(dissolve, forKey: "dissolve")
            if r.intoNotch {
                node.transform = CATransform3DMakeScale(0.3, 0.3, 1)
                let swallow = CAKeyframeAnimation(keyPath: "transform.scale")
                swallow.values = [1.0, 1.0, 0.3]
                swallow.keyTimes = [0, 0.62, 1]
                swallow.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeIn)]
                swallow.duration = duration
                node.add(swallow, forKey: "swallow")
            }
        }

        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if !r.intoBar || r.intoNotch {
                // Nothing of ours may cover the menu that is about to open here.
                win.level = .floating
                landed()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    win.orderOut(nil)
                    live.removeAll { $0 === win }
                }
                return
            }
            landed()
            ripple(in: rootLayer, around: e, scale: scale)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glyph.opacity = 0
            let out = CABasicAnimation(keyPath: "opacity")
            out.fromValue = 1; out.toValue = 0
            out.duration = 0.18
            out.timingFunction = CAMediaTimingFunction(name: .easeOut)
            glyph.add(out, forKey: "out")
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                win.orderOut(nil)
                live.removeAll { $0 === win }
            }
        }
    }

    /// A soft ring that spreads from the landing spot.
    private static func ripple(in layer: CALayer, around r: CGRect, scale: CGFloat) {
        let ring = CAShapeLayer()
        let rect = r.insetBy(dx: -3, dy: -2)
        ring.path = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: min(rect.height / 2, 10),
                           cornerHeight: min(rect.height / 2, 10), transform: nil)
        ring.bounds = CGRect(origin: .zero, size: rect.size)
        ring.position = CGPoint(x: rect.midX, y: rect.midY)
        ring.fillColor = NSColor.white.withAlphaComponent(0.10).cgColor
        ring.strokeColor = NSColor.white.withAlphaComponent(0.75).cgColor
        ring.lineWidth = 1.5
        ring.contentsScale = scale
        layer.addSublayer(ring)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.opacity = 0
        ring.transform = CATransform3DMakeScale(1.5, 1.7, 1)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(0.9, 0.9, 1))
        grow.toValue = NSValue(caTransform3D: CATransform3DMakeScale(1.5, 1.7, 1))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9; fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = 0.42
        g.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.0, 0.2, 1.0)
        ring.add(g, forKey: "ripple")
        CATransaction.commit()
    }

    private static func tintedWhite(_ img: NSImage) -> NSImage {
        NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }
}
