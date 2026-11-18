import Cocoa
import Carbon.HIToolbox

/// A global shortcut in Carbon terms (what RegisterEventHotKey wants).
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = KeyCombo(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: UInt32(controlKey | optionKey))

    var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyCombo.keyName(UInt16(keyCode))
    }

    static func carbon(from f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static func keyName(_ code: UInt16) -> String {
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Tab: "⇥", kVK_Delete: "⌫",
                                      kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                      kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                      kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let s = special[Int(code)] { return s }
        // Name the key by the current ASCII-capable layout (so it reads "M", not the Hangul jamo on that key).
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "?" }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var len = 0
            UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
            return String(utf16CodeUnits: chars, count: len).uppercased()
        }
    }
}

enum PanelStyle: String, CaseIterable, Identifiable {
    case notch, glass
    var id: String { rawValue }
    var title: String { self == .notch ? L("Out of the Notch") : L("Liquid Glass") }
    var subtitle: String { self == .notch ? L("A black shelf flows out of the notch") : L("A translucent glass panel below the menu bar") }
}

enum IconStyle: String, CaseIterable, Identifiable {
    case original, monochrome
    var id: String { rawValue }
}

enum ShelfLayout: String, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
    var title: String { self == .grid ? L("Grid") : L("List") }
}

enum AnimationMode: String, CaseIterable, Identifiable {
    case full, reduced, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full: L("Full")
        case .reduced: L("Simple")
        case .off: L("Off")
        }
    }
}

enum PanelPlacement: String, CaseIterable, Identifiable {
    case notch, mouse
    var id: String { rawValue }
}

