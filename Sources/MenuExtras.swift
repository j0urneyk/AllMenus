import Cocoa
import ApplicationServices

/// A menu bar extra (status item) of some running app, as seen through Accessibility.
struct MenuExtra {
    let pid: pid_t
    let appName: String
    let bundleID: String?
    let appIcon: NSImage?
    let element: AXUIElement
    let index: Int
    let title: String
    let detail: String
    /// Global frame, top-left origin (CG / AX coordinates).
    let frame: CGRect
    /// True when macOS does not draw it in the active menu bar (behind the notch / overflowed).
    let hidden: Bool
    /// Same question for the display the shelf is shown on (the one the user is looking at).
    let hiddenHere: Bool
    /// An on-screen menu bar rect (any display) where this item is currently drawn, for icon capture.
    let captureRect: CGRect?
    /// True when `captureRect` is on another display's (inactive, dimmed) menu bar.
    let captureDimmed: Bool

    var displayName: String {
        let label = !title.isEmpty ? title : (!detail.isEmpty ? detail : "")
        if label.isEmpty || label == appName { return appName }
        return "\(appName) — \(label)"
    }

    var cacheKey: String {
        let label = !title.isEmpty ? title : String(detail.split(separator: ",").first ?? "")
        return "\(bundleID ?? appName)#\(label.isEmpty ? String(index) : label)"
    }

    var isSystem: Bool {
        guard let b = bundleID else { return false }
        return b.hasPrefix("com.apple.")
    }
}

struct StatusWindow {
    let id: CGWindowID
    let frame: CGRect
    let onScreen: Bool
}

