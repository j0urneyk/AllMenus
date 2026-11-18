import SwiftUI
import ServiceManagement

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shortcut, appearance, items, permissions, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: L("General")
        case .shortcut: L("Shortcut")
        case .appearance: L("Appearance")
        case .items: L("Items")
        case .permissions: L("Permissions")
        case .about: L("About")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcut: "command"
        case .appearance: "paintbrush.fill"
        case .items: "square.grid.2x2.fill"
        case .permissions: "lock.shield.fill"
        case .about: "info"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray
        case .shortcut: .indigo
        case .appearance: .pink
        case .items: .orange
        case .permissions: .blue
        case .about: .teal
        }
    }
}

final class SettingsNav: ObservableObject {
    @Published var pane: SettingsPane? = .general
}

final class SettingsWindow: NSObject {
    static let shared = SettingsWindow()
    let nav = SettingsNav()
    private var window: NSWindow?

    func show(pane: SettingsPane? = nil) {
        if let pane { nav.pane = pane }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = L("All Menus Settings")
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(nav: nav))
            w.setContentSize(NSSize(width: 720, height: 500))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 22
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(pane.tint.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: pane.symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
    }
}

struct SettingsView: View {
    @ObservedObject var nav: SettingsNav

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $nav.pane) { p in
                Label { Text(p.title) } icon: { PaneIcon(pane: p) }
                    .padding(.vertical, 2)
                    .tag(p)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            Group {
                switch nav.pane ?? .general {
                case .general: GeneralPane()
                case .shortcut: ShortcutPane()
                case .appearance: AppearancePane()
                case .items: ItemsPane()
                case .permissions: PermissionsPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle((nav.pane ?? .general).title)
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var s = Settings.shared
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section(L("Startup")) {
                Toggle(L("Open at login"), isOn: Binding(get: { login }, set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch { loginError = error.localizedDescription }
                    login = SMAppService.mainApp.status == .enabled
                }))
                if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Section(L("Opening")) {
                Toggle(L("Open when the pointer rests on the notch"), isOn: $s.hoverToOpen)
                if s.hoverToOpen {
                    LabeledContent(L("Delay")) {
                        HStack {
                            Slider(value: $s.hoverDelay, in: 0.0...0.6) { EmptyView() } minimumValueLabel: {
                                Text(L("Faster")).font(.caption2)
                            } maximumValueLabel: {
                                Text(L("Slower")).font(.caption2)
                            }
                            Text(L("%.2fs", s.hoverDelay)).monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                Toggle(L("Open when the notch is clicked"), isOn: $s.clickNotchToOpen)
                Toggle(isOn: $s.closeOnMouseExit) {
                    Text(L("Close when the pointer leaves the shelf"))
                    Text(L("Only when it was opened by resting on the notch."))
                }
            }
            Section(L("Position")) {
                Picker(L("Shelf position"), selection: $s.placement) {
                    Text(L("Below the notch (on screens with one)")).tag(PanelPlacement.notch)
                    Text(L("Where the pointer is")).tag(PanelPlacement.mouse)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcut

struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button { recording ? stop() : start() } label: {
            HStack(spacing: 6) {
                if recording { Circle().fill(Color.red).frame(width: 7, height: 7) }
                Text(recording ? L("Press a key combination…") : combo.display)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
            }
            .frame(minWidth: 150)
            .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKey.shared.register(nil)   // so the current shortcut can be pressed again
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }   // esc cancels
            let mods = KeyCombo.carbon(from: e.modifierFlags)
            guard mods & UInt32(cmdKeyMask | controlKeyMask | optionKeyMask) != 0 else { NSSound.beep(); return nil }
            combo = KeyCombo(keyCode: UInt32(e.keyCode), carbonModifiers: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        let s = Settings.shared
        HotKey.shared.register(s.hotkeyEnabled ? s.hotkey : nil)
    }
}

private let cmdKeyMask = 1 << 8, optionKeyMask = 1 << 11, controlKeyMask = 1 << 12

struct ShortcutPane: View {
    @ObservedObject var s = Settings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Open the shelf with a shortcut"), isOn: $s.hotkeyEnabled)
                LabeledContent(L("Shortcut")) {
                    HStack {
                        ShortcutRecorder(combo: $s.hotkey)
                        Button(L("Default")) { s.hotkey = .default }.disabled(s.hotkey == .default)
                    }
                }
                .disabled(!s.hotkeyEnabled)
            } footer: {
                Text(L("Click the shortcut button, then press the combination you want. It must include ⌘, ⌃ or ⌥. Press esc to cancel."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("In the shelf")) {
                LabeledContent(L("Move between items")) { Text("← → ↑ ↓") }
                LabeledContent(L("Open the menu")) { Text(L("⏎ or click")) }
                LabeledContent(L("Search")) { Text(L("Just start typing")) }
                LabeledContent(L("Clear search / close")) { Text("esc") }
                LabeledContent(L("Open settings")) { Text("⌘,") }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

struct StyleCard: View {
    let style: PanelStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.95), Color(red: 0.62, green: 0.36, blue: 0.9)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Rectangle().fill(.white.opacity(0.22)).frame(height: 9)
                    if style == .notch {
                        NotchShape(topRadius: 5, bottomRadius: 12)
                            .fill(.black)
                            .frame(width: 118, height: 62)
                            .overlay(tiles.padding(.top, 14).padding(.horizontal, 10), alignment: .top)
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.32))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
                            .frame(width: 112, height: 48)
                            .overlay(tiles.padding(8), alignment: .top)
                            .padding(.top, 14)
                    }
                }
                .frame(width: 190, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2.5 : 1))
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(style.title).font(.system(size: 12, weight: .semibold))
                        Text(style.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var tiles: some View {
        VStack(spacing: 4) {
            ForEach(0..<2) { r in
                HStack(spacing: 4) {
                    ForEach(0..<5) { c in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white.opacity(style == .notch ? 0.18 : 0.6))
                            .frame(width: 14, height: 11)
                            .overlay(alignment: .topTrailing) {
                                if r == 0 && c < 2 { Circle().fill(.orange).frame(width: 3, height: 3).padding(1) }
                            }
                    }
                }
            }
        }
    }
}

struct AppearancePane: View {
    @ObservedObject var s = Settings.shared
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        Form {
            Section(L("Shelf style")) {
                HStack(spacing: 18) {
                    ForEach(PanelStyle.allCases) { st in
                        StyleCard(style: st, selected: s.panelStyle == st) { s.panelStyle = st }
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
            Section(L("Layout")) {
                Picker(L("Arrangement"), selection: $s.layout) {
                    ForEach(ShelfLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section(L("Icons")) {
                Picker(L("Icon color"), selection: $s.iconStyle) {
                    Text(L("Original colors")).tag(IconStyle.original)
                    Text(L("Monochrome")).tag(IconStyle.monochrome)
                }
                .pickerStyle(.segmented)
                Toggle(L("Show names under icons (grid)"), isOn: $s.showLabels)
                    .disabled(s.layout == .list)
                Toggle(isOn: $s.groupHidden) {
                    Text(L("Group hidden items first"))
                    Text(L("Icons the notch keeps out of the menu bar get their own section at the top."))
                }
            }
            Section {
                Picker(L("Animation"), selection: $s.animation) {
                    ForEach(AnimationMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $s.flyToMenuBar) {
                    Text(L("Fly the icon to the menu bar when opening"))
                    Text(L("Menus open at the item's real spot in the menu bar. The clicked icon flies there to show where."))
                }
                .disabled(s.animation != .full || reduceMotion)
                Toggle(isOn: $s.haptics) {
                    Text(L("Trackpad haptics"))
                    Text(L("A very light tap on the trackpad when the shelf opens and when an icon lands. Only on Force Touch trackpads."))
                }
            } header: {
                Text(L("Motion"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Full: grows out of the notch and icons fly · Simple: a quick fade only · Off: opens and closes instantly"))
                    if reduceMotion && s.animation == .full {
                        Label(L("macOS “Reduce motion” is on, so Simple is used."), systemImage: "figure.walk.motion")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Items

struct ItemsPane: View {
    @ObservedObject var s = Settings.shared
    @State private var items: [MenuExtra] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Drag to reorder, ★ to pin to the front, and use the switch to hide an item from the shelf."))
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
            List {
                ForEach(s.ordered(items)) { item in row(item) }
                    .onMove { from, to in
                        var keys = s.ordered(items).map(\.cacheKey)
                        keys.move(fromOffsets: from, toOffset: to)
                        s.order = keys
                    }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Button(L("Reset to Menu Bar Order")) { s.order = []; s.pinnedKeys = []; s.hiddenKeys = [] }
                Spacer()
                Button { items = MenuExtras.enumerate() } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
            }
            .padding(14)
        }
        .onAppear { items = MenuExtras.enumerate() }
    }

    private func row(_ item: MenuExtra) -> some View {
        let key = item.cacheKey
        let pinned = s.pinnedKeys.contains(key)
        let shown = !s.hiddenKeys.contains(key)
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            IconView(icon: IconCache.shared.cached(item) ?? IconCache.fallback(item), forceMono: s.iconStyle == .monochrome, maxWidth: 64)
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.shortName).fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(item.shortName == item.appName ? (item.title.isEmpty ? item.detail : item.title) : item.appName)
                    if item.hiddenHere {
                        Text(L("· hidden in the menu bar")).foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .opacity(shown ? 1 : 0.45)
            Spacer()
            Button { s.togglePinned(key) } label: {
                Image(systemName: pinned ? "star.fill" : "star").foregroundStyle(pinned ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(pinned ? L("Unpin") : L("Pin to front"))
            Toggle("", isOn: Binding(get: { shown }, set: { s.setHidden(key, !$0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .help(L("Show in the shelf"))
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Permissions

struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let required: Bool
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold)
                    Text(required ? L("Required") : L("Optional"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill((required ? Color.red : Color.gray).opacity(0.15)))
                        .foregroundStyle(required ? .red : .secondary)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label(L("Allowed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout.weight(.medium))
            } else {
                Button(L("Allow"), action: action).buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}

struct PermissionsPane: View {
    @State private var ax = Permissions.accessibility
    @State private var sc = Permissions.screenCapture
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                PermissionRow(symbol: "accessibility", tint: .blue, title: L("Accessibility"),
                              detail: L("Needed to read the menu bar icons and to open their menus."),
                              required: true, granted: ax, action: Permissions.openAccessibility)
                PermissionRow(symbol: "rectangle.dashed.badge.record", tint: .purple, title: L("Screen Recording"),
                              detail: L("Used to show the real menu bar icons. Without it, app icons are shown instead. Nothing on screen is saved or sent."),
                              required: false, granted: sc, action: Permissions.requestScreenCapture)
            } footer: {
                Text(L("If it's on in the list but doesn't show as Allowed, go to System Settings → Privacy & Security → Accessibility, select All Menus, remove it with −, and add it again with +. When the app's signature changes, macOS treats the old entry as a different app."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(L("Show Permission Guide Again")) { OnboardingWindow.shared.show() }
                    Spacer()
                    if !sc {
                        Button(L("Restart All Menus")) { Permissions.relaunch() }
                            .help(L("Screen Recording takes effect after a restart"))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in ax = Permissions.accessibility; sc = Permissions.screenCapture }
    }
}

// MARK: - About

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("All Menus").font(.system(size: 22, weight: .bold, design: .rounded))
            Text(L("Version %@", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? L("development")))
                .foregroundStyle(.secondary)
            Text(L("Every menu bar icon in one place — even behind the notch.\nClick one to open that app's own menu."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
