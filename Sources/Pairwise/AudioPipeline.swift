import Foundation
import AVFoundation
import AudioToolbox
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
    // Bumped on stop() so delayed watchdog work from an earlier call knows
    // the pipeline was stopped and must not restart audio.
    private var lifecycleGeneration = 0
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
    private static var vpBrokenThisProcess = false
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
                // Player goes straight to outputNode: touching mainMixerNode
                // after enabling voice processing breaks output unit init
                // (-10875), and the VP output unit is the AEC reference anyway.
                engine.connect(player, to: engine.outputNode, format: fmt)
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
        // A failed real start only poisons THIS process's CoreAudio state, so
        // the broken flag must not outlive the launch. Clear anything an older
        // build persisted so AEC gets retried.
        UserDefaults.standard.removeObject(forKey: vpBrokenKey)
        if vpBrokenThisProcess { probedVPWorks = false; return false }
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
        let forceOff = ProcessInfo.processInfo.environment["PAIRWISE_FORCE_NO_AEC"] == "1"
        let mode: VoiceProcessingMode = (!forceOff && Self.voiceProcessingWorks()) ? .inputOnly : .off
        DispatchQueue.main.async { [weak self] in self?.startEngineOnMain(mode: mode) }
    }

    private func startEngineOnMain(mode: VoiceProcessingMode) {
        guard !running else { return }
        setUpCodecs()
        if attemptStart(mode: mode) {
            PWLog("audio running (\(mode.rawValue))")
            if mode == .inputOnly { scheduleAECWatchdog() }
            return
        }
        if mode == .inputOnly {
            // The probe passed but the real start failed; the process is now
            // poisoned, so a fallback attempt would fail too. Remember the
            // failure so the next call THIS LAUNCH goes straight to no-AEC audio.
            Self.vpBrokenThisProcess = true
            Self.probedVPWorks = false
            PWLog("AEC engine failed despite probe; this call has no audio, calls after relaunch will skip AEC")
        } else {
            PWLog("audio unavailable; call continues without audio")
        }
    }

    // The voice-processing unit can start cleanly yet deliver no input at all
    // (wedged CoreAudio voice-processing state — the engine runs, the tap never
    // fires). If nothing has been captured shortly after start, trade AEC for
    // a working call.
    private func scheduleAECWatchdog() {
        let engineAtStart = engine
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.running, self.engine === engineAtStart else { return }
            let dead = self.debugTapCount == 0 ||
                (self.micEnabled && self.debugSampleCount > 0 && self.debugSumSquares == 0)
            guard dead else { return }
            PWLog("AEC engine started but captured nothing; retrying without AEC")
            Self.vpBrokenThisProcess = true
            Self.probedVPWorks = false
            let old = self.engine
            let oldPlayer = self.player
            self.engine = nil
            self.player = nil
            self.running = false
            if let old {
                _ = PWTryCatch({
                    old.inputNode.removeTap(onBus: 0)
                    oldPlayer?.stop()
                    old.stop()
                }, nil)
            }
            // Give the dead voice-processing unit a moment to finish tearing
            // down in coreaudiod; starting the replacement engine immediately
            // leaves it starved the same way.
            let generation = self.lifecycleGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.lifecycleGeneration == generation,
                      !self.running, self.engine == nil else { return }
                if self.attemptStart(mode: .off) {
                    PWLog("audio running (no AEC)")
                } else {
                    PWLog("audio unavailable; call continues without audio")
                }
            }
        }
    }

    private func attemptStart(mode: VoiceProcessingMode) -> Bool {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        debugTapCount = 0
        debugSumSquares = 0
        debugSampleCount = 0

        if mode != .off {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
            } catch {
                NSLog("Pairwise: voice processing enable failed (\(error))")
                return false
            }
        }

        applyPreferredInputDevice(engine)

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
            // Straight to outputNode — see runVoiceProcessingProbe for why
            // mainMixerNode must not be touched with voice processing on.
            engine.connect(player, to: engine.outputNode, format: self.workFormat)
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

    /// Points the engine's input at the user-chosen mic. Must run before the
    /// input format is read or the engine starts. Any failure (device
    /// unplugged, property rejected) falls back to the system default input.
    private func applyPreferredInputDevice(_ engine: AVAudioEngine) {
        guard let uid = DeviceSettings.micUID else { return }
        guard let device = AudioInputDevices.all().first(where: { $0.uid == uid }) else {
            PWLog("preferred mic \(uid) not connected; using system default")
            return
        }
        guard let unit = engine.inputNode.audioUnit else { return }
        var deviceID = device.id
        let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &deviceID,
                                       UInt32(MemoryLayout<AudioDeviceID>.size))
        if err == noErr {
            PWLog("mic: \(device.name)")
        } else {
            PWLog("could not select mic '\(device.name)' (err \(err)); using system default")
        }
    }

    /// Tears down and rebuilds the engine (e.g. after the user picks a
    /// different mic mid-call). The 1 s gap mirrors the AEC watchdog: a
    /// replacement engine started immediately after teardown inherits a
    /// starved input from coreaudiod.
    func restart() {
        guard running else { return }
        stop()
        let generation = lifecycleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.lifecycleGeneration == generation, !self.running else { return }
            self.start()
        }
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
        lifecycleGeneration += 1
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
            // The sequence deliberately survives stop/start: the receiver
            // drops packets whose sequence runs backward, so an engine
            // rebuild mid-call (mic change, AEC fallback) must not restart
            // numbering or the peer goes silent until it catches up.
        }
    }

    // MARK: - Capture → encode → wire

    private(set) var debugTapCount = 0
    private var debugSumSquares = 0.0
    private var debugSampleCount = 0
    /// RMS of all captured (post-conversion) samples — 0 means the mic path
    /// is producing pure silence even if frames are flowing.
    var debugCaptureRMS: Double {
        debugSampleCount > 0 ? (debugSumSquares / Double(debugSampleCount)).squareRoot() : 0
    }
    private func handleCaptured(_ buffer: AVAudioPCMBuffer) {
        debugTapCount += 1
        guard running, micEnabled else { return }

        // The voice-processing unit can deliver the full device channel layout
        // (9 channels on some Macs) with the mic signal in only one channel.
        // AVAudioConverter's default multichannel→mono mapping yields silence
        // for those buffers, so downmix explicitly before converting.
        let source = downmixToMono(buffer) ?? buffer

        if inputConverter == nil || inputConverterSourceFormat != source.format {
            inputConverter = AVAudioConverter(from: source.format, to: workFormat)
            inputConverterSourceFormat = source.format
            pending.removeAll()
        }
        guard let converter = inputConverter else { return }

        let ratio = workFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: workFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return source
        }
        guard error == nil, converted.frameLength > 0, let ch = converted.floatChannelData else { return }

        for i in 0..<Int(converted.frameLength) {
            let s = Double(ch[0][i])
            debugSumSquares += s * s
        }
        debugSampleCount += Int(converted.frameLength)

        pending.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(converted.frameLength)))

        while pending.count >= samplesPerFrame {
            let frame = Array(pending.prefix(samplesPerFrame))
            pending.removeFirst(samplesPerFrame)
            encodeAndEmit(frame)
        }
    }

    private func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.channelCount > 1, buffer.frameLength > 0,
              let ch = buffer.floatChannelData,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: buffer.format.sampleRate,
                                      channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: buffer.frameLength)
        else { return nil }
        let frames = Int(buffer.frameLength)
        // Average only channels carrying signal: unused slots in the VP unit's
        // channel layout are digital silence, and mixing them in would just
        // attenuate the one live mic channel.
        var live = [UnsafeMutablePointer<Float>]()
        for c in 0..<Int(buffer.format.channelCount) {
            var energy: Float = 0
            for i in 0..<frames { energy += ch[c][i] * ch[c][i] }
            if energy > 0 { live.append(ch[c]) }
        }
        mono.frameLength = buffer.frameLength
        let out = mono.floatChannelData![0]
        if live.isEmpty {
            for i in 0..<frames { out[i] = 0 }
        } else {
            let scale = 1 / Float(live.count)
            for i in 0..<frames {
                var s: Float = 0
                for c in live { s += c[i] }
                out[i] = s * scale
            }
        }
        return mono
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
