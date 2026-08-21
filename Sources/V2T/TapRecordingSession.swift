import AVFoundation
import CoreAudio
import Foundation
import os.log

/// What a capture session records: one app, or the whole system mix.
@available(macOS 14.4, *)
enum CaptureTarget {
    case app(AudioProcess)
    case systemAudio

    var displayName: String {
        switch self {
        case .app(let process): return process.name
        case .systemAudio: return "System Audio"
        }
    }

    var process: AudioProcess? {
        if case .app(let process) = self { return process }
        return nil
    }
}

/// One app-audio recording run: owns the tap and mic recorders, the session
/// folder, and start/stop orchestration including cross-track alignment.
/// (Ported from DesktopAudio's RecordingSession.)
///
/// The tap is disposable — torn down and rebuilt (keeping the same output
/// file) when the default output device changes, when the target app's
/// helper processes churn, or when the silence watchdog suspects the known
/// zero-buffer tap bug.
@available(macOS 14.4, *)
@MainActor
final class TapRecordingSession {
    private static let logger = Logger(subsystem: kV2TSubsystem, category: "TapRecordingSession")

    let target: CaptureTarget
    let directory: URL

    /// Fired when buffers have been all-zero since recording started —
    /// almost certainly a System Audio Recording permission denial.
    var onSuspectedPermissionDenial: (() -> Void)?

    private let levelBox = TapLevelBox()
    private var tap = ProcessTap()
    private var tapRecorder: ProcessTapRecorder?
    private var micRecorder: MicTrackRecorder?
    private let watchdog = SilenceWatchdog()
    private var currentObjectIDs: [AudioObjectID] = []
    private var outputDeviceListener: AudioPropertyListener?
    private var rateListener: AudioPropertyListener?
    private let ioQueue = DispatchQueue(label: "\(kV2TSubsystem).tap-io", qos: .userInitiated)

    private(set) var startedAt: Date?
    private(set) var isPaused = false
    private var stopped = false
    /// Wall-clock time actually recorded (pauses excluded).
    private(set) var activeDuration: TimeInterval = 0
    private var segmentStartedAt: Date?

    var appFileURL: URL { directory.appendingPathComponent("app.m4a") }
    var micFileURL: URL { directory.appendingPathComponent("mic.m4a") }
    var hasMicTrack: Bool { micRecorder != nil }

    /// Peak amplitude (0...1) seen since the last call — feeds the live
    /// waveform in the main window.
    func takeRecentPeak() -> Float {
        levelBox.take()
    }

    /// Seconds the mic track started after the app track (negative: before).
    var micOffsetSeconds: Double? {
        guard let appHostTime = tapRecorder?.firstBufferHostTime,
              let micHostTime = micRecorder?.firstBufferHostTime else { return nil }
        return AVAudioTime.seconds(forHostTime: micHostTime)
            - AVAudioTime.seconds(forHostTime: appHostTime)
    }

    init(target: CaptureTarget, baseDirectory: URL) {
        self.target = target
        self.directory = baseDirectory.appendingPathComponent(
            "V2T-capture-\(UUID().uuidString)", isDirectory: true
        )
    }

