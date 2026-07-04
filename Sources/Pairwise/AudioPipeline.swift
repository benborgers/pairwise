import Foundation
import AVFoundation
import PWShim

/// Full-duplex voice pipeline: an AVAudioEngine (built fresh for every call)
/// with Apple's voice processing (echo cancellation + noise suppression),
/// Opus over the wire when available, 24 kHz PCM fallback otherwise.
///
/// AVFAudio throws Objective-C exceptions on format disagreements (especially
/// with voice processing enabled), which Swift cannot catch — so every risky
/// call is wrapped in PWTryCatch and failure degrades to a call without audio
/// instead of a crash.
///
/// Wire payload: [codec: u8 (0 = Opus 48k mono, 1 = Int16 PCM 24k mono)] + frame bytes.
final class AudioPipeline {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let queue = DispatchQueue(label: "pairwise.audio", qos: .userInteractive)

    // 48 kHz mono is the pipeline's working format.
    private let workFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                           channels: 1, interleaved: false)!
    private let pcmFallbackFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                                  channels: 1, interleaved: true)!
    private var opusFormat: AVAudioFormat?

    private var inputConverter: AVAudioConverter?
    private var inputConverterSourceFormat: AVAudioFormat?
    private var opusEncoder: AVAudioConverter?
    private var opusDecoder: AVAudioConverter?
    private var fallbackDownConverter: AVAudioConverter?
    private var fallbackUpConverter: AVAudioConverter?

    private var pending = [Float]()  // accumulated mono samples awaiting a full 20 ms frame
    private let samplesPerFrame = 960  // 20 ms @ 48 kHz

    private var sequence: UInt32 = 0
    private var running = false
    var micEnabled = true

    var onEncodedFrame: ((_ data: Data, _ sequence: UInt32, _ timestampUs: UInt64) -> Void)?

    // MARK: - Lifecycle

    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else { NSLog("Pairwise: mic denied"); return }
            self?.queue.async { self?.startEngine() }
        }
    }

    private enum VoiceProcessingMode: String {
        case inputOnly = "AEC on"
        case off = "no AEC"
    }

    // MARK: - Voice-processing probe
    //
    // On some machines the voice-processing I/O unit fails to initialize
    // (-10875) — and once ONE attempt fails, CoreAudio state in the process is
    // poisoned and even plain engines refuse to start. So VP is probed in a
    // throwaway child process (this same executable with PAIRWISE_VP_PROBE=1);
    // the app process only ever attempts a configuration known to work.

    private static var probedVPWorks: Bool?
    private static let vpBrokenKey = "pairwise.vpBroken"

    /// Run the probe ahead of time (at app launch) so the first call doesn't
    /// pay the subprocess round-trip before audio starts.
    static func warmUpProbe() {
        _ = voiceProcessingWorks()
    }

    /// Runs inside the child process. Attempts a VP engine start and exits.
    static func runVoiceProcessingProbe() -> Never {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        var ok = false
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                    channels: 1, interleaved: false)!
            _ = PWTryCatch({
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: fmt)
                engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: nil) { _, _ in }
                engine.prepare()
                do { try engine.start(); ok = true } catch {}
            }, nil)
            engine.stop()
        } catch {}
        exit(ok ? 0 : 1)
    }

    private static func voiceProcessingWorks() -> Bool {
        if let cached = probedVPWorks { return cached }
        if UserDefaults.standard.bool(forKey: vpBrokenKey) { probedVPWorks = false; return false }
        guard let exe = Bundle.main.executablePath else { probedVPWorks = false; return false }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: exe)
        child.environment = ProcessInfo.processInfo.environment
            .merging(["PAIRWISE_VP_PROBE": "1"]) { _, new in new }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in done.signal() }
        do { try child.run() } catch { probedVPWorks = false; return false }
        if done.wait(timeout: .now() + 6) == .timedOut {
            child.terminate()
            probedVPWorks = false
            return false
        }
        let ok = child.terminationStatus == 0
        PWLog("voice-processing probe: \(ok ? "works" : "unavailable")")
        probedVPWorks = ok
        return ok
    }

    private func startEngine() {
        // Probe runs here on the pipeline queue (it blocks on the child
        // process); the engine itself is built on the main thread.
        let mode: VoiceProcessingMode = Self.voiceProcessingWorks() ? .inputOnly : .off
        DispatchQueue.main.async { [weak self] in self?.startEngineOnMain(mode: mode) }
    }

    private func startEngineOnMain(mode: VoiceProcessingMode) {
        guard !running else { return }
        setUpCodecs()
        if attemptStart(mode: mode) {
            PWLog("audio running (\(mode.rawValue))")
            return
        }
        if mode == .inputOnly {
            // The probe passed but the real start failed; the process is now
            // poisoned, so a fallback attempt would fail too. Remember the
            // failure so the NEXT call goes straight to no-AEC audio.
            UserDefaults.standard.set(true, forKey: Self.vpBrokenKey)
            PWLog("AEC engine failed despite probe; this call has no audio, future calls will skip AEC")
        } else {
            PWLog("audio unavailable; call continues without audio")
        }
    }

    private func attemptStart(mode: VoiceProcessingMode) -> Bool {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        if mode != .off {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
            } catch {
                NSLog("Pairwise: voice processing enable failed (\(error))")
                return false
            }
        }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            NSLog("Pairwise: no usable audio input (format \(inputFormat))")
            return false
        }

        // The tap uses the bus's own format (nil) — passing an explicit format
        // that disagrees with the hardware is the classic AVFAudio crash. The
        // input converter is built lazily from the first delivered buffer.
        inputConverter = nil
        inputConverterSourceFormat = nil

        var setupError: NSError?
        var started = false
        let ok = PWTryCatch({
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: self.workFormat)
            engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: nil) { [weak self] buffer, _ in
                self?.queue.async { self?.handleCaptured(buffer) }
            }
            engine.prepare()
            do {
                try engine.start()
                started = true
            } catch {
                PWLog("audio engine start failed [\(mode.rawValue)]: \(error)")
            }
        }, &setupError)

        if !ok {
            NSLog("Pairwise: audio setup threw [\(mode.rawValue)]: \(setupError?.localizedDescription ?? "?")")
        }
        guard ok, started else {
            _ = PWTryCatch({
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }, nil)
            return false
        }

        _ = PWTryCatch({ player.play() }, nil)
        self.engine = engine
        self.player = player
        running = true
        return true
    }

    private func setUpCodecs() {
        // Opus if the OS converter supports it, PCM otherwise. Rebuilt per
        // call so no stale codec state leaks between calls.
        var opusDesc = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        if let of = AVAudioFormat(streamDescription: &opusDesc) {
            opusFormat = of
            opusEncoder = AVAudioConverter(from: workFormat, to: of)
            opusDecoder = AVAudioConverter(from: of, to: workFormat)
            opusEncoder?.bitRate = 40_000
        }
        if opusEncoder == nil || opusDecoder == nil {
            NSLog("Pairwise: Opus unavailable, falling back to PCM")
            opusEncoder = nil
            opusDecoder = nil
            fallbackDownConverter = AVAudioConverter(from: workFormat, to: pcmFallbackFormat)
            fallbackUpConverter = AVAudioConverter(from: pcmFallbackFormat, to: workFormat)
        }
    }

    func stop() {
        let engine = self.engine
        let player = self.player
        self.engine = nil
        self.player = nil
        running = false
        if let engine {
            _ = PWTryCatch({
                engine.inputNode.removeTap(onBus: 0)
                player?.stop()
                engine.stop()
            }, nil)
        }
        queue.async { [weak self] in
            self?.pending.removeAll()
            self?.sequence = 0
        }
    }

    // MARK: - Capture → encode → wire

    private(set) var debugTapCount = 0
    private func handleCaptured(_ buffer: AVAudioPCMBuffer) {
        debugTapCount += 1
        guard running, micEnabled else { return }

        if inputConverter == nil || inputConverterSourceFormat != buffer.format {
            inputConverter = AVAudioConverter(from: buffer.format, to: workFormat)
            inputConverterSourceFormat = buffer.format
            pending.removeAll()
        }
        guard let converter = inputConverter else { return }

        let ratio = workFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: workFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0, let ch = converted.floatChannelData else { return }

        pending.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(converted.frameLength)))

        while pending.count >= samplesPerFrame {
            let frame = Array(pending.prefix(samplesPerFrame))
            pending.removeFirst(samplesPerFrame)
            encodeAndEmit(frame)
        }
    }

    private func encodeAndEmit(_ samples: [Float]) {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: workFormat, frameCapacity: AVAudioFrameCount(samplesPerFrame)) else { return }
        pcm.frameLength = AVAudioFrameCount(samplesPerFrame)
        samples.withUnsafeBufferPointer { src in
            pcm.floatChannelData![0].update(from: src.baseAddress!, count: samplesPerFrame)
        }

        var payload = Data()
        if let encoder = opusEncoder, let of = opusFormat {
            let out = AVAudioCompressedBuffer(format: of, packetCapacity: 1, maximumPacketSize: 1500)
            var fed = false
            var error: NSError?
            encoder.convert(to: out, error: &error) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return pcm
            }
            guard error == nil, out.byteLength > 0 else { return }
            payload.append(0)
            payload.append(Data(bytes: out.data, count: Int(out.byteLength)))
        } else if let down = fallbackDownConverter {
            let capacity = AVAudioFrameCount(samplesPerFrame / 2 + 16)
            guard let out = AVAudioPCMBuffer(pcmFormat: pcmFallbackFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            down.convert(to: out, error: &error) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return pcm
            }
            guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            payload.append(1)
            payload.append(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
        } else {
            return
        }

        let seq = sequence
        sequence &+= 1
        let ts = UInt64(DispatchTime.now().uptimeNanoseconds / 1000)
        onEncodedFrame?(payload, seq, ts)
    }

    // MARK: - Wire → decode → playback

    func playReceived(_ payload: Data) {
        queue.async { [weak self] in self?.decodeAndSchedule(payload) }
    }

    private func decodeAndSchedule(_ payload: Data) {
        guard running, payload.count > 1 else { return }
        let codec = payload[payload.startIndex]
        let body = payload.subdata(in: (payload.startIndex + 1)..<payload.endIndex)

        var pcmOut: AVAudioPCMBuffer?
        if codec == 0, let decoder = opusDecoder, let of = opusFormat {
            let compressed = AVAudioCompressedBuffer(format: of, packetCapacity: 1,
                                                     maximumPacketSize: max(body.count, 1))
            body.withUnsafeBytes { raw in
                compressed.data.copyMemory(from: raw.baseAddress!, byteCount: body.count)
            }
            compressed.byteLength = UInt32(body.count)
            compressed.packetCount = 1
            compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(body.count))

            guard let out = AVAudioPCMBuffer(pcmFormat: workFormat,
                                             frameCapacity: AVAudioFrameCount(samplesPerFrame * 2)) else { return }
            var fed = false
            var error: NSError?
            decoder.convert(to: out, error: &error) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return compressed
            }
            guard error == nil, out.frameLength > 0 else { return }
            pcmOut = out
        } else if codec == 1, let up = fallbackUpConverter {
            let sampleCount = body.count / 2
            guard sampleCount > 0,
                  let inBuf = AVAudioPCMBuffer(pcmFormat: pcmFallbackFormat,
                                               frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
            inBuf.frameLength = AVAudioFrameCount(sampleCount)
            body.withUnsafeBytes { raw in
                inBuf.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!,
                                                  count: sampleCount)
            }
            guard let out = AVAudioPCMBuffer(pcmFormat: workFormat,
                                             frameCapacity: AVAudioFrameCount(sampleCount * 2 + 16)) else { return }
            var fed = false
            var error: NSError?
            up.convert(to: out, error: &error) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return inBuf
            }
            guard error == nil, out.frameLength > 0 else { return }
            pcmOut = out
        }

        if let buf = pcmOut, let player, running {
            _ = PWTryCatch({ player.scheduleBuffer(buf, completionHandler: nil) }, nil)
        }
    }
}
