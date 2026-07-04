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

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }
}
