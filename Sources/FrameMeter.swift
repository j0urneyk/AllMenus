import Cocoa
import ScreenCaptureKit
import CoreMedia

/// Outside judge for smoothness: records when the screen *actually* changed, via a ScreenCaptureKit
/// stream asking for up to 120 fps. The stream delivers a "complete" frame only when the captured
/// region changed, so frames counted during an animation = frames really drawn on screen.
final class FrameMeter: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "framemeter")
    private let lock = NSLock()
    private var times: [CFTimeInterval] = []
    private(set) var refreshRate = 0

    func start(region: CGRect, screen: NSScreen, ready: @escaping () -> Void) {
        refreshRate = screen.maximumFramesPerSecond
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let d = content.displays.first(where: { CGDisplayBounds($0.displayID).intersects(region) }) else { return }
            let db = CGDisplayBounds(d.displayID)
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = region.offsetBy(dx: -db.minX, dy: -db.minY)
            cfg.width = Int(region.width); cfg.height = Int(region.height)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            cfg.queueDepth = 8
            cfg.showsCursor = false
            let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg, delegate: nil)
            try? s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try? await s.startCapture()
            self.stream = s
            DispatchQueue.main.async(execute: ready)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, raw == SCFrameStatus.complete.rawValue else { return }
        let t = CACurrentMediaTime()
        lock.lock(); times.append(t); lock.unlock()
    }

    func stop() { Task { try? await stream?.stopCapture() } }

    /// Frames that landed in [from, to], with the effective rate and the longest gap between frames.
    func report(_ name: String, from: CFTimeInterval, to: CFTimeInterval) -> String {
        lock.lock(); let ts = times.filter { $0 >= from && $0 <= to }; lock.unlock()
        let dur = to - from
        guard ts.count > 1 else { return String(format: "%-28@ %3d frames in %.0f ms", name as NSString, ts.count, dur * 1000) }
        var gaps: [Double] = []
        for i in 1..<ts.count { gaps.append((ts[i] - ts[i - 1]) * 1000) }
        let span = ts.last! - ts.first!
        let fps = Double(ts.count - 1) / span
        let budget = 1000.0 / Double(max(refreshRate, 1))
        let late = gaps.filter { $0 > budget * 1.5 }.count
        // Where the hitches happen, as offsets from the start of the window.
        var where_: [String] = []
        for i in 1..<ts.count where (ts[i] - ts[i - 1]) * 1000 > budget * 1.5 {
            where_.append(String(format: "%.0f–%.0f ms", (ts[i - 1] - from) * 1000, (ts[i] - from) * 1000))
        }
        gaps.sort()
        let detail = where_.isEmpty ? "" : "  [hitches at " + where_.joined(separator: ", ") + "]"
        return detail.isEmpty ? String(format: "%-28@ %3d frames · %5.1f fps while moving · median gap %.1f ms · worst gap %.1f ms · gaps over 1.5 frames: %d",
                      name as NSString, ts.count, fps, gaps[gaps.count / 2], gaps.last!, late)
            : String(format: "%-28@ %3d frames · %5.1f fps while moving · worst gap %.1f ms · gaps over 1.5 frames: %d%@",
                     name as NSString, ts.count, fps, gaps.last!, late, detail)
    }
}
