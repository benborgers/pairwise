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
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { completion(false) }
                    return
                }
                let excluded = content.windows.filter { self.excludedWindowIDs.contains($0.windowID) }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)

                let config = SCStreamConfiguration()
                // Native pixel resolution, capped to keep the encoder happy.
                let scale = display.width > 2560 ? 2560.0 / Double(display.width) : 1.0
                let pxScale = filter.pointPixelScale > 0 ? Double(filter.pointPixelScale) : 2.0
                let w = Int(Double(display.width) * pxScale * scale)
                let h = Int(Double(display.height) * pxScale * scale)
                config.width = min(w, 3840) & ~1
                config.height = min(h, 2160) & ~1
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
                NSLog("Pairwise: screen capture failed: \(error)")
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
        NSLog("Pairwise: screen stream stopped: \(error)")
        self.stream = nil
        DispatchQueue.main.async { self.onStopped?() }
    }
}
