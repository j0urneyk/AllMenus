import SwiftUI

final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: OnboardingView { [weak self] in self?.finish() })
            w.setContentSize(NSSize(width: 560, height: 480))
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func finish() {
        Settings.shared.onboardingDone = true
        window?.close()
    }
}

/// A little animated picture of the idea: the shelf growing out of the notch.
struct NotchIllustration: View {
    var cursor = false
    @State private var open = false
    @State private var cursorAtNotch = false

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.33, green: 0.4, blue: 0.98), Color(red: 0.66, green: 0.34, blue: 0.92)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: 7) {
                ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.75)).frame(width: 12, height: 4) }
                Spacer()
                ForEach(0..<5) { _ in Circle().fill(.white.opacity(0.85)).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 14).frame(height: 16)
            .background(Rectangle().fill(.white.opacity(0.18)))
            NotchShape(topRadius: open ? 8 : 4, bottomRadius: open ? 16 : 7)
                .fill(.black)
                .frame(width: open ? 210 : 62, height: open ? 96 : 16)
                .overlay(alignment: .top) {
                    VStack(spacing: 6) {
                        ForEach(0..<2) { r in
                            HStack(spacing: 6) {
                                ForEach(0..<6) { c in
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(.white.opacity(0.16))
                                        .frame(width: 20, height: 18)
                                        .overlay(Circle().fill(.white.opacity(0.85)).frame(width: 7, height: 7))
                                        .overlay(alignment: .topTrailing) {
                                            if r == 0 && c < 2 { Circle().fill(.orange).frame(width: 4, height: 4).padding(2) }
                                        }
                                }
                            }
                        }
                    }
                    .padding(.top, 24)
                    .opacity(open ? 1 : 0)
                }
            if cursor {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .offset(x: cursorAtNotch ? 4 : 90, y: cursorAtNotch ? 2 : 110)
            }
        }
        .frame(width: 300, height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .onAppear(perform: loop)
    }

    private func loop() {
        let go = {
            withAnimation(.easeInOut(duration: 0.7)) { cursorAtNotch = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + (cursor ? 0.75 : 0.2)) {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { open = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { open = false }
                withAnimation(.easeInOut(duration: 0.6)) { cursorAtNotch = false }
            }
        }
        go()
        Timer.scheduledTimer(withTimeInterval: 3.6, repeats: true) { _ in go() }
    }
}

