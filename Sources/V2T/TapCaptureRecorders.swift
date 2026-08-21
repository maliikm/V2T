import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os.log

// The tap-side and mic-side file writers plus the silence watchdog,
// ported from DesktopAudio.

/// On-disk formats for captured audio.
enum CaptureFormat: String {
    case m4a
    case wav

    var fileExtension: String { rawValue }

    /// AVAudioFile settings matching the capture stream's rate and channels.
    /// AVAudioFile transparently converts the PCM buffers we write into the
    /// file's format (AAC encode for m4a).
    func fileSettings(sampleRate: Double, channelCount: UInt32) -> [String: Any] {
        switch self {
        case .m4a:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        case .wav:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        }
    }
}

/// Receives buffers from a ProcessTap's IO proc and writes them to an
/// AVAudioFile off the IO thread. Outlives tap rebuilds: call
/// `makeIOBlock(tapFormat:)` again for the new tap and keep writing to the
/// same file; format changes are converted.
final class ProcessTapRecorder {
    private static let logger = Logger(subsystem: kV2TSubsystem, category: "ProcessTapRecorder")

    let fileURL: URL
    private let file: AVAudioFile
    private let writerQueue = DispatchQueue(label: "\(kV2TSubsystem).tap-writer", qos: .userInitiated)
    private var converter: AVAudioConverter?

    /// Called (on the writer queue) with each buffer's peak amplitude (0...1).
    var onBuffer: ((_ peak: Float) -> Void)?

    /// While true, incoming buffers are dropped (the tap keeps running so
    /// resume is instant and stays aligned with the mic track).
    var isPaused = false

    /// Host time of the first non-empty buffer (for cross-track alignment).
    private(set) var firstBufferHostTime: UInt64?
    private(set) var framesWritten: Int64 = 0

    init(fileURL: URL, tapFormat: AVAudioFormat, captureFormat: CaptureFormat) throws {
        self.fileURL = fileURL
        let settings = captureFormat.fileSettings(
            sampleRate: tapFormat.sampleRate,
            channelCount: tapFormat.channelCount
        )
        self.file = try AVAudioFile(
            forWriting: fileURL,
            settings: settings,
            commonFormat: tapFormat.commonFormat,
            interleaved: tapFormat.isInterleaved
        )
    }

    /// The block installed as the aggregate device's IO proc. Runs on the
    /// Core Audio IO queue — copy the buffer and get out fast.
    func makeIOBlock(tapFormat: AVAudioFormat) -> AudioDeviceIOBlock {
        return { [weak self] _, inInputData, inInputTime, _, _ in
            guard let self, !self.isPaused else { return }
            guard let source = AVAudioPCMBuffer(
                pcmFormat: tapFormat,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ), source.frameLength > 0 else { return }

            if self.firstBufferHostTime == nil, inInputTime.pointee.mFlags.contains(.hostTimeValid) {
                self.firstBufferHostTime = inInputTime.pointee.mHostTime
            }

            guard let copy = Self.copyBuffer(source) else { return }
            self.writerQueue.async {
                self.write(copy)
            }
        }
    }

    /// Flushes pending writes (AVAudioFile closes on dealloc).
    func finish() {
        writerQueue.sync { }
    }

    // MARK: - Writer queue

    private func write(_ buffer: AVAudioPCMBuffer) {
        onBuffer?(Self.peak(of: buffer))
        do {
            // Full AVAudioFormat equality also compares channel layouts, which
            // differ (nil vs. default) between the tap ASBD and the file's
            // processing format — compare the fields that matter for writing.
            if Self.formatsCompatible(buffer.format, file.processingFormat) {
                try file.write(from: buffer)
                framesWritten += Int64(buffer.frameLength)
            } else {
                try writeConverted(buffer)
            }
        } catch {
            Self.logger.error("File write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func formatsCompatible(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }

    /// Conversion for buffers captured after a tap rebuild changed the stream
    /// format (e.g. 44.1 kHz AirPods → 48 kHz speakers).
    private func writeConverted(_ buffer: AVAudioPCMBuffer) throws {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: file.processingFormat)
        }
        guard let converter else { return }

        let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            return
        }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        if status != .error, output.frameLength > 0 {
            try file.write(from: output)
            framesWritten += Int64(output.frameLength)
        }
    }

