import Foundation
import ScreenCaptureKit
import CoreMedia

/// Screen capture via ScreenCaptureKit at native resolution and up to 60 fps.
/// The annotation overlay window is excluded from capture so the remote side
/// doesn't see its own strokes echoed back.
final class ScreenShareCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "pairwise.screen", qos: .userInteractive)
    var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?
    var onStopped: (() -> Void)?

    /// Window IDs to exclude from capture (annotation overlay).
    var excludedWindowIDs: Set<CGWindowID> = []

    private(set) var capturedSize: CGSize = .zero

    func start(completion: @escaping (Bool) -> Void) {
        Task {
            do {
                // The overlay windows to exclude were ordered front only
                // moments ago, and SCShareableContent snapshots can lag the
                // window server — if we start before they're listed, the
                // viewer sees the sharer's own indicator marks and strokes.
                // Retry briefly until every excluded window is enumerable.
                var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                var attempts = 0
                while attempts < 10,
                      !self.excludedWindowIDs.isSubset(of: Set(content.windows.map(\.windowID))) {
                    attempts += 1
                    try await Task.sleep(nanoseconds: 100_000_000)
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                }
                guard let display = content.displays.first else {
                    await MainActor.run { completion(false) }
                    return
                }
                let excluded = content.windows.filter { self.excludedWindowIDs.contains($0.windowID) }
                if excluded.count != self.excludedWindowIDs.count {
                    PWLog("screen share: only \(excluded.count)/\(self.excludedWindowIDs.count) overlay windows excludable after \(attempts) retries")
                }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)

                let config = SCStreamConfiguration()
                // Native pixel resolution, downscaled proportionally to the
                // user's chosen long-side cap (0 = native) and the encoder's
                // hard ceiling.
                let pxScale = filter.pointPixelScale > 0 ? Double(filter.pointPixelScale) : 2.0
                var w = Double(display.width) * pxScale
                var h = Double(display.height) * pxScale
                let cap = DeviceSettings.screenShareMaxDimension
                let limit = cap > 0 ? Double(min(cap, 3840)) : 3840.0
                if max(w, h) > limit {
                    let s = limit / max(w, h)
                    w *= s
                    h *= s
                }
                config.width = Int(w) & ~1
                config.height = Int(h) & ~1
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                config.queueDepth = 5
                config.showsCursor = true
                self.capturedSize = CGSize(width: config.width, height: config.height)

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                self.stream = stream
                await MainActor.run { completion(true) }
            } catch {
                PWLog("screen capture failed: \(error)")
                await MainActor.run { completion(false) }
            }
        }
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Skip frames where nothing changed? SCK only delivers on change already
        // when minimumFrameInterval allows, so forward everything.
        onPixelBuffer?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        PWLog("screen stream stopped: \(error)")
        self.stream = nil
        DispatchQueue.main.async { self.onStopped?() }
    }
}
