import Cocoa
import ApplicationServices

enum Permissions {
    /// `--simulate-missing` lets the onboarding be previewed on a Mac that already granted everything.
    static let simulateMissing = CommandLine.arguments.contains("--simulate-missing")

    static var accessibility: Bool { !simulateMissing && AXIsProcessTrusted() }
    static var screenCapture: Bool { !simulateMissing && CGPreflightScreenCaptureAccess() }

    static func openAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func requestScreenCapture() {
        // The system prompt appears only the first time; after that, send the user to the right pane.
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// Screen capture permission only takes effect after a relaunch.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
