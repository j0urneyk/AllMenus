import Cocoa
import SwiftUI
import ScreenCaptureKit
import CoreMedia
import UniformTypeIdentifiers

/// Records the shelf opening, moving its selection and closing, for the README. Only the shelf's own
/// window is captured (never the desktop behind it), with demo items, and each frame is laid over a
/// drawn backdrop. Writes an animated GIF.
final class DemoRecorder: NSObject, SCStreamOutput {
    private let shelf: ShelfController
    private let out: String
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "allmenus.recorder")
    private let lock = NSLock()
    private var frames: [(CFTimeInterval, CGImage)] = []
    private var recording = false
    private let ci = CIContext()

    init(shelf: ShelfController, out: String) { self.shelf = shelf; self.out = out }

    private var savedLayout: ShelfLayout = .grid

    func run() {
        DemoContent.enabled = true
        // Record the grid (restored afterwards: the setting is persisted).
        savedLayout = Settings.shared.layout
        Settings.shared.layout = .grid
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens[0]
        shelf.forcedScreen = screen
        shelf.holdMorphForRecording = true
        shelf.show(byHover: true)          // closed, notch-sized shelf on screen; nothing moves yet
        shelf.keepOpenForTest()
        let windowID = CGWindowID(shelf.windowNumber)
        let size = shelf.windowFrame.size
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                  let win = content.windows.first(where: { $0.windowID == windowID }) else { print("shelf window not found"); exit(1) }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(size.width * 2); cfg.height = Int(size.height * 2)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.backgroundColor = .clear
            cfg.showsCursor = false
            cfg.queueDepth = 8
            let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg, delegate: nil)
            try? s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try? await s.startCapture()
            stream = s
            let notch = await MainActor.run { NotchTrigger.notchRect(on: screen)?.size ?? CGSize(width: 185, height: 32) }
            await MainActor.run { self.script(size: size, notch: notch) }
        }
    }

    private func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

    /// open → glide the selection across a few items → close.
    private func script(size: CGSize, notch: CGSize) {
        lock.lock(); recording = true; lock.unlock()
        let t0 = CACurrentMediaTime()
        if ProcessInfo.processInfo.environment["AM_REC_DEBUG"] != nil { print("script starts at", t0) }
        after(0.25) { self.shelf.pendingMorph?() }
        let model = shelf.model
        for (k, t) in [1.25, 1.55, 1.85, 2.15, 2.45].enumerated() {
            after(t) { let f = model.flat; if f.count > k + 1 { model.selectedID = f[k + 1].id } }
        }
        after(3.0) { self.shelf.close(animated: true) }
        after(3.7) {
            self.lock.lock(); self.recording = false; self.lock.unlock()
            Task { try? await self.stream?.stopCapture(); await MainActor.run { self.write(size: size, notch: notch) } }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, raw == SCFrameStatus.complete.rawValue,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let img = CIImage(cvPixelBuffer: pb)
        guard let cg = ci.createCGImage(img, from: img.extent) else { return }
        lock.lock(); if recording { frames.append((CACurrentMediaTime(), cg)) }; lock.unlock()
    }

    /// Lays each frame over the drawn backdrop and writes a GIF at 30 fps (holding frames where the
    /// screen didn't change, since the capture only delivers changes).
    @MainActor private func write(size: CGSize, notch: CGSize) {
        lock.lock(); let fs = frames; lock.unlock()
        guard let first = fs.first, let last = fs.last else { print("no frames"); exit(1) }
        if ProcessInfo.processInfo.environment["AM_REC_DEBUG"] != nil {
            print("capture span \(String(format: "%.2f", last.0 - first.0)) s, frame times:",
                  fs.map { String(format: "%.2f", $0.0 - first.0) }.joined(separator: " "))
        }
        Settings.shared.layout = savedLayout
        // A canvas wider than the shelf window, so the drawn menu bar has room; the shelf is centered
        // on the drawn notch.
        let scale: CGFloat = 1.5
        let canvas = CGSize(width: max(size.width + 260, 860), height: size.height)
        let W = Int(canvas.width * scale), H = Int(canvas.height * scale)
        let shelfRect = CGRect(x: (canvas.width - size.width) / 2 * scale, y: 0, width: size.width * scale, height: size.height * scale)
        let renderer = ImageRenderer(content: DemoBackdrop(notch: notch).frame(width: canvas.width, height: canvas.height))
        renderer.scale = scale
        guard let backdrop = renderer.cgImage else { exit(1) }
        let start = first.0 - 0.25, end = last.0 + 0.4
        let fps = 30.0
        let count = Int((end - start) * fps)
        let url = URL(fileURLWithPath: out)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else { exit(1) }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var j = 0
        for n in 0..<count {
            let t = start + Double(n) / fps
            while j + 1 < fs.count && fs[j + 1].0 <= t { j += 1 }
            let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(backdrop, in: CGRect(x: 0, y: 0, width: W, height: H))
            if fs[j].0 <= t { ctx.draw(fs[j].1, in: shelfRect) }
            guard let frame = ctx.makeImage() else { continue }
            CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
        print("wrote \(count) frames (\(fs.count) captured) to \(out)")
        exit(0)
    }
}