    /// Starts the app-audio tap and, when `withMic`, the microphone track.
    /// A mic failure never aborts the session — the app track is the product.
    func start(withMic: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        currentObjectIDs = target.process?.objectIDs ?? []
        try tap.activate(mode: tapMode)
        guard let tapFormat = tap.tapFormat else {
            throw CoreAudioError.osStatus(kAudioHardwareUnspecifiedError, "missing tap format")
        }

        let recorder = try ProcessTapRecorder(
            fileURL: appFileURL,
            tapFormat: tapFormat,
            captureFormat: .m4a
        )
        recorder.onBuffer = { [weak self] peak in
            guard let self else { return }
            self.watchdog.ingest(isSilent: peak == 0)
            self.levelBox.note(peak)
        }
        tapRecorder = recorder
        try tap.run(on: ioQueue, ioBlock: recorder.makeIOBlock(tapFormat: tapFormat))
        installRateListener()

        watchdog.onSuspectedPermissionDenial = { [weak self] in
            self?.onSuspectedPermissionDenial?()
        }
        watchdog.onProlongedSilence = { [weak self] in
            self?.rebuildTap(reason: "prolonged silence")
        }

        // Default output device switches change where the target app renders;
        // the safest recovery is a full tap rebuild.
        outputDeviceListener = try? AudioPropertyListener(
            objectID: .system,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) { [weak self] in
            Task { @MainActor in self?.rebuildTap(reason: "default output device changed") }
        }

        if withMic {
            let mic = MicTrackRecorder()
            do {
                try mic.start(fileURL: micFileURL, captureFormat: .m4a)
                micRecorder = mic
            } catch {
                Self.logger.error("Mic track failed to start, continuing app-only: \(String(describing: error), privacy: .public)")
                try? FileManager.default.removeItem(at: micFileURL) // no stub files
            }
        }

        startedAt = Date()
        segmentStartedAt = startedAt
    }

    // MARK: - Pause / resume

    /// Drops buffers on both tracks; the tap and engine keep running so
    /// resume is instant and the tracks stay mutually aligned.
    func pause() {
        guard !stopped, !isPaused, startedAt != nil else { return }
        isPaused = true
        tapRecorder?.isPaused = true
        micRecorder?.isPaused = true
        if let segmentStartedAt {
            activeDuration += Date().timeIntervalSince(segmentStartedAt)
        }
        segmentStartedAt = nil
    }

    func resume() {
        guard !stopped, isPaused else { return }
        isPaused = false
        segmentStartedAt = Date()
        tapRecorder?.isPaused = false
        micRecorder?.isPaused = false
        // Don't let silence accumulated across the pause trigger a rebuild.
        watchdog.resetAfterRebuild()
    }

    private var tapMode: ProcessTap.Mode {
        switch target {
        case .app: return .processes(currentObjectIDs)
        case .systemAudio: return .globalExcluding([])
        }
    }

    /// Retargets the tap when the referenced app's process set changes
    /// mid-recording (e.g. Chrome spawning a new audio helper for a new tab).
    func updateProcesses(from processes: [AudioProcess]) {
        guard !stopped, startedAt != nil else { return }
        guard let targetProcess = target.process else { return }
        let updatedIDs = processes.first { $0.id == targetProcess.id }?.objectIDs ?? []
        if updatedIDs.isEmpty { return } // app briefly has no audio processes
        guard Set(updatedIDs) != Set(currentObjectIDs) else { return }
        currentObjectIDs = updatedIDs
        rebuildTap(reason: "target app process set changed")
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let segmentStartedAt {
            activeDuration += Date().timeIntervalSince(segmentStartedAt)
            self.segmentStartedAt = nil
        }
        outputDeviceListener?.cancel()
        outputDeviceListener = nil
        rateListener?.cancel()
        rateListener = nil
        tap.invalidate()
        micRecorder?.stop()
        tapRecorder?.finish()
    }

    /// A sample-rate change on the (new) aggregate device mid-recording
    /// would silently mistime everything written after it — rebuild so the
    /// recorder's converter resamples into the file's original rate instead.
    private func installRateListener() {
        rateListener?.cancel()
        rateListener = try? AudioPropertyListener(
            objectID: tap.aggregateDeviceID,
            selector: kAudioDevicePropertyNominalSampleRate
        ) { [weak self] in
            Task { @MainActor in self?.rebuildTap(reason: "aggregate sample rate changed") }
        }
    }

    // MARK: - Tap rebuild