    // MARK: - Helpers

    /// Peak amplitude scan (also the silence signal: peak == 0). Tight
    /// pointer loop — a Collection-based scan is far slower in debug builds.
    static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        var peak: Float = 0
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for channelBuffer in list {
            guard let data = channelBuffer.mData else { continue }
            let count = Int(channelBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let floats = data.assumingMemoryBound(to: Float.self)
            var index = 0
            while index < count {
                let magnitude = abs(floats[index])
                if magnitude > peak { peak = magnitude }
                index += 1
            }
        }
        return peak
    }

    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            return nil
        }
        copy.frameLength = source.frameLength
        let src = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(src.count, dst.count) {
            guard let srcData = src[index].mData, let dstData = dst[index].mData else { continue }
            let bytes = min(src[index].mDataByteSize, dst[index].mDataByteSize)
            memcpy(dstData, srcData, Int(bytes))
            dst[index].mDataByteSize = bytes
        }
        return copy
    }
}

/// Records the default input device (microphone) to a file as the session's
/// second track. AVAudioEngine's input tap runs on a non-realtime thread, so
/// writing in the callback is fine.
final class MicTrackRecorder {
    private static let logger = Logger(subsystem: kV2TSubsystem, category: "MicTrackRecorder")

    enum MicError: LocalizedError {
        case noInputDevice
        case invalidInputFormat

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone is connected."
            case .invalidInputFormat: return "The microphone's audio format is unavailable."
            }
        }
    }

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?

    /// Host time of the first captured buffer (for cross-track alignment).
    private(set) var firstBufferHostTime: UInt64?

    /// While true, incoming buffers are dropped (engine keeps running so
    /// resume is instant and stays aligned with the app track).
    var isPaused = false

    func start(fileURL: URL, captureFormat: CaptureFormat) throws {
        // Verify an input device exists BEFORE touching the engine —
        // installTap throws an uncatchable NSException when there is none.
        let defaultInput: AudioObjectID = (try? AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultInputDevice,
            defaultValue: AudioObjectID.unknown
        )) ?? .unknown
        guard defaultInput.isValid else { throw MicError.noInputDevice }

        let input = engine.inputNode
        // The HARDWARE-side format is the honest signal — outputFormat(forBus:)
        // can report a stale default with no device attached.
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw MicError.invalidInputFormat
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicError.invalidInputFormat
        }

        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: captureFormat.fileSettings(
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            ),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        self.file = file

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self, !self.isPaused else { return }
            if self.firstBufferHostTime == nil {
                self.firstBufferHostTime = when.hostTime
            }
            do {
                try file.write(from: buffer)
            } catch {
                Self.logger.error("Mic write failed: \(String(describing: error), privacy: .public)")
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.file = nil
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }
}

/// Backstop against mislabeled capture rates: the session knows the true
/// wall-clock recording duration, so if the finished file's decoded duration
/// disagrees with it, the audio was written with a wrong sample-rate label
/// (whatever the underlying cause). Rewrite it with the rate relabeled so it
/// plays in real time — pure PCM copy, no resampling, pitch restored exactly.
enum CaptureTimingRepair {
    private static let logger = Logger(subsystem: kV2TSubsystem, category: "CaptureTimingRepair")