/// User preferences, persisted in UserDefaults and observed live by every window.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var hoverToOpen: Bool { didSet { d.set(hoverToOpen, forKey: "hoverToOpen") } }
    @Published var clickNotchToOpen: Bool { didSet { d.set(clickNotchToOpen, forKey: "clickNotchToOpen") } }
    @Published var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var closeOnMouseExit: Bool { didSet { d.set(closeOnMouseExit, forKey: "closeOnMouseExit") } }
    @Published var placement: PanelPlacement { didSet { d.set(placement.rawValue, forKey: "placement") } }
    @Published var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    @Published var hotkey: KeyCombo { didSet { d.set(try? JSONEncoder().encode(hotkey), forKey: "hotkey") } }
    @Published var panelStyle: PanelStyle { didSet { d.set(panelStyle.rawValue, forKey: "panelStyle") } }
    @Published var iconStyle: IconStyle { didSet { d.set(iconStyle.rawValue, forKey: "iconStyle") } }
    @Published var showLabels: Bool { didSet { d.set(showLabels, forKey: "showLabels") } }
    @Published var groupHidden: Bool { didSet { d.set(groupHidden, forKey: "groupHidden") } }
    @Published var flyToMenuBar: Bool { didSet { d.set(flyToMenuBar, forKey: "flyToMenuBar") } }
    @Published var animation: AnimationMode { didSet { d.set(animation.rawValue, forKey: "animation") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    @Published var layout: ShelfLayout { didSet { d.set(layout.rawValue, forKey: "layout") } }

    /// A light tap on Force Touch trackpads (silently does nothing elsewhere).
    func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// What actually plays: Full steps down to Simple when macOS Reduce Motion is on.
    var effectiveAnimation: AnimationMode {
        if animation == .full && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .reduced }
        return animation
    }
    @Published var hiddenKeys: [String] { didSet { d.set(hiddenKeys, forKey: "hiddenKeys") } }
    @Published var pinnedKeys: [String] { didSet { d.set(pinnedKeys, forKey: "pinnedKeys") } }
    @Published var order: [String] { didSet { d.set(order, forKey: "order") } }
    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }

    /// The app's identifier before it was renamed to All Menus.
    static let previousBundleID = "local.menushelf"

    /// Preferences live under the bundle identifier, which changed from `local.menushelf` to
    /// `local.allmenus`; carry the old ones over once so the rename keeps the user's settings.
    private static func migratePreviousPreferences(_ d: UserDefaults) {
        guard let current = Bundle.main.bundleIdentifier, current != previousBundleID,
              d.persistentDomain(forName: current)?.isEmpty ?? true,
              let old = d.persistentDomain(forName: previousBundleID), !old.isEmpty else { return }
        for (key, value) in old { d.set(value, forKey: key) }
        d.removePersistentDomain(forName: previousBundleID)
    }

    private init() {
        Settings.migratePreviousPreferences(d)
        d.register(defaults: ["hoverToOpen": true, "clickNotchToOpen": true, "hoverDelay": 0.1, "closeOnMouseExit": true,
                              "placement": "notch", "hotkeyEnabled": true, "panelStyle": "notch", "iconStyle": "original",
                              "showLabels": false, "groupHidden": true, "flyToMenuBar": true, "animation": "full", "haptics": true, "layout": "grid", "onboardingDone": false])
        hoverToOpen = d.bool(forKey: "hoverToOpen")
        clickNotchToOpen = d.bool(forKey: "clickNotchToOpen")
        hoverDelay = d.double(forKey: "hoverDelay")
        closeOnMouseExit = d.bool(forKey: "closeOnMouseExit")
        placement = PanelPlacement(rawValue: d.string(forKey: "placement") ?? "") ?? .notch
        hotkeyEnabled = d.bool(forKey: "hotkeyEnabled")
        hotkey = (d.data(forKey: "hotkey")).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .default
        panelStyle = PanelStyle(rawValue: d.string(forKey: "panelStyle") ?? "") ?? .notch
        iconStyle = IconStyle(rawValue: d.string(forKey: "iconStyle") ?? "") ?? .original
        showLabels = d.bool(forKey: "showLabels")
        groupHidden = d.bool(forKey: "groupHidden")
        flyToMenuBar = d.bool(forKey: "flyToMenuBar")
        animation = AnimationMode(rawValue: d.string(forKey: "animation") ?? "") ?? .full
        haptics = d.bool(forKey: "haptics")
        layout = ShelfLayout(rawValue: d.string(forKey: "layout") ?? "") ?? .grid
        hiddenKeys = d.stringArray(forKey: "hiddenKeys") ?? []
        pinnedKeys = d.stringArray(forKey: "pinnedKeys") ?? []
        order = d.stringArray(forKey: "order") ?? []
        onboardingDone = d.bool(forKey: "onboardingDone")
    }

    /// Items in the user's order; anything not ordered yet keeps its menu bar position, after the ordered ones.
    func ordered(_ items: [MenuExtra]) -> [MenuExtra] {
        guard !order.isEmpty else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated().sorted { a, b in
            let ra = rank[a.element.cacheKey] ?? Int.max, rb = rank[b.element.cacheKey] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    func togglePinned(_ key: String) {
        if let i = pinnedKeys.firstIndex(of: key) { pinnedKeys.remove(at: i) } else { pinnedKeys.append(key) }
    }

    func setHidden(_ key: String, _ hidden: Bool) {
        hiddenKeys.removeAll { $0 == key }
        if hidden { hiddenKeys.append(key) }
    }
}

/// Korean search: matches by the full jamo sequence and by initial consonants (choseong), so both
/// the first syllables of an app name and just their initial consonants find it.
enum Hangul {
    static let cho = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ").map(String.init)  // ko-data
    static let jung = ["ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅗㅏ", "ㅗㅐ", "ㅗㅣ", "ㅛ", "ㅜ", "ㅜㅓ", "ㅜㅔ", "ㅜㅣ", "ㅠ", "ㅡ", "ㅡㅣ", "ㅣ"]  // ko-data
    static let jong = ["", "ㄱ", "ㄲ", "ㄱㅅ", "ㄴ", "ㄴㅈ", "ㄴㅎ", "ㄷ", "ㄹ", "ㄹㄱ", "ㄹㅁ", "ㄹㅂ", "ㄹㅅ", "ㄹㅌ", "ㄹㅍ", "ㄹㅎ",  // ko-data
                       "ㅁ", "ㅂ", "ㅂㅅ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]  // ko-data
    static let compound: [String: String] = ["ㅘ": "ㅗㅏ", "ㅙ": "ㅗㅐ", "ㅚ": "ㅗㅣ", "ㅝ": "ㅜㅓ", "ㅞ": "ㅜㅔ", "ㅟ": "ㅜㅣ", "ㅢ": "ㅡㅣ",  // ko-data
                                             "ㄳ": "ㄱㅅ", "ㄵ": "ㄴㅈ", "ㄶ": "ㄴㅎ", "ㄺ": "ㄹㄱ", "ㄻ": "ㄹㅁ", "ㄼ": "ㄹㅂ", "ㄽ": "ㄹㅅ",  // ko-data
                                             "ㄾ": "ㄹㅌ", "ㄿ": "ㄹㅍ", "ㅀ": "ㄹㅎ", "ㅄ": "ㅂㅅ"]  // ko-data

    static func decompose(_ s: String, initialsOnly: Bool) -> String {
        var out = ""
        for ch in s {
            guard let v = ch.unicodeScalars.first?.value, v >= 0xAC00, v <= 0xD7A3 else {
                out += compound[String(ch)] ?? String(ch); continue
            }
            let i = Int(v - 0xAC00)
            out += cho[i / 588]
            if !initialsOnly { out += jung[(i % 588) / 28] + jong[i % 28] }
        }
        return out
    }

    /// The panel takes raw key events (no input method), so with the Korean 2-set layout active
    /// typing "dk" arrives as Latin letters. Map them to the jamo the user meant.
    static let dubeolsik: [Character: String] = [
        "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ", "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",  // ko-data
        "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ", "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",  // ko-data
        "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ", "n": "ㅜ", "m": "ㅡ",  // ko-data
        "Q": "ㅃ", "W": "ㅉ", "E": "ㄸ", "R": "ㄲ", "T": "ㅆ", "O": "ㅒ", "P": "ㅖ"]  // ko-data

    static var koreanInputActive: Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return false }
        let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        return id.contains("Korean")
    }

    static func typed(_ chars: String) -> String {
        guard koreanInputActive else { return chars }
        return chars.map { ch in dubeolsik[ch] ?? (dubeolsik[Character(ch.lowercased())] ?? String(ch)) }.joined()
    }

    // MARK: Dubeolsik (2-set) composition (the panel gets raw keys, so it has to assemble syllables itself)

    static let choList = cho
    static let jungList = ["ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅘ", "ㅙ", "ㅚ", "ㅛ", "ㅜ", "ㅝ", "ㅞ", "ㅟ", "ㅠ", "ㅡ", "ㅢ", "ㅣ"]  // ko-data
    static let jongList = ["", "ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ", "ㄺ", "ㄻ", "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ", "ㅄ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]  // ko-data
    static let vowelPairs: [String: String] = ["ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ", "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ"]  // ko-data
    static let finalPairs: [String: String] = ["ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ",  // ko-data
                                              "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ"]  // ko-data

    static func isVowel(_ s: String) -> Bool { jungList.contains(s) }
    static func isConsonant(_ s: String) -> Bool { choList.contains(s) }

    /// Assembles typed jamo into syllables the way the Dubeolsik (2-set) input method does, including
    /// splitting a compound final when a vowel follows. Anything else passes through unchanged.
    static func compose(_ keys: [String]) -> String {
        var out = ""
        var c: String? = nil, v: String? = nil, f: String? = nil   // current syllable: initial, medial, final

        func syllable() -> String {
            guard let c, let v, let ci = choList.firstIndex(of: c), let vi = jungList.firstIndex(of: v) else {
                return (c ?? "") + (v ?? "") + (f ?? "")
            }
            let fi = jongList.firstIndex(of: f ?? "") ?? 0
            return String(UnicodeScalar(0xAC00 + (ci * 21 + vi) * 28 + fi)!)
        }
        func flush() { out += syllable(); c = nil; v = nil; f = nil }

        for k in keys {
            if isConsonant(k) {
                if c != nil && v != nil {
                    if f == nil && jongList.contains(k) { f = k; continue }               // tense consonants never end a syllable
                    if let ff = f, let pair = finalPairs[ff + k] { f = pair; continue }
                }
                flush(); c = k
            } else if isVowel(k) {
                if let cc = c, v == nil { _ = cc; v = k; continue }
                if c != nil, let vv = v, f == nil, let pair = vowelPairs[vv + k] { v = pair; continue }
                if c != nil, v != nil, let ff = f {
                    // The final consonant moves to the next syllable (a compound final splits: its second half moves).
                    var keep: String? = nil, move = ff
                    if let split = finalPairs.first(where: { $0.value == ff })?.key {
                        keep = String(split.first!); move = String(split.last!)
                    }
                    f = keep
                    flush(); c = move; v = k
                    continue
                }
                if c == nil, let vv = v, let pair = vowelPairs[vv + k] { v = pair; continue }
                flush(); v = k
            } else {
                flush(); out += k
            }
        }
        flush()
        return out
    }

    static func matches(_ text: String, _ query: String) -> Bool {
        let t = text.lowercased(), q = query.lowercased()
        if t.contains(q) { return true }
        let qj = decompose(q, initialsOnly: false)
        return decompose(t, initialsOnly: false).contains(qj) || decompose(t, initialsOnly: true).contains(qj)
    }
}
