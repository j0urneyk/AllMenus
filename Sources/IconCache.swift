import Cocoa
import ScreenCaptureKit
import CryptoKit

struct IconImage {
    let image: NSImage
    /// Monochrome glyph: drawn in the shelf's foreground color instead of its captured color.
    let mono: Bool
}

/// Real menu bar icon images, separated from the menu bar background.
/// Captured from whichever display currently draws the item and remembered on disk,
/// so items later hidden behind the notch still show their real icon.
final class IconCache {
    static let shared = IconCache()
    private var mem: [String: IconImage] = [:]
    let dir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = caches.appendingPathComponent("AllMenus/icons-v2")
        // One-time move from the app's previous name, so captured icons survive the rename.
        let old = caches.appendingPathComponent("MenuShelf/icons-v2")
        if !FileManager.default.fileExists(atPath: d.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: old, to: d)
            try? FileManager.default.removeItem(at: caches.appendingPathComponent("MenuShelf"))
        }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func file(_ key: String) -> URL {
        let h = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return dir.appendingPathComponent("\(h).png")
    }

    private func dimMarker(_ key: String) -> URL { file(key).appendingPathExtension("dim") }

    private static func make(_ cg: CGImage, mono: Bool) -> IconImage {
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)) // stored @2x
        img.isTemplate = mono
        return IconImage(image: img, mono: mono)
    }

    func cached(_ item: MenuExtra) -> IconImage? {
        if let i = mem[item.cacheKey] { return i }
        guard let src = CGImageSourceCreateWithURL(file(item.cacheKey) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let i = IconCache.make(cg, mono: Matting.isMono(cg))
        mem[item.cacheKey] = i
        return i
    }

    static var canCapture: Bool { Permissions.screenCapture }

    /// Captures every item that is drawn somewhere right now; calls back on main when done.
    func refresh(_ items: [MenuExtra], done: @escaping () -> Void) {
        guard IconCache.canCapture else { done(); return }
        let wanted = items.compactMap { i in i.captureRect.map { (i.cacheKey, $0, i.captureDimmed) } }
        guard !wanted.isEmpty else { done(); return }
        Task {
            defer { DispatchQueue.main.async(execute: done) }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            for d in content.displays {
                let db = CGDisplayBounds(d.displayID)
                // Clip to the display: the rightmost item's window can stick out past the screen edge.
                let mine = wanted.filter { db.contains(CGPoint(x: $0.1.midX, y: $0.1.midY)) }
                    .map { ($0.0, $0.1.intersection(db), $0.2) }
                guard !mine.isEmpty else { continue }
                let strip = mine.map(\.1).reduce(mine[0].1) { $0.union($1) }
                let local = strip.offsetBy(dx: -db.minX, dy: -db.minY)
                let cfg = SCStreamConfiguration()
                cfg.sourceRect = local
                cfg.width = Int(local.width * 2); cfg.height = Int(local.height * 2)
                cfg.showsCursor = false
                guard let img = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) else { continue }
                let sx = CGFloat(img.width) / local.width, sy = CGFloat(img.height) / local.height
                for (key, r, dim) in mine {
                    // Never let a dimmed capture (inactive display) replace a crisp one.
                    if dim, FileManager.default.fileExists(atPath: file(key).path),
                       !FileManager.default.fileExists(atPath: dimMarker(key).path) { continue }
                    let c = CGRect(x: (r.minX - strip.minX) * sx, y: (r.minY - strip.minY) * sy, width: r.width * sx, height: r.height * sy)
                    guard let crop = img.cropping(to: c.integral), let m = Matting.matte(crop) else { continue }
                    if let dest = CGImageDestinationCreateWithURL(file(key) as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, m.image, nil); CGImageDestinationFinalize(dest)
                    }
                    if dim { FileManager.default.createFile(atPath: dimMarker(key).path, contents: nil) }
                    else { try? FileManager.default.removeItem(at: dimMarker(key)) }
                    let icon = IconCache.make(m.image, mono: m.mono)
                    await MainActor.run { self.mem[key] = icon }
                }
            }
        }
    }

    /// Blocking variant for command-line tools.
    func refreshSync(_ items: [MenuExtra]) {
        var finished = false
        refresh(items) { finished = true }
        while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Stand-in when no real capture exists yet.
    static func fallback(_ item: MenuExtra) -> IconImage? {
        if item.isSystem {
            let d = (item.detail + " " + item.title).lowercased()
            let map: [(String, String)] = [("배터리", "battery.75"), ("battery", "battery.75"), ("wi", "wifi"),  // ko-data
                                           ("시계", "clock"), ("clock", "clock"), ("제어 센터", "switch.2"),  // ko-data
                                           ("control center", "switch.2"), ("사운드", "speaker.wave.2"), ("sound", "speaker.wave.2"),  // ko-data
                                           ("집중", "moon"), ("focus", "moon"), ("bluetooth", "dot.radiowaves.left.and.right"),  // ko-data
                                           ("spotlight", "magnifyingglass"), ("siri", "waveform")]
            var symbol = map.first(where: { d.contains($0.0) })?.1
            if symbol == nil && item.appName.contains("제어 센터") { symbol = "switch.2" }  // ko-data
            if item.bundleID == "com.apple.TextInputMenuAgent" { symbol = "keyboard" }
            if let s = symbol, let img = NSImage(systemSymbolName: s, accessibilityDescription: nil) {
                img.isTemplate = true
                return IconImage(image: img, mono: true)
            }
        }
        guard let icon = item.appIcon?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 18, height: 18)
        return IconImage(image: icon, mono: false)
    }
}
