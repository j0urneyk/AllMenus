import Cocoa
import Carbon.HIToolbox

/// The one system-wide shortcut, via Carbon (needs no extra permission). Re-registered live from Settings.
final class HotKey {
    static let shared = HotKey()
    var handler: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var installed = false

    func register(_ combo: KeyCombo?) {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        guard let combo else { return }
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.shared.handler?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: 0x4D534846, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

/// Opens the shelf when the pointer rests on (or clicks) the notch — the one menu bar spot that is always empty.
final class NotchTrigger {
    private var monitors: [Any] = []
    private var poll: Timer?
    private var enteredAt: Date?
    private var firedForThisVisit = false
    private let fire: (_ byHover: Bool) -> Void

    init(fire: @escaping (_ byHover: Bool) -> Void) {
        self.fire = fire
        // Mouse-moved events are barely delivered while the pointer is over the menu bar, so a
        // monitor alone misses the moment it reaches the notch. Sample the position instead
        // (30 Hz, a few microseconds each); the monitor just makes the check immediate when it fires.
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.check() }
        poll?.tolerance = 0.005
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in self?.check() }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            guard let self, Settings.shared.clickNotchToOpen, NotchTrigger.inNotch(NSEvent.mouseLocation) else { return }
            self.firedForThisVisit = true
            self.fire(false)
        }) { monitors.append(m) }
    }

    private func check() {
        guard Settings.shared.hoverToOpen, NotchTrigger.inNotch(NSEvent.mouseLocation) else {
            enteredAt = nil; firedForThisVisit = false
            return
        }
        if enteredAt == nil {
            enteredAt = Date()
            // Read the menu bar items now, during the hover delay, so the shelf opens without waiting.
            if let scr = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
                let display = MenuExtras.cgBounds(scr)
                ItemsCache.shared.prefetch(for: display)
                // …and refresh their pictures while the menu bar is still in its normal state.
                IconCache.shared.refresh(ItemsCache.shared.items(for: display, maxAge: 30).items) {}
            }
        }
        // Fire once per visit: leaving the notch re-arms it.
        if !firedForThisVisit, Date().timeIntervalSince(enteredAt!) >= Settings.shared.hoverDelay {
            firedForThisVisit = true
            fire(true)
        }
    }

    /// The notch of a given screen, in AppKit global coordinates.
    static func notchRect(on s: NSScreen) -> NSRect? {
        guard s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return nil }
        let off: CGFloat = s.frame.contains(NSPoint(x: l.minX, y: l.minY)) ? 0 : s.frame.minX
        return NSRect(x: l.maxX + off, y: s.frame.maxY - s.safeAreaInsets.top, width: r.minX - l.maxX, height: s.safeAreaInsets.top)
    }

    /// Pushing the pointer against the top edge puts it at exactly `maxY`, which a plain
    /// rect test treats as outside (the upper edge is exclusive). That is the most natural way to
    /// "go to the notch", so the test includes the edge (and a hair beyond it).
    static func inNotch(_ p: NSPoint) -> Bool {
        NSScreen.screens.contains { s in
            guard let r = notchRect(on: s) else { return false }
            return p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY + 1
        }
    }

}

extension Notification.Name {
    static let shelfDidOpen = Notification.Name("AllMenusDidOpen")
}