enum MenuExtras {
    private static func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { CGDisplayBounds($0) }
    }

    /// Menu-bar-sized windows at the status layer, grouped by display, each group sorted right-to-left.
    static func statusWindowsByDisplay() -> [(display: CGRect, windows: [StatusWindow])] {
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var all: [StatusWindow] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 25,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b),
                  r.height > 0, r.height < 50 else { continue }
            all.append(StatusWindow(id: w[kCGWindowNumber as String] as? CGWindowID ?? 0,
                                    frame: r,
                                    onScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false))
        }
        return displayBounds().compactMap { d in
            let ws = all.filter { abs($0.frame.minY - d.minY) < 2 && $0.frame.midX >= d.minX - 400 && $0.frame.midX <= d.maxX + 400 }
            return ws.isEmpty ? nil : (d, ws.sorted { $0.frame.maxX > $1.frame.maxX })
        }
    }

    /// NSScreen frame -> global CG (top-left origin) bounds.
    static func cgBounds(_ s: NSScreen) -> CGRect {
        let h = NSScreen.screens[0].frame.maxY
        return CGRect(x: s.frame.minX, y: h - s.frame.maxY, width: s.frame.width, height: s.frame.height)
    }

    /// - Parameter viewDisplay: CG bounds of the display the user is looking at; `hiddenHere` is judged there.
    static func enumerate(viewDisplay: CGRect? = nil) -> [MenuExtra] {
        let groups = statusWindowsByDisplay()
        let displays = displayBounds()
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [MenuExtra] = []

        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != me {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 0.25)
            guard let bar = attr(appEl, "AXExtrasMenuBar") else { continue }
            let kids = attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for (i, k) in kids.enumerated() {
                var p = CGPoint.zero, s = CGSize.zero
                if let v = attr(k, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
                if let v = attr(k, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
                let frame = CGRect(origin: p, size: s)
                // Items switched off (e.g. in System Settings > Menu Bar) report a bogus position outside any menu bar.
                guard s.width > 0, p.x >= 0,
                      let disp = displays.first(where: { $0.minX <= frame.midX && frame.midX <= $0.maxX + 400 && abs(frame.minY - $0.minY) < 40 })
                else { continue }

                var hidden = true
                var hiddenHere = true
                var capture: CGRect? = nil
                var dimmed = false
                if let gi = groups.firstIndex(where: { $0.display == disp }) {
                    let ws = groups[gi].windows
                    if let wi = ws.firstIndex(where: { $0.frame.minX - 1 <= frame.midX && frame.midX <= $0.frame.maxX + 1 }) {
                        hidden = !ws[wi].onScreen
                        // The same item drawn on another display's menu bar. Order can differ between
                        // displays, so pair windows of equal width in right-to-left order.
                        let width = ws[wi].frame.width
                        let rank = ws[..<wi].filter { abs($0.frame.width - width) < 2 }.count
                        func counterpart(_ g: [StatusWindow]) -> StatusWindow? {
                            guard g.count == ws.count else { return nil }
                            let same = g.filter { abs($0.frame.width - width) < 2 }
                            return rank < same.count ? same[rank] : nil
                        }
                        if !hidden { capture = ws[wi].frame }
                        else {
                            for (oi, g) in groups.enumerated() where oi != gi {
                                if let w = counterpart(g.windows), w.onScreen { capture = w.frame; dimmed = true; break }
                            }
                        }
                        hiddenHere = hidden
                        if let v = viewDisplay, v != disp, let g = groups.first(where: { $0.display == v }) {
                            hiddenHere = !(counterpart(g.windows)?.onScreen ?? false)
                        }
                    }
                }

                out.append(MenuExtra(
                    pid: app.processIdentifier,
                    appName: app.localizedName ?? app.bundleIdentifier ?? "?",
                    bundleID: app.bundleIdentifier,
                    appIcon: app.icon,
                    element: k,
                    index: i,
                    title: attr(k, kAXTitleAttribute) as? String ?? "",
                    detail: (attr(k, kAXDescriptionAttribute) as? String) ?? (attr(k, kAXHelpAttribute) as? String) ?? "",
                    frame: frame,
                    hidden: hidden,
                    hiddenHere: hiddenHere,
                    captureRect: capture,
                    captureDimmed: dimmed))
            }
        }
        // Same order as the menu bar: left to right.
        return out.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// IDs of on-screen windows that look like an opened menu or popover (not the menu bar icons themselves).
    static func popupWindowIDs() -> Set<CGWindowID> {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(info.compactMap { w in
            guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                  r.height > 20, r.width > 20 else { return nil }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer != 25 || r.height > 50 else { return nil }
            // Our own windows (the shelf, the flying icon) are never "the menu that opened".
            if (w[kCGWindowOwnerPID as String] as? pid_t) == ProcessInfo.processInfo.processIdentifier { return nil }
            return w[kCGWindowNumber as String] as? CGWindowID
        })
    }

    /// Opens the item's own menu (or popover) exactly as a click in the menu bar would.
    /// AXPress blocks until the menu closes or times out, so it runs off the main thread.
    /// Some apps accept AXPress but only react to a real mouse click; if nothing shows up
    /// within `clickFallbackDelay` and the icon is drawn somewhere, click it for real.
    static let clickFallbackDelay: TimeInterval = 0.4

    static func press(_ item: MenuExtra) {
        let el = item.element
        let before = popupWindowIDs()
        DispatchQueue.global(qos: .userInteractive).async {
            _ = AXUIElementPerformAction(el, kAXPressAction as CFString)
        }
        guard !item.hidden else { return }
        let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let t0 = Date()
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { t in
            if !popupWindowIDs().subtracting(before).isEmpty { t.invalidate(); return }
            let elapsed = Date().timeIntervalSince(t0)
            guard elapsed >= clickFallbackDelay else { return }
            t.invalidate()
            // If we were not polled in time, a menu may have opened and closed unseen: never click late.
            if elapsed < clickFallbackDelay + 0.15 { click(at: center) }
        }
    }

    /// Fallback for items that ignore AXPress: a real click at the visible icon, then put the cursor back.
    static func click(at p: CGPoint) {
        let back = CGEvent(source: nil)?.location ?? p
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGWarpMouseCursorPosition(back)
    }
}

extension MenuExtra: Identifiable {
    var id: String { "\(pid):\(index)" }

    /// Short label for under the icon.
    var shortName: String {
        if !title.isEmpty && title.count <= 14 && title != "StatusItem" { return title }
        if isSystem, let first = detail.split(separator: ",").first, !first.isEmpty { return String(first) }
        return appName
    }

    var searchText: String { [appName, title, detail, shortName, bundleID ?? ""].joined(separator: " ") }
}

/// Menu bar items read ahead of time on a background thread, so opening the shelf never waits on
/// ~40 ms of Accessibility round-trips to every running app (measured: that was the source of the
/// dropped frames at the start of the opening animation).
final class ItemsCache {
    static let shared = ItemsCache()
    private let queue = DispatchQueue(label: "allmenus.items", qos: .userInitiated)
    private let lock = NSLock()
    private var cached: [MenuExtra] = []
    private var cachedFor: CGRect?
    private var stamp = Date.distantPast
    private var inFlight = false
    private var timer: Timer?

    func startPeriodicRefresh(every seconds: TimeInterval = 5) {
        // Judge "hidden" for the display under the pointer, where the shelf would open.
        func display() -> CGRect? {
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }.map(MenuExtras.cgBounds)
        }
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in self?.prefetch(for: display()) }
        prefetch(for: display())
    }

    /// Kick off a background read (no-op if one is running).
    func prefetch(for display: CGRect?) {
        lock.lock()
        if inFlight { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        queue.async { [weak self] in
            let items = MenuExtras.enumerate(viewDisplay: display)
            guard let self else { return }
            self.lock.lock()
            self.cached = items; self.cachedFor = display; self.stamp = Date(); self.inFlight = false
            self.lock.unlock()
        }
    }

    /// Items for showing now: the prefetched list when fresh enough and judged for the same display,
    /// otherwise a synchronous read (first use, or the cache is stale).
    func items(for display: CGRect?, maxAge: TimeInterval = 6) -> (items: [MenuExtra], fresh: Bool) {
        lock.lock()
        let ok = !cached.isEmpty && Date().timeIntervalSince(stamp) < maxAge && cachedFor == display
        let c = cached
        lock.unlock()
        if ok { return (c, true) }
        let items = MenuExtras.enumerate(viewDisplay: display)
        lock.lock(); cached = items; cachedFor = display; stamp = Date(); lock.unlock()
        return (items, false)
    }
}
