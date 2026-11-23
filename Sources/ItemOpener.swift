import Cocoa
import ScreenCaptureKit

/// Opens the menu or popover of a menu bar item.
///
/// Most items open by Accessibility "press". Some apps ignore it, because they react only to mouse events: they
/// watch for a mouse-down in their button's window, check the current event's type, put a view of their own on the
/// button, or use a gesture recognizer. A press produces no mouse event, so nothing happens. For those:
///
/// - A drawn item gets a real click. What the window server adds to that click (which layer context of which
///   process it is for) is remembered as the item's address.
/// - A hidden item with a known address gets that click again, sent to its process only. macOS routes clicks to
///   drawn windows, but the app itself doesn't care whether its item is drawn.
/// - A hidden item without a known address: its app is opened again (as by double-clicking it in Finder), which
///   menu bar apps usually answer by showing their popover or window.
///
/// Nothing in the menu bar is moved, and for hidden items neither is the pointer.
enum ItemOpener {
    private static let queue = DispatchQueue(label: "allmenus.opener", qos: .userInteractive, attributes: .concurrent)

    private static let testing = CommandLine.arguments.contains { $0 == "--selftest" || $0 == "--builtin-suite" }
    /// Step-by-step log for the test tools and `AM_CLICK_LOG=1`.
    private static let verbose = testing || ProcessInfo.processInfo.environment["AM_CLICK_LOG"] != nil
    private static func log(_ s: @autoclosure () -> String) { if verbose { print("   [open] " + s()); fflush(stdout) } }

    // MARK: What is known about an item

    private enum Way: String {
        case press   // a press opens it: never needs anything else
        case click   // ignores a press, opens by a click: not pressed first any more
        case toggle  // a press switches something on or off and opens nothing: a click would switch it back
    }