struct OnboardingView: View {
    let done: () -> Void
    @State private var step = Int(ProcessInfo.processInfo.environment["ALLMENUS_ONBOARDING_STEP"] ?? "0") ?? 0
    @State private var ax = Permissions.accessibility
    @State private var sc = Permissions.screenCapture
    @State private var askedScreen = false
    @State private var tried = false
    @ObservedObject private var settings = Settings.shared
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome
                case 1: accessibility
                case 2: screen
                default: tryIt
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 34)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule().fill(i == step ? Color.accentColor : Color.primary.opacity(0.15))
                            .frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                .animation(.spring(response: 0.3), value: step)
                Spacer()
                if step > 0 {
                    Button(L("Back")) { go(step - 1) }.buttonStyle(.borderless)
                }
                primaryButton
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(.bar)
        }
        .frame(width: 560, height: 480)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.07), .clear], startPoint: .top, endPoint: .center))
        .onReceive(timer) { _ in
            let nowAx = Permissions.accessibility
            if nowAx && !ax && step == 1 {
                ax = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { if step == 1 { go(2) } }
            } else { ax = nowAx }
            sc = Permissions.screenCapture
        }
        .onReceive(NotificationCenter.default.publisher(for: .shelfDidOpen)) { _ in
            if step == 3 { withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { tried = true } }
        }
    }

    private func go(_ s: Int) { withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { step = s } }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case 0:
            Button(L("Get Started")) { go(1) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
        case 1:
            if ax {
                Button(L("Next")) { go(2) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button(L("Open System Settings")) { Permissions.openAccessibility() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
            }
        case 2:
            HStack {
                if !sc { Button(L("Skip")) { go(3) }.buttonStyle(.borderless) }
                if sc {
                    Button(L("Next")) { go(3) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
                } else if askedScreen {
                    Button(L("Restart to Apply")) { Permissions.relaunch() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button(L("Allow")) { askedScreen = true; Permissions.requestScreenCapture() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        default:
            Button(tried ? L("Done") : L("Skip and Finish")) { done() }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    // MARK: steps

    private var welcome: some View {
        VStack(spacing: 18) {
            NotchIllustration()
            VStack(spacing: 8) {
                Text(L("A full menu bar is fine")).font(.system(size: 24, weight: .bold, design: .rounded))
                Text(L("All Menus gathers every menu bar icon in one place, even the ones hidden behind the notch, and opens each app's own menu when you click it."))
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(3)
            }
            Text(L("It needs just one permission to get started.")).font(.callout).foregroundStyle(.tertiary)
        }
    }

    private func hero(_ symbol: String, _ tint: Color, granted: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(tint.gradient)
                .frame(width: 76, height: 76)
                .overlay(Image(systemName: symbol).font(.system(size: 36, weight: .semibold)).foregroundStyle(.white))
                .shadow(color: tint.opacity(0.35), radius: 12, y: 6)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26)).foregroundStyle(.white, .green)
                    .background(Circle().fill(.white).frame(width: 22, height: 22))
                    .offset(x: 8, y: 8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.55), value: granted)
    }

    private func statusPill(_ granted: Bool, waiting: String) -> some View {
        HStack(spacing: 6) {
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L("Permission granted"))
            } else {
                ProgressView().controlSize(.small)
                Text(waiting)
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(granted ? Color.green.opacity(0.12) : Color.primary.opacity(0.06)))
    }

    private func howTo(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1)").font(.system(size: 11, weight: .bold, design: .rounded))
                        .frame(width: 18, height: 18).background(Circle().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                    Text(l).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var accessibility: some View {
        VStack(spacing: 16) {
            hero("accessibility", .blue, granted: ax)
            VStack(spacing: 6) {
                Text(L("Allow Accessibility access")).font(.system(size: 20, weight: .bold, design: .rounded))
                Text(L("Needed to read the menu bar icons and to open their menus."))
                    .foregroundStyle(.secondary)
            }
            statusPill(ax, waiting: L("Waiting for permission… continues as soon as it's on"))
            if !ax {
                howTo([L("Click “Open System Settings” below."),
                       L("Turn on All Menus in the Accessibility list."),
                       L("Already on but nothing happens? Select All Menus in the list, remove it with −, then add it again with +.")])
            }
        }
    }

    private var screen: some View {
        VStack(spacing: 16) {
            hero("rectangle.dashed.badge.record", .purple, granted: sc)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(L("Show the real icons too?")).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(L("Optional")).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Text(L("With Screen Recording, All Menus shows icons exactly as they look in the menu bar.\nNothing on your screen is saved or sent anywhere."))
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(2)
            }
            HStack(spacing: 22) {
                compare(title: L("Without it"), sub: L("App icons instead"), real: false)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                compare(title: L("With it"), sub: L("Real menu bar icons"), real: true)
            }
            if sc {
                statusPill(true, waiting: "")
            } else if askedScreen {
                Text(L("Turn it on in Settings, then click “Restart to Apply”. macOS applies this permission only after a restart."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func compare(title: String, sub: String, real: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach(["wifi", "battery.75", "speaker.wave.2"], id: \.self) { s in
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black)
                        .frame(width: 30, height: 28)
                        .overlay {
                            if real { Image(systemName: s).font(.system(size: 12)).foregroundStyle(.white) }
                            else { Image(systemName: "app.fill").font(.system(size: 13)).foregroundStyle(.gray) }
                        }
                }
            }
            Text(title).font(.caption.weight(.semibold))
            Text(sub).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var tryIt: some View {
        VStack(spacing: 18) {
            NotchIllustration(cursor: true)
            VStack(spacing: 6) {
                Text(tried ? L("Perfect! 🎉") : L("Now move the pointer to the notch"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .contentTransition(.opacity)
                Text(tried ? L("Open it anytime from the notch or with %@. Settings are under ⚙︎ in the shelf.", settings.hotkey.display)
                           : L("Or press %@.", settings.hotkey.display))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if tried {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
}