    private func rebuildTap(reason: String) {
        guard !stopped, let recorder = tapRecorder else { return }
        if case .app = target, currentObjectIDs.isEmpty {
            return
        }
        Self.logger.log("Rebuilding tap (\(reason, privacy: .public))")

        tap.invalidate()
        let newTap = ProcessTap()
        do {
            try newTap.activate(mode: tapMode)
            guard let tapFormat = newTap.tapFormat else {
                throw CoreAudioError.osStatus(kAudioHardwareUnspecifiedError, "missing tap format after rebuild")
            }
            try newTap.run(on: ioQueue, ioBlock: recorder.makeIOBlock(tapFormat: tapFormat))
            tap = newTap
            installRateListener()
            watchdog.resetAfterRebuild()
        } catch {
            newTap.invalidate()
            Self.logger.error("Tap rebuild failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Peak level handoff from the tap writer queue to the main-actor UI timer.
final class TapLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    func note(_ value: Float) {
        lock.lock()
        if value > peak { peak = value }
        lock.unlock()
    }

    /// Returns the max since the previous take, then resets.
    func take() -> Float {
        lock.lock()
        defer {
            peak = 0
            lock.unlock()
        }
        return peak
    }
}

/// Renders a session's app + mic tracks into a single file offline,
/// honoring the recorded start-time offset between the tracks.
/// (Ported from DesktopAudio's MixdownExporter.)
enum MixdownExporter {
    enum ExportError: LocalizedError {
        case renderFailed(String)
        var errorDescription: String? {
            if case .renderFailed(let reason) = self { return "Mixdown failed: \(reason)" }
            return nil
        }
    }

    /// Blocking; call off the main thread. Returns `outputURL`.
    static func export(appURL: URL, micURL: URL, micOffsetSeconds: Double, outputURL: URL) throws -> URL {
        let appFile = try AVAudioFile(forReading: appURL)
        let micFile = try AVAudioFile(forReading: micURL)

        let engine = AVAudioEngine()
        let appPlayer = AVAudioPlayerNode()
        let micPlayer = AVAudioPlayerNode()
        engine.attach(appPlayer)
        engine.attach(micPlayer)
        engine.connect(appPlayer, to: engine.mainMixerNode, format: appFile.processingFormat)
        engine.connect(micPlayer, to: engine.mainMixerNode, format: micFile.processingFormat)

        let sampleRate = appFile.processingFormat.sampleRate
        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw ExportError.renderFailed("could not create render format")
        }

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: maxFrames)
        try engine.start()

        // Positive offset: mic started after the app track; delay the mic.
        // Negative: app started later; delay the app track instead.
        let appDelaySamples = AVAudioFramePosition(max(0, -micOffsetSeconds) * sampleRate)
        let micDelaySamples = AVAudioFramePosition(max(0, micOffsetSeconds) * sampleRate)

        appPlayer.scheduleFile(appFile, at: AVAudioTime(sampleTime: appDelaySamples, atRate: sampleRate))
        micPlayer.scheduleFile(micFile, at: AVAudioTime(sampleTime: micDelaySamples, atRate: sampleRate))
        appPlayer.play()
        micPlayer.play()

        let appLength = appDelaySamples + frames(of: appFile, at: sampleRate)
        let micLength = micDelaySamples + frames(of: micFile, at: sampleRate)
        let totalFrames = max(appLength, micLength)

        try? FileManager.default.removeItem(at: outputURL)
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: CaptureFormat.m4a.fileSettings(sampleRate: sampleRate, channelCount: 2),
            commonFormat: renderFormat.commonFormat,
            interleaved: renderFormat.isInterleaved
        )

        guard let buffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: maxFrames) else {
            throw ExportError.renderFailed("could not allocate render buffer")
        }

        var rendered: AVAudioFramePosition = 0
        while rendered < totalFrames {
            let toRender = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), totalFrames - rendered))
            let status = try engine.renderOffline(toRender, to: buffer)
            switch status {
            case .success:
                try outputFile.write(from: buffer)
                rendered += AVAudioFramePosition(buffer.frameLength)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw ExportError.renderFailed("engine render error at frame \(rendered)")
            @unknown default:
                throw ExportError.renderFailed("unknown render status")
            }
        }

        engine.stop()
        return outputURL
    }

    /// File length converted to the render sample rate.
    private static func frames(of file: AVAudioFile, at sampleRate: Double) -> AVAudioFramePosition {
        let fileRate = file.processingFormat.sampleRate
        guard fileRate > 0 else { return file.length }
        return AVAudioFramePosition(Double(file.length) * sampleRate / fileRate)
    }
}
