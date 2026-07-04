import Foundation
import VideoToolbox
import CoreMedia
import AVFoundation

/// Hardware H.264 encoder tuned for real-time, low-latency streaming.
final class VideoEncoder {
    struct Config {
        var width: Int32
        var height: Int32
        var fps: Int32
        var bitrate: Int  // bits per second
        var keyframeInterval: Double  // seconds
    }

    private var session: VTCompressionSession?
    private var config: Config
    private var sequence: UInt32 = 0
    private var forceKeyframeFlag = false
    private let lock = NSLock()

    /// Called with a fully serialized frame ready for the wire.
    var onEncodedFrame: ((_ data: Data, _ isKeyframe: Bool, _ sequence: UInt32, _ timestampUs: UInt64) -> Void)?
    private lazy var emitCounter = PWCounter("encoder[\(config.width)x\(config.height)] frames out", every: 150)
    private lazy var inCounter = PWCounter("encoder[\(config.width)x\(config.height)] frames in", every: 150)

    init(config: Config) {
        self.config = config
    }

    deinit { invalidate() }

    func invalidate() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
            session = nil
        }
    }

    func forceKeyframe() {
        lock.lock(); forceKeyframeFlag = true; lock.unlock()
    }

    func updateBitrate(_ bitrate: Int) {
        config.bitrate = bitrate
        guard let s = session else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [NSNumber(value: bitrate / 8 * 2), NSNumber(value: 1)] as NSArray)
    }

    private func ensureSession(width: Int32, height: Int32) -> VTCompressionSession? {
        if let s = session, config.width == width, config.height == height { return s }
        invalidate()
        config.width = width
        config.height = height

        // Low-latency rate control is ideal but only some hardware encoders
        // support it (e.g. not most Intel Macs) — fall back to a standard
        // real-time session rather than silently sending no video at all.
        var newSession: VTCompressionSession?
        let lowLatencySpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
        var status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: lowLatencySpec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &newSession)
        if status != noErr || newSession == nil {
            PWLog("low-latency encoder unavailable (\(status)), using standard encoder")
            status = VTCompressionSessionCreate(
                allocator: nil, width: width, height: height,
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil,
                compressionSessionOut: &newSession)
        }
        guard status == noErr, let s = newSession else {
            PWLog("VTCompressionSessionCreate FAILED \(status) for \(width)x\(height)")
            return nil
        }

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: config.bitrate))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [NSNumber(value: config.bitrate / 8 * 2), NSNumber(value: 1)] as NSArray)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: config.fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: config.keyframeInterval))
        VTCompressionSessionPrepareToEncodeFrames(s)
        PWLog("encoder session created \(width)x\(height) @\(config.bitrate)bps")
        session = s
        return s
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        guard let s = ensureSession(width: width, height: height) else { return }
        inCounter.tick()

        lock.lock()
        let wantKeyframe = forceKeyframeFlag
        forceKeyframeFlag = false
        lock.unlock()

        var frameProps: CFDictionary?
        if wantKeyframe {
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            s, imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime, duration: .invalid,
            frameProperties: frameProps, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sb = sampleBuffer else {
                PWLog("encode callback error \(status), sample=\(sampleBuffer != nil)")
                return
            }
            self.emit(sampleBuffer: sb)
        }
    }

    private func emit(sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let isKeyframe: Bool = {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
                  let first = attachments.first else { return true }
            return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }()

        var out = Data()
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // Prefix parameter sets: u8 count, then u16 length + bytes per set.
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            out.append(UInt8(count))
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let ptr {
                    out.appendBE(UInt16(size))
                    out.append(ptr, count: size)
                }
            }
        } else if isKeyframe {
            out.append(UInt8(0))
        }

        // Append AVCC frame data (4-byte length-prefixed NALUs) as-is.
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let dp = dataPointer else { return }
        out.append(UnsafeRawPointer(dp).assumingMemoryBound(to: UInt8.self), count: totalLength)

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let tsUs = UInt64(max(0, pts.seconds) * 1_000_000)
        let seq = sequence
        sequence &+= 1
        emitCounter.tick("seq \(seq), key=\(isKeyframe), \(out.count)B")
        onEncodedFrame?(out, isKeyframe, seq, tsUs)
    }
}

/// Turns wire frames back into decodable CMSampleBuffers.
/// AVSampleBufferDisplayLayer decodes H.264 in hardware, so no explicit
/// VTDecompressionSession is needed on the receive side.
final class VideoFrameUnpacker {
    private var formatDescription: CMVideoFormatDescription?
    private var waitingForKeyframe = true

    /// Set when the unpacker needs a keyframe to resume (loss recovery).
    var needsKeyframe: Bool { waitingForKeyframe }

    func reset() {
        formatDescription = nil
        waitingForKeyframe = true
    }

    func unpack(frame: MediaFrame) -> CMSampleBuffer? {
        var data = frame.data
        if frame.isKeyframe {
            guard data.count >= 1 else { return nil }
            let paramCount = Int(data[data.startIndex])
            var offset = 1
            var paramSets: [Data] = []
            for _ in 0..<paramCount {
                guard data.count >= offset + 2 else { return nil }
                let len = Int(data.readBE(UInt16.self, at: offset))
                offset += 2
                guard data.count >= offset + len else { return nil }
                paramSets.append(data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + len)))
                offset += len
            }
            data = data.subdata(in: (data.startIndex + offset)..<data.endIndex)

            if paramSets.count >= 2 {
                // Copy each set into a stable heap buffer for the C call.
                let buffers: [UnsafeMutablePointer<UInt8>] = paramSets.map { set in
                    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
                    set.copyBytes(to: buf, count: set.count)
                    return buf
                }
                defer { buffers.forEach { $0.deallocate() } }
                let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
                let sizes = paramSets.map { $0.count }
                var fmt: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: paramSets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
                if let fmt { formatDescription = fmt }
            }
            waitingForKeyframe = false
        }

        guard !waitingForKeyframe, let fmt = formatDescription, !data.isEmpty else {
            waitingForKeyframe = true
            return nil
        }

        var blockBuffer: CMBlockBuffer?
        let length = data.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: length,
            flags: 0, blockBufferOut: &blockBuffer) == noErr, let bb = blockBuffer else { return nil }
        let copyStatus = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copyStatus == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame.timestampUs), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: bb, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer) == noErr, let sb = sampleBuffer else { return nil }

        // Render as soon as it arrives — the network is our clock.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}
