import Cocoa
import ApplicationServices

/// Outside judge: opens every item through the same path the shelf uses and checks
/// that a real menu/popover window actually appears on screen, then closes it.
enum SelfTest {
    struct Win: Hashable { let id: CGWindowID; let owner: String; let layer: Int; let frame: CGRect
        func hash(into h: inout Hasher) { h.combine(id) }
        static func == (a: Win, b: Win) -> Bool { a.id == b.id } }

    static func onScreen() -> Set<Win> {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(info.compactMap { w in
            guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return nil }
            return Win(id: w[kCGWindowNumber as String] as? CGWindowID ?? 0, owner: w[kCGWindowOwnerName as String] as? String ?? "",
                       layer: w[kCGWindowLayer as String] as? Int ?? 0, frame: r)
        })
    }

    static func key(_ code: CGKeyCode) {
        let s = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: s, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: s, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }

    /// Matting judge: the fixture's icons have known shapes and colors, so compare the
    /// captured-and-matted result with the ground-truth images the fixture wrote.
    static func matteTest(_ args: [String]) {
        let dir = args.drop { $0 != "--matte-test" }.dropFirst().first ?? "."
        let items = MenuExtras.enumerate().filter { $0.detail.hasPrefix("FIXTURE-") || $0.title.hasPrefix("FIXTURE-") }
        guard !items.isEmpty else { print("fixture icons not running"); return }
        IconCache.shared.refreshSync(items)
        var pass = true
        for item in items {
            let name = (item.detail + item.title).replacingOccurrences(of: "FIXTURE-", with: "").lowercased()
            guard let got = IconCache.shared.cached(item)?.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let truthURL = Optional(URL(fileURLWithPath: "\(dir)/\(name).png")),
                  let src = CGImageSourceCreateWithURL(truthURL as CFURL, nil),
                  let truth = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("FAIL \(name): no capture or no ground truth"); pass = false; continue }
            let g = Matting.pixels(got), t = Matting.pixels(truth)
            func mask(_ m: (px: [UInt8], w: Int, h: Int)) -> (bits: [Bool], w: Int, h: Int) {
                var minX = m.w, minY = m.h, maxX = -1, maxY = -1
                for y in 0..<m.h { for x in 0..<m.w where m.px[(y * m.w + x) * 4 + 3] > 127 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
                let w = maxX - minX + 1, h = maxY - minY + 1
                var b = [Bool](repeating: false, count: max(w * h, 0))
                for y in 0..<max(h, 0) { for x in 0..<max(w, 0) { b[y * w + x] = m.px[((y + minY) * m.w + x + minX) * 4 + 3] > 127 } }
                return (b, w, h)
            }
            let mg = mask(g), mt = mask(t)
            // Best IoU over small shifts (the glyph may land on a half pixel).
            var best = 0.0, bestShift = (0, 0)
            let W = max(mg.w, mt.w) + 4, H = max(mg.h, mt.h) + 4
            for dy in -2...2 { for dx in -2...2 {
                var inter = 0, uni = 0
                for y in 0..<H { for x in 0..<W {
                    let ax = x - 2, ay = y - 2, bx = x - 2 - dx, by = y - 2 - dy
                    let a = ax >= 0 && ay >= 0 && ax < mg.w && ay < mg.h && mg.bits[ay * mg.w + ax]
                    let b = bx >= 0 && by >= 0 && bx < mt.w && by < mt.h && mt.bits[by * mt.w + bx]
                    if a && b { inter += 1 }; if a || b { uni += 1 }
                } }
                let iou = uni == 0 ? 0 : Double(inter) / Double(uni)
                if iou > best { best = iou; bestShift = (dx, dy) }
            } }
            // Color fidelity on pixels that are fully opaque in both (after the best shift, on bbox-aligned crops).
            var colorErr = 0.0, n = 0
            func bboxOrigin(_ m: (px: [UInt8], w: Int, h: Int)) -> (Int, Int) {
                var minX = m.w, minY = m.h
                for y in 0..<m.h { for x in 0..<m.w where m.px[(y * m.w + x) * 4 + 3] > 127 { minX = min(minX, x); minY = min(minY, y) } }
                return (minX, minY)
            }
            let og = bboxOrigin(g), ot = bboxOrigin(t)
            for y in 0..<mt.h { for x in 0..<mt.w {
                let tx = x + ot.0, ty = y + ot.1, gx = x + og.0 + bestShift.0, gy = y + og.1 + bestShift.1
                guard gx >= 0, gy >= 0, gx < g.w, gy < g.h else { continue }
                let ti = (ty * t.w + tx) * 4, gi = (gy * g.w + gx) * 4
                guard t.px[ti + 3] > 250, g.px[gi + 3] > 250 else { continue }
                for c in 0..<3 { colorErr += abs(Double(t.px[ti + c]) - Double(g.px[gi + c])) / 255 }
                n += 3
            } }
            if name == "color" { print(String(format: "     color: mean abs RGB error %.3f over %d opaque pixels", n > 0 ? colorErr / Double(n) : -1, n / 3)) }
            let monoOK = (name == "star") == (IconCache.shared.cached(item)?.mono ?? false)
            print(String(format: "%@ %-6@ IoU %.3f (glyph %dx%d px vs truth %dx%d px, shift %d,%d)  mono=%@ expected=%@",
                         best >= 0.95 && monoOK ? "PASS" : "FAIL", name as NSString, best, mg.w, mg.h, mt.w, mt.h, bestShift.0, bestShift.1,
                         (IconCache.shared.cached(item)?.mono ?? false) ? "yes" : "no", name == "star" ? "yes" : "no"))
            if best < 0.95 || !monoOK { pass = false }
        }
        print(pass ? "RESULT matte PASS" : "RESULT matte FAIL")
    }

    /// Korean input: 2-set key sequences must compose into the right syllables, and search must find
    /// items by syllables, typed jamo and initial consonants. Keys are given as the Latin keys typed
    /// with the Korean 2-set layout; expected results as Unicode escapes.
    static func hangulTest() {
        func jamo(_ keys: String) -> [String] { keys.map { Hangul.dubeolsik[$0] ?? String($0) } }
        let compose: [(String, String)] = [
            ("qoxjfl", "\u{BC30}\u{D130}\u{B9AC}"),          // battery
            ("zkzkdhxhr", "\u{CE74}\u{CE74}\u{C624}\u{D1A1}"), // kakaotalk
            ("ekfr", "\u{B2ED}"), ("ekfrl", "\u{B2EC}\u{AE30}"),   // compound final, then split by a vowel
            ("rhk", "\u{ACFC}"), ("dmlwk", "\u{C758}\u{C790}"),    // compound vowels
            ("dkssud", "\u{C548}\u{B155}"), ("Qkd", "\u{BE75}"), ("abc", "\u{BBBB}"),
            ("zzd", "\u{314B}\u{314B}\u{3147}")]                 // lone consonants stay jamo
        var ok = 0
        for (keys, want) in compose {
            let got = Hangul.compose(jamo(keys))
            if got == want { ok += 1 } else { print("FAIL compose \(keys): got \(got), want \(want)") }
        }
        let name = "\u{CE74}\u{CE74}\u{C624}\u{D1A1}"            // kakaotalk
        let match: [(String, String, Bool)] = [
            (name, String(jamo("zzdx").joined()), true),             // initial consonants
            (name, String(jamo("zkz").joined()), true),              // typed jamo mid-composition
            (name, Hangul.compose(jamo("zkzk")), true),              // composed syllables
            (name, String(jamo("qx").joined()), false),
            ("Weather", "weath", true), ("Weather", String(jamo("zz").joined()), false)]
        var mok = 0
        for (text, q, want) in match {
            if Hangul.matches(text, q) == want { mok += 1 } else { print("FAIL match \(q) in \(text)") }
        }
        print("compose \(ok)/\(compose.count) · search \(mok)/\(match.count)")
        print(ok == compose.count && mok == match.count ? "RESULT PASS" : "RESULT FAIL")
    }

    static func run(_ args: [String]) {
        if args.contains("--hangul-test") { hangulTest(); return }
        if args.contains("--matte-test") { matteTest(args); return }
        print("Accessibility trusted:", AXIsProcessTrusted(), " Screen capture:", IconCache.canCapture)
        var times: [Double] = []
        var items: [MenuExtra] = []
        // Judge "hidden" against the notched built-in display — the screen All Menus exists for.
        let view = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }).map(MenuExtras.cgBounds)
        for _ in 0..<5 { let t = Date(); items = MenuExtras.enumerate(viewDisplay: view); times.append(Date().timeIntervalSince(t) * 1000) }
        times.sort()
        print(String(format: "enumerate: %d items, median %.1f ms (max %.1f ms)", items.count, times[2], times[4]))
        print(String(repeating: "-", count: 96))
        for i in items {
            let icon = IconCache.shared.cached(i) != nil ? "captured" : (i.captureRect != nil ? "capturable" : "fallback")
            print(String(format: "%-40@ %@  x=%6.0f  icon=%@", i.displayName as NSString, i.hiddenHere ? "HIDDEN on built-in " : "visible on built-in", i.frame.minX, icon))
        }
        guard args.contains("--selftest") else { return }

        let filters = args.drop { $0 != "--selftest" }.dropFirst().filter { !$0.hasPrefix("--") }.map { $0.lowercased() }
        let targets = filters.isEmpty ? items : items.filter { i in filters.contains { i.displayName.lowercased().contains($0) } }
        print(String(repeating: "-", count: 96))
        var opened = 0, openedHidden = 0, hiddenTotal = 0
        var lat: [Double] = []
        for item in targets {
            if item.hiddenHere { hiddenTotal += 1 }
            let before = onScreen()
            let t0 = Date()
            MenuExtras.press(item)
            var appeared: Win? = nil
            while Date().timeIntervalSince(t0) < 1.5 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))  // lets the click-fallback timer run
                let new = onScreen().subtracting(before).filter { ($0.layer != 25 || $0.frame.height > 50) && $0.frame.height > 20 && $0.frame.width > 20 }
                if args.contains("--verbose"), !new.isEmpty { print("   new:", new.map { "\($0.owner) L\($0.layer) x=\(Int($0.frame.minX))" }) }
                // Strict: the window must belong to the item's own app (system items: Control Center / Notification Center).
                if let w = new.first(where: { $0.owner == item.appName || (item.isSystem && ["제어 센터", "Control Center", "알림 센터", "Notification Center"].contains($0.owner)) }) {  // ko-data
                    appeared = w; break
                }
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            if let w = appeared {
                opened += 1; if item.hiddenHere { openedHidden += 1 }; lat.append(ms)
                print(String(format: "OPEN  %-40@ %4.0f ms  menu at x=%.0f y=%.0f (%@, layer %d)%@", item.displayName as NSString, ms,
                             w.frame.minX, w.frame.minY, w.owner, w.layer, item.hiddenHere ? "  [hidden on built-in]" : ""))
            } else {
                print(String(format: "FAIL  %-40@ nothing appeared within 1.5 s%@", item.displayName as NSString, item.hiddenHere ? "  [hidden on built-in]" : ""))
            }
            // Close whatever opened and wait until the screen is back to how it was.
            // Esc only when something opened, so a stray key never reaches the user's frontmost app.
            if appeared != nil { key(53) }
            let tc = Date()
            while Date().timeIntervalSince(tc) < 1.0 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                if onScreen().subtracting(before).filter({ ($0.layer != 25 || $0.frame.height > 50) && $0.frame.height > 20 }).isEmpty { break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        lat.sort()
        let med = lat.isEmpty ? 0 : lat[lat.count / 2]
        print(String(repeating: "-", count: 96))
        print(String(format: "RESULT opened %d/%d items (hidden: %d/%d), median time-to-menu %.0f ms",
                     opened, targets.count, openedHidden, hiddenTotal, med))
    }
}