    /// Blocking; call off the main thread. Returns the corrected file URL,
    /// or the original when timing is already right (±3%) or repair fails.
    static func repairIfMistimed(url: URL, actualDuration: Double) -> URL {
        guard actualDuration > 1 else { return url }
        do {
            let source = try AVAudioFile(forReading: url)
            let declaredRate = source.processingFormat.sampleRate
            guard declaredRate > 0, source.length > 0 else { return url }
            let fileDuration = Double(source.length) / declaredRate
            let ratio = fileDuration / actualDuration
            guard ratio < 0.97 || ratio > 1.03 else { return url }

            // The rate the frames were really captured at.
            let idealRate = declaredRate * fileDuration / actualDuration
            let standardRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000]
            var rate = idealRate
            if let nearest = standardRates.min(by: { abs($0 - idealRate) < abs($1 - idealRate) }),
               abs(nearest - idealRate) / idealRate <= 0.03 {
                rate = nearest
            }
            Self.logger.warning("Mistimed capture: declared \(declaredRate, privacy: .public) Hz, plays \(fileDuration, privacy: .public)s for \(actualDuration, privacy: .public)s recorded — relabeling at \(rate, privacy: .public) Hz")

            let channels = source.processingFormat.channelCount
            guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels) else {
                return url
            }
            let outURL = url.deletingLastPathComponent()
                .appendingPathComponent("retimed-\(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: outURL)
            let output = try AVAudioFile(
                forWriting: outURL,
                settings: CaptureFormat.m4a.fileSettings(sampleRate: rate, channelCount: UInt32(channels)),
                commonFormat: outFormat.commonFormat,
                interleaved: outFormat.isInterleaved
            )

            let capacity: AVAudioFrameCount = 1 << 16
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: capacity),
                  let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
                return url
            }
            while true {
                try source.read(into: inBuffer)
                let frames = Int(inBuffer.frameLength)
                if frames == 0 { break }
                for channel in 0..<Int(channels) {
                    if let src = inBuffer.floatChannelData?[channel],
                       let dst = outBuffer.floatChannelData?[channel] {
                        dst.update(from: src, count: frames)
                    }
                }
                outBuffer.frameLength = inBuffer.frameLength
                try output.write(from: outBuffer)
            }
            return outURL
        } catch {
            Self.logger.error("Timing repair failed: \(String(describing: error), privacy: .public)")
            return url
        }
    }
}

/// Watches the tap's buffer stream for pathological silence.
///
/// - All-zero from the very first buffer: almost certainly the System Audio
///   Recording permission was denied (denial manifests as silent buffers,
///   never as an error) → surface a permission hint.
/// - Prolonged all-zero after audio was flowing: either the app went quiet
///   (fine) or the known Core Audio tap bug where a live tap starts
///   delivering zeros → request a tap rebuild (harmless if merely quiet).
///
/// `ingest` is called on the recorder's writer queue; callbacks are
/// dispatched to the main queue.
final class SilenceWatchdog {
    var onSuspectedPermissionDenial: (() -> Void)?
    var onProlongedSilence: (() -> Void)?

    private let permissionHintSeconds: TimeInterval
    private let rebuildSeconds: TimeInterval
    private let rebuildCooldownSeconds: TimeInterval

    private var sawSignal = false
    private var silenceStartedAt: Date?
    private var startedAt = Date()
    private var permissionHintFired = false
    private var lastRebuildRequestAt: Date?

    init(
        permissionHintSeconds: TimeInterval = 3,
        rebuildSeconds: TimeInterval = 10,
        rebuildCooldownSeconds: TimeInterval = 30
    ) {
        self.permissionHintSeconds = permissionHintSeconds
        self.rebuildSeconds = rebuildSeconds
        self.rebuildCooldownSeconds = rebuildCooldownSeconds
    }

    /// Call after a tap rebuild or resume so accumulated silence isn't
    /// immediately re-flagged.
    func resetAfterRebuild() {
        silenceStartedAt = nil
        lastRebuildRequestAt = Date()
    }

    func ingest(isSilent: Bool) {
        let now = Date()

        if !isSilent {
            sawSignal = true
            silenceStartedAt = nil
            return
        }

        if silenceStartedAt == nil { silenceStartedAt = now }

        if !sawSignal {
            if !permissionHintFired, now.timeIntervalSince(startedAt) >= permissionHintSeconds {
                permissionHintFired = true
                let callback = onSuspectedPermissionDenial
                DispatchQueue.main.async { callback?() }
            }
            return
        }

        guard let silenceStart = silenceStartedAt,
              now.timeIntervalSince(silenceStart) >= rebuildSeconds else { return }
        if let last = lastRebuildRequestAt, now.timeIntervalSince(last) < rebuildCooldownSeconds { return }

        lastRebuildRequestAt = now
        silenceStartedAt = nil
        let callback = onProlongedSilence
        DispatchQueue.main.async { callback?() }
    }
}
