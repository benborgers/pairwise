import Foundation
import AVFoundation
import CoreMedia

/// Camera capture → pixel buffers.
///
/// Device selection is explicit: virtual cameras (OBS et al.) register as
/// perfectly valid devices but deliver zero frames unless their host app is
/// streaming — so the built-in camera is tried first, and a watchdog swaps
/// to the next device if the current one produces nothing for 3 seconds.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "pairwise.camera", qos: .userInteractive)
    private let captureCounter = PWCounter("camera frames captured", every: 300)
    var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?

    private var candidates: [AVCaptureDevice] = []
    private var candidateIndex = 0
    private var generation = 0

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { PWLog("camera permission DENIED"); return }
            guard let self else { return }
            self.queue.async { self.configureAndRun() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1  // invalidate any pending watchdog
            if self.session.isRunning {
                self.session.stopRunning()
                PWLog("camera capture stopped")
            }
        }
    }

    private func discoverCandidates() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified)
        var devices = discovery.devices
        PWLog("cameras: \(devices.map { "\($0.localizedName) <\($0.deviceType.rawValue)>" }.joined(separator: "; "))")
        // Real hardware first; virtual cameras enumerate as .external.
        devices.sort {
            ($0.deviceType == .builtInWideAngleCamera ? 0 : 1) <
            ($1.deviceType == .builtInWideAngleCamera ? 0 : 1)
        }
        if devices.isEmpty, let fallback = AVCaptureDevice.default(for: .video) {
            devices = [fallback]
        }
        // The user's chosen camera leads; the watchdog still rotates onward
        // if it turns out to deliver no frames.
        if let uid = DeviceSettings.cameraUID,
           let idx = devices.firstIndex(where: { $0.uniqueID == uid }) {
            devices.insert(devices.remove(at: idx), at: 0)
        }
        candidates = devices
        candidateIndex = 0
    }

    static func availableCameras() -> [(name: String, uid: String)] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified)
        return discovery.devices.map { ($0.localizedName, $0.uniqueID) }
    }

    private func configureAndRun() {
        if session.isRunning { return }
        discoverCandidates()
        guard !candidates.isEmpty else {
            PWLog("no camera available")
            return
        }
        applyDevice(candidates[candidateIndex])

        if session.outputs.isEmpty {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            session.beginConfiguration()
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        }

        session.startRunning()
        PWLog("camera session running: \(session.isRunning), device: \(currentDeviceName())")
        scheduleWatchdog()
    }

    private func currentDeviceName() -> String {
        candidateIndex < candidates.count ? candidates[candidateIndex].localizedName : "?"
    }

    private func applyDevice(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            configureFormat(device)
        } else {
            PWLog("could not create capture input for \(device.localizedName)")
        }
        session.commitConfiguration()
    }

    /// Pin the device to a ~480p30 format — the feed only ever shows in the
    /// small floating window, so 720p+ just burns bandwidth. Session presets
    /// proved unreliable here (both test machines delivered 1080p under
    /// .hd1280x720, starving the encoder's bitrate budget), so pick the
    /// activeFormat explicitly. Also cap auto-exposure at 1/24 s: in low
    /// light it otherwise stretches frame duration and the feed visibly
    /// stutters.
    private func configureFormat(_ device: AVCaptureDevice) {
        let targetPixels = 854 * 480
        var best: AVCaptureDevice.Format?
        var bestScore = Int.max
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 24 }) else { continue }
            let pixels = Int(dims.width) * Int(dims.height)
            // Prefer the closest pixel count to the target, undersized only
            // if nothing at or above it exists.
            let score = pixels >= targetPixels ? pixels - targetPixels
                                               : (targetPixels - pixels) * 4
            if score < bestScore {
                bestScore = score
                best = format
            }
        }
        do {
            try device.lockForConfiguration()
            if let best {
                device.activeFormat = best
                let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
                PWLog("camera format pinned to \(dims.width)x\(dims.height) on \(device.localizedName)")
            }
            // Clamp to the active format's supported durations: setting one
            // outside the range throws an uncaught NSException. The Studio
            // Display Camera's formats support exactly one rate (30.00003
            // fps, min == max), so even a plain 1/30 is out of range.
            if let range = device.activeFormat.videoSupportedFrameRateRanges
                .max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                let clamp = { (d: CMTime) in
                    min(max(d, range.minFrameDuration), range.maxFrameDuration)
                }
                device.activeVideoMinFrameDuration = clamp(CMTime(value: 1, timescale: 30))
                device.activeVideoMaxFrameDuration = clamp(CMTime(value: 1, timescale: 24))
            }
            device.unlockForConfiguration()
        } catch {
            PWLog("could not configure format on \(device.localizedName): \(error)")
        }
    }

    /// If the running device produces no frames, rotate to the next one.
    private func scheduleWatchdog() {
        generation += 1
        let gen = generation
        let baseline = captureCounter.value
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == gen, self.session.isRunning else { return }
            guard self.captureCounter.value == baseline else { return }  // frames flowing
            PWLog("camera '\(self.currentDeviceName())' delivered ZERO frames in 3s — rotating")
            self.candidateIndex += 1
            if self.candidateIndex < self.candidates.count {
                self.applyDevice(self.candidates[self.candidateIndex])
                PWLog("switched to camera: \(self.currentDeviceName())")
                self.scheduleWatchdog()
            } else {
                PWLog("all cameras failed to deliver frames")
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            PWLog("capture frame arrived without image buffer")
            return
        }
        captureCounter.tick("\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))")
        onPixelBuffer?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
