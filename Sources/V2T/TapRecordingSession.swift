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
/// stream stops delivering buffers. Helper changes update the existing tap;
/// silence alone never restarts capture.
@available(macOS 14.4, *)
@MainActor
final class TapRecordingSession {
    private static let logger = Logger(subsystem: kV2TSubsystem, category: "TapRecordingSession")

    let target: CaptureTarget
    let directory: URL

    var onCaptureNotice: ((CaptureNotice?) -> Void)?
    private var currentNotice: CaptureNotice?
    private var healthTimer: Timer?
    private var healthActiveSince = ProcessInfo.processInfo.systemUptime
    private var lastHealthRecovery: TimeInterval = 0
    private var stalledRecoveries = 0
    var callAudioSink: LiveAudioSink?
    var micAudioSink: LiveAudioSink?

    private var tap = ProcessTap()
    private var tapRecorder: ProcessTapRecorder?
    private var micRecorder: MicTrackRecorder?
    private let signal = CaptureSignalMonitor()
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
    private var timeline = CaptureTimeline()

    var appFileURL: URL { directory.appendingPathComponent("app.m4a") }
    var micFileURL: URL { directory.appendingPathComponent("mic.m4a") }
    var hasMicTrack: Bool { micRecorder != nil }

    /// Seconds the mic track started after the app track (negative: before).
    var micOffsetSeconds: Double? {
        guard let appHostTime = tapRecorder?.firstBufferHostTime,
              let micHostTime = micRecorder?.firstBufferHostTime else { return nil }
        return timeline.offset(
            from: AVAudioTime.seconds(forHostTime: appHostTime),
            to: AVAudioTime.seconds(forHostTime: micHostTime)
        )
    }

    init(target: CaptureTarget, baseDirectory: URL) {
        self.target = target
        self.directory = baseDirectory.appendingPathComponent(
            "V2T-capture-\(UUID().uuidString)", isDirectory: true
        )
    }

    /// Starts app audio immediately; the mic can be enabled at any time.
    func start() throws {
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
            self.signal.ingest(peak: peak)
        }
        tapRecorder = recorder
        recorder.onAudio = { [callAudioSink] buffer in callAudioSink?.append(buffer) }
        try tap.run(on: ioQueue, ioBlock: recorder.makeIOBlock(tapFormat: tapFormat))
        installRateListener()

        // Default output device switches change where the target app renders;
        // the safest recovery is a full tap rebuild.
        outputDeviceListener = try? AudioPropertyListener(
            objectID: .system,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) { [weak self] in
            Task { @MainActor in self?.rebuildTap(reason: "default output device changed") }
        }

        startedAt = Date()
        segmentStartedAt = startedAt
        healthActiveSince = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkCaptureHealth() }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    func setMicrophoneEnabled(_ enabled: Bool) throws {
        guard !stopped, startedAt != nil else { return }
        if let micRecorder {
            // Keep the track's clock running. Muting writes silence, whereas
            // pausing drops time from BOTH tracks.
            micRecorder.isMuted = !enabled
        } else if enabled {
            let mic = MicTrackRecorder()
            micStartedAt = ProcessInfo.processInfo.systemUptime
            mic.onAudio = { [micAudioSink] buffer in micAudioSink?.append(buffer) }
            mic.isPaused = isPaused
            try mic.start(fileURL: micFileURL, captureFormat: .m4a)
            micRecorder = mic
        }
    }

    // MARK: - Pause / resume

    /// Drops buffers on both tracks; the tap and engine keep running so
    /// resume is instant and the tracks stay mutually aligned.
    func pause() {
        guard !stopped, !isPaused, startedAt != nil else { return }
        isPaused = true
        timeline.pause(at: AVAudioTime.seconds(forHostTime: mach_absolute_time()))
        tapRecorder?.isPaused = true
        micRecorder?.isPaused = true
        if let segmentStartedAt {
            activeDuration += Date().timeIntervalSince(segmentStartedAt)
        }
        segmentStartedAt = nil
        setNotice(nil)
    }

    func resume() {
        guard !stopped, isPaused else { return }
        isPaused = false
        timeline.resume(at: AVAudioTime.seconds(forHostTime: mach_absolute_time()))
        segmentStartedAt = Date()
        healthActiveSince = ProcessInfo.processInfo.systemUptime
        tapRecorder?.isPaused = false
        micRecorder?.isPaused = false
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
        do {
            try tap.updateProcesses(updatedIDs)
            currentObjectIDs = updatedIDs
            LiveDiagnostics.write("Capture: updated app process set count=\(updatedIDs.count)")
        } catch {
            currentObjectIDs = updatedIDs
            rebuildTap(reason: "process update failed")
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        healthTimer?.invalidate()
        healthTimer = nil
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
        setNotice(nil)
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

    private func checkCaptureHealth() {
        guard !stopped, !isPaused, let recorder = tapRecorder else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let app = recorder.progress.snapshot
        if app.writeError != nil || app.isStalled(now: now, activeSince: healthActiveSince) {
            setNotice(.init(message: stalledRecoveries < 3
                            ? "Call audio has stopped reaching the file. Attempting to restore capture."
                            : "Call audio capture is unavailable. Stop recording and check the audio source; the captured portion will be kept.", severity: .error))
            if stalledRecoveries < 3, now - lastHealthRecovery > 5 {
                lastHealthRecovery = now
                stalledRecoveries += 1
                LiveDiagnostics.write("Capture: call stalled; rebuilding tap, attempt=\(stalledRecoveries)")
                rebuildTap(reason: "no successful audio writes")
            }
        } else {
            stalledRecoveries = 0
            if let mic = micRecorder,
               mic.progress.snapshot.writeError != nil || mic.progress.snapshot.isStalled(now: now, activeSince: max(healthActiveSince, micStartedAt)) {
                setNotice(.init(message: "Microphone audio has stopped reaching the file. Check your microphone; call audio is still arriving.", severity: .error))
            } else if signal.isQuiet(now: now, activeSince: healthActiveSince) {
                setNotice(.init(message: "No sound detected from \(target.displayName). If audio is playing, check the selected source and V2T’s System Audio Recording permission.", severity: .information))
            } else {
                setNotice(nil)
            }
        }
    }
    private func setNotice(_ notice: CaptureNotice?) {
        guard currentNotice != notice else { return }
        currentNotice = notice
        onCaptureNotice?(notice)
        // Fixed, metadata-only events; do not log user-facing app names.
        LiveDiagnostics.write(notice == nil ? "Capture: status cleared" : "Capture: status changed severity=\(notice!.severity)")
    }
    private var micStartedAt = ProcessInfo.processInfo.systemUptime

    // MARK: - Tap rebuild

    private func rebuildTap(reason: String) {
        guard !stopped, let recorder = tapRecorder else { return }
        if case .app = target, currentObjectIDs.isEmpty {
            return
        }
        Self.logger.log("Rebuilding tap (\(reason, privacy: .public))")
        LiveDiagnostics.write("Capture: rebuilding tap reason=\(reason)")

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
            healthActiveSince = ProcessInfo.processInfo.systemUptime
        } catch {
            newTap.invalidate()
            setNotice(.init(message: "Call audio capture could not restart. Stop and check your audio source; the captured portion will be kept.", severity: .error))
            LiveDiagnostics.write("Capture: tap rebuild failed code=\((error as NSError).code)")
            Self.logger.error("Tap rebuild failed: \(String(describing: error), privacy: .public)")
        }
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