    private static let lock = NSLock()
    private static let defaultsKey = "itemWays"
    private static func key(_ i: MenuExtra) -> String { "\(i.bundleID ?? i.appName)#\(i.index)" }
    nonisolated(unsafe) private static var ways: [String: String] = testing ? [:] : (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:])

    private static func way(_ item: MenuExtra) -> Way? { lock.withLock { ways[key(item)].flatMap(Way.init) } }
    private static func learn(_ way: Way, _ item: MenuExtra) {
        lock.withLock {
            guard ways[key(item)] != way.rawValue else { return }
            ways[key(item)] = way.rawValue
            // Switching items are kept until quit only: a wrong guess shouldn't cost an item its fallback for good.
            if !testing { UserDefaults.standard.set(ways.filter { $0.value != Way.toggle.rawValue }, forKey: defaultsKey) }
        }
    }

    /// The click the window server delivered to an item, per item and process.
    nonisolated(unsafe) private static var addresses: [String: (pid: pid_t, click: CGEvent)] = [:]
    private static func address(_ item: MenuExtra) -> CGEvent? {
        lock.withLock { addresses[key(item)].flatMap { $0.pid == item.pid ? $0.click : nil } }
    }

    // MARK: Opening

    static func open(_ item: MenuExtra) {
        queue.async {
            let w = Watch(item)
            switch way(item) {
            case .press, .toggle: press(item)
            case .click: byClick(item, w, sure: true)
            case nil: firstTime(item, w)
            }
        }
    }

    /// Presses the item and works out how it has to be opened.
    private static func firstTime(_ item: MenuExtra, _ w: Watch) {
        let look0 = look(item), shot0 = shot(item)
        let t0 = Date()
        var returned = false
        // A press blocks while the menu is open, so it has a thread of its own.
        Thread.detachNewThread { press(item); lock.withLock { returned = true } }
        if w.changed(within: 0.4) { learn(.press, item); return }
        // Still busy: the app is slow, or tracks a menu we don't recognize. Leave it alone.
        guard lock.withLock({ returned }) else {
            if w.changed(within: 2) { learn(.press, item) } else { log("\(item.displayName): the press is still running") }
            return
        }
        if look(item) != look0 { log("\(item.displayName): the press changed it"); learn(.toggle, item); return }
        // Different pixels that stay: the press switched something. Pixels that keep changing (a timer) say nothing.
        if let a = shot0, let b = shot(item), differs(a, b) {
            usleep(1_100_000)
            if w.changed(within: 0) { learn(.press, item); return }
            if let c = shot(item), !differs(b, c) { log("\(item.displayName): the press switched it"); learn(.toggle, item); return }
        }
        log(String(format: "%@: the press did nothing (%.0f ms)", item.displayName, Date().timeIntervalSince(t0) * 1000))
        byClick(item, w, sure: shot0 != nil)
    }

    private static func press(_ item: MenuExtra) { _ = AXUIElementPerformAction(item.element, kAXPressAction as CFString) }

    /// - Parameter sure: it is known that a press doesn't do anything, so success is worth remembering.
    private static func byClick(_ item: MenuExtra, _ w: Watch, sure: Bool) {
        let t0 = Date()
        func done(_ how: String) {
            log(String(format: "%@ opened by %@ after %.0f ms", item.displayName, how, Date().timeIntervalSince(t0) * 1000))
            if sure { learn(.click, item) }
        }
        if !item.hidden {
            clickAndLearn(item)
            if w.changed(within: 0.8) { done("a click") } else { log("\(item.displayName): a click opened nothing"); if way(item) == nil { learn(.toggle, item) } }
            return
        }
        if let click = address(item) {
            send(click, to: item.pid)
            if w.changed(within: 0.6) { done("an addressed click"); return }
            log("\(item.displayName): the address is out of date")
            lock.withLock { addresses[key(item)] = nil }
        }
        guard !item.isSystem, let url = NSRunningApplication(processIdentifier: item.pid)?.bundleURL, url.pathExtension == "app" else { return }
        let c = NSWorkspace.OpenConfiguration()
        c.activates = true
        c.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: c)
        if w.changed(within: 1.5) { done("opening the app again") } else { log("\(item.displayName): opening the app again showed nothing") }
    }

    /// Notices when something of the item's app opens, or when its open popover closes (picking the item again closes it).
    private struct Watch {
        private let owners: Set<pid_t>?
        private let before: Set<CGWindowID>
        private let own: Set<CGWindowID>
        init(_ item: MenuExtra) {
            // The app and its helpers (same vendor and product in the bundle identifier); system items: whatever appears.
            if item.isSystem { owners = nil } else {
                let family = item.bundleID.map { $0.split(separator: ".").prefix(2).joined(separator: ".") + "." }
                owners = Set(NSWorkspace.shared.runningApplications.filter { a in
                    family.map { f in a.bundleIdentifier?.hasPrefix(f) ?? false } ?? false
                }.map(\.processIdentifier)).union([item.pid])
            }
            before = MenuExtras.popupWindowIDs()
            own = owners == nil ? [] : MenuExtras.popupWindowIDs(of: owners)
        }
        func changed(within s: TimeInterval) -> Bool {
            let end = Date().addingTimeInterval(s)
            while true {
                let now = MenuExtras.popupWindowIDs(of: owners)
                if !now.subtracting(before).isEmpty || !own.isSubset(of: now) { return true }
                if Date() >= end { return false }
                usleep(12_000)
            }
        }
    }

    // MARK: How an item looks

    private static func look(_ item: MenuExtra) -> String {
        func attr(_ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(item.element, a as CFString, &v) == .success ? v : nil }
        return [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute].map { attr($0) as? String ?? "" }.joined(separator: "|")
    }

    /// The item's own window, which can be captured even while it isn't drawn. Nil without the Screen Recording permission.
    private static func shot(_ item: MenuExtra) -> CGImage? {
        guard IconCache.canCapture, let id = MenuExtras.statusWindowsByDisplay().flatMap(\.windows).first(where: {
            $0.frame.minX - 1 <= item.frame.midX && item.frame.midX <= $0.frame.maxX + 1 && abs($0.frame.midY - item.frame.midY) < 20
        })?.id else { return nil }
        final class Box: @unchecked Sendable { var image: CGImage? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            guard let all = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                  let w = all.windows.first(where: { $0.windowID == id }) else { return }
            let c = SCStreamConfiguration()
            c.width = Int(w.frame.width * 2); c.height = Int(w.frame.height * 2)
            c.showsCursor = false
            box.image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: c)
        }
        return done.wait(timeout: .now() + 0.5) == .success ? box.image : nil
    }

    private static func differs(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return true }
        func pixels(_ i: CGImage) -> [UInt8] {
            var p = [UInt8](repeating: 0, count: i.width * i.height * 4)
            p.withUnsafeMutableBytes { raw in
                let c = CGContext(data: raw.baseAddress, width: i.width, height: i.height, bitsPerComponent: 8, bytesPerRow: i.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                c?.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
            }
            return p
        }
        let x = pixels(a), y = pixels(b)
        var n = 0
        for k in stride(from: 0, to: x.count, by: 4) where (0..<4).contains(where: { abs(Int(x[k + $0]) - Int(y[k + $0])) > 48 }) { n += 1 }
        return n >= 12
    }

    // MARK: Clicks

    /// Undocumented event field: the layer context (CAContext) a mouse event is for. AppKit finds a status
    /// item's window by it; the windows on the menu bar itself belong to Control Center.
    private static let contextField = CGEventField(rawValue: 146)!

    /// A real click, watched on its way to the app to learn the item's address.
    private static func clickAndLearn(_ item: MenuExtra) {
        final class Catch { var pid: pid_t = 0; var event: CGEvent? }
        let box = Catch()
        box.pid = item.pid
        let ref = Unmanaged.passRetained(box)
        // Annotated: after the window server has filled in the receiver. It only looks; events pass unchanged.
        let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: 1 << CGEventMask(CGEventType.leftMouseDown.rawValue), callback: { _, _, e, info in
            if let info {
                let b = Unmanaged<Catch>.fromOpaque(info).takeUnretainedValue()
                if b.event == nil, e.getIntegerValueField(.eventTargetUnixProcessID) == Int64(b.pid) { b.event = e.copy() }
            }
            return Unmanaged.passUnretained(e)
        }, userInfo: ref.toOpaque())
        let source = tap.flatMap { CFMachPortCreateRunLoopSource(nil, $0, 0) }
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        MenuExtras.click(at: CGPoint(x: item.frame.midX, y: item.frame.midY))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            if let e = box.event, e.getIntegerValueField(contextField) != 0 {
                lock.withLock { addresses[key(item)] = (item.pid, e) }
                log("\(item.displayName): learned its address")
            }
            ref.release()
        }
    }

    /// Sends a click like `learned` to one process. The pointer and the session's input state aren't touched.
    private static func send(_ learned: CGEvent, to pid: pid_t) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let e = learned.copy() else { return }
            e.type = type
            e.flags = []
            e.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            e.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setDoubleValueField(.mouseEventPressure, value: type == .leftMouseDown ? 1 : 0)
            e.postToPid(pid)
            usleep(40_000)
        }
    }
}
