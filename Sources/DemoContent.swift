import Cocoa
import SwiftUI

/// Made-up menu bar items for screenshots and recordings, so documentation never shows the
/// apps installed on the machine that produced it. Turned on with `AM_DEMO=1` (or by the docs
/// renderer); opening an item does nothing.
enum DemoContent {
    static var enabled = ProcessInfo.processInfo.environment["AM_DEMO"] != nil

    private static func symbol(_ name: String) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))!
        img.isTemplate = true
        return img
    }

    /// Text drawn like a menu bar item (the clock, a timer).
    private static func text(_ s: String) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let size = (s as NSString).size(withAttributes: attrs)
        let img = NSImage(size: NSSize(width: ceil(size.width), height: 16), flipped: false) { r in
            (s as NSString).draw(at: NSPoint(x: 0, y: (r.height - size.height) / 2), withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        return img
    }

    /// A colored icon (most menu bar icons are monochrome; a few are not).
    private static func colored() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 6, dy: 6)).fill()
            return true
        }
    }

    // name, picture, hidden behind the notch
    private static let catalog: [(String, () -> NSImage, Bool, Bool)] = [
        ("Weather", { symbol("cloud.sun.fill") }, true, true),
        ("Timer", { text("12:30") }, true, true),
        ("Notes", { symbol("note.text") }, true, true),
        ("VPN", { symbol("lock.shield.fill") }, false, true),
        ("Music", { symbol("music.note") }, false, true),
        ("Recorder", { colored() }, false, false),
        ("Clipboard", { symbol("doc.on.clipboard") }, false, true),
        ("Wi-Fi", { symbol("wifi") }, false, true),
        ("Battery", { symbol("battery.75") }, false, true),
        ("Control Center", { symbol("switch.2") }, false, true),
        ("Clock", { text("Tue 18 Nov  5:50 PM") }, false, true),
    ]

    static func items() -> [MenuExtra] {
        catalog.enumerated().map { i, entry in
            MenuExtra(pid: pid_t(-1 - i), appName: entry.0, bundleID: "demo.\(i)", appIcon: nil,
                      element: AXUIElementCreateApplication(0), index: i, title: "", detail: "",
                      frame: CGRect(x: 900 + i * 40, y: 4, width: 32, height: 24),
                      hidden: entry.2, hiddenHere: entry.2, captureRect: nil, captureDimmed: false)
        }
    }

    /// Symbol for the icon column of the list when the item's own picture is wide text (timer, clock).
    static func listSymbol(for item: MenuExtra) -> IconImage? {
        guard enabled, item.bundleID?.hasPrefix("demo.") == true else { return nil }
        let name = ["Timer": "timer", "Clock": "clock", "Battery": "battery.75"][item.appName] ?? "app.dashed"
        return IconImage(image: symbol(name), mono: true)
    }

    static func icons(for items: [MenuExtra]) -> [String: IconImage] {
        Dictionary(uniqueKeysWithValues: zip(items, catalog).map { item, entry in
            (item.id, IconImage(image: entry.1(), mono: entry.3))
        })
    }
}

/// A drawn desktop for documentation images: wallpaper, a generic menu bar and the notch.
/// Nothing from the real screen is ever captured behind the shelf.
struct DemoBackdrop: View {
    var notch = CGSize(width: 185, height: 32)
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.24, green: 0.30, blue: 0.62), Color(red: 0.50, green: 0.28, blue: 0.66)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 16) {
                Image(systemName: "apple.logo").font(.system(size: 13, weight: .semibold))
                Text("Finder").fontWeight(.bold)
                ForEach(["File", "Edit", "View", "Go"], id: \.self) { Text($0) }
                Spacer()
                Image(systemName: "wifi"); Image(systemName: "battery.75"); Text("Tue 18 Nov  5:50 PM")
            }
            .font(.system(size: 13)).foregroundStyle(.white).lineLimit(1).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18).frame(height: notch.height)
            .background(Color.white.opacity(0.16))
            NeckShape(neckWidth: notch.width, neckHeight: notch.height).fill(.black).frame(width: notch.width, height: notch.height)
        }
    }
}
