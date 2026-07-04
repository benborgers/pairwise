import AppKit
import AVFoundation

/// NSView backed by AVSampleBufferDisplayLayer — hardware H.264 decode + display.
final class VideoDisplayView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    init(gravity: AVLayerVideoGravity) {
        super.init(frame: .zero)
        wantsLayer = true
        displayLayer.videoGravity = gravity
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = displayLayer
    }

    required init?(coder: NSCoder) { fatalError() }

    private let failCounter = PWCounter("display layer FAILED, flushing", every: 10)

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            failCounter.tick(displayLayer.error.map { "\($0)" } ?? "no error detail")
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }
}
