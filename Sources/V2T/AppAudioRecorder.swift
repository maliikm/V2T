import AppKit
import AVFoundation
import Foundation

/// Menu bar app-audio recording, driven by Core Audio process taps (ported
/// from DesktopAudio): record one app's audio or the whole system mix,
/// optionally with a simultaneous microphone track that is mixed in on stop.
/// Finished recordings land in the library and auto-transcribe.
///
/// Process taps require macOS 14.4 and the System Audio Recording
/// permission (a silent denial is detected by the silence watchdog).
@MainActor
final class AppAudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var targetName = ""
    /// True when the current session also records the microphone.
    @Published private(set) var sessionHasMic = false
    /// Live tap levels (0...1), ~20/s — drives the main window's live waveform.
    @Published private(set) var levels: [Float] = []
    @Published private(set) var appLevel: Float = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var availableApps: [AudioProcess] = []
    @Published private(set) var isSaving = false
    @Published var lastError: String?

    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    private var timer: Timer?
    private var startedAt = Date()
    private var accumulated: Double = 0
    private var segmentStartedAt: Date?

    private weak var store: LibraryStore?
    private var folderID: UUID?
    private var onFinished: ((Recording) -> Void)?

    // Availability-gated internals, stored untyped so this class stays
    // usable on macOS 14.0.
    private var _controller: Any?
    private var _session: Any?

    @available(macOS 14.4, *)
    private var controller: AudioProcessController? {
        get { _controller as? AudioProcessController }
        set { _controller = newValue }
    }

    @available(macOS 14.4, *)
    private var session: TapRecordingSession? {
        get { _session as? TapRecordingSession }
        set { _session = newValue }
    }

    private static let unsupportedMessage = "Recording app audio requires macOS 14.4 or later."
    private static let permissionMessage = "No audio is arriving — macOS is likely blocking system-audio capture. Allow V2T under System Settings → Privacy & Security → Screen & System Audio Recording (System Audio Recording Only), then try again."

    // MARK: - App discovery

    func refreshApps() async {
        guard #available(macOS 14.4, *) else {
            lastError = Self.unsupportedMessage
            return
        }
        if controller == nil {
            let controller = AudioProcessController()
            controller.onProcessesChanged = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.availableApps = controller.processes
                if #available(macOS 14.4, *) {
                    self.session?.updateProcesses(from: controller.processes)
                }
            }
            self.controller = controller
            controller.activate()
        } else {
            controller?.reload()
        }
        availableApps = controller?.processes ?? []
    }

    // MARK: - Recording

    /// Starts capturing `app`'s audio, or all system audio when nil.
    func start(
        app: AudioProcess?,
        withMic: Bool,
        store: LibraryStore,
        folderID: UUID? = nil,
        onFinished: ((Recording) -> Void)? = nil
    ) {
        guard !isRecording, !isSaving else { return }
        guard #available(macOS 14.4, *) else {
            lastError = Self.unsupportedMessage
            return
        }
        self.store = store
        self.folderID = folderID
        self.onFinished = onFinished
        lastError = nil

        let target: CaptureTarget = app.map { .app($0) } ?? .systemAudio
        let session = TapRecordingSession(
            target: target,
            baseDirectory: store.recoveryRootURL
        )
        session.onSuspectedPermissionDenial = { [weak self] in
            self?.lastError = Self.permissionMessage
        }
        let wantsMic = withMic
        do {
            try session.start(withMic: wantsMic)
        } catch {
            lastError = "Couldn't start capture: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: session.directory)
            return
        }

        self.session = session
        targetName = target.displayName
        sessionHasMic = session.hasMicTrack
        startedAt = Date()
        accumulated = 0
        segmentStartedAt = startedAt
        elapsed = 0
        levels = []
        appLevel = 0
        micLevel = 0
        isPaused = false
        isRecording = true
        startTimer()

        if wantsMic && !session.hasMicTrack {
            lastError = "Microphone track couldn't start — recording app audio only."
        }
    }

    func pause() {
        guard #available(macOS 14.4, *), let session, isRecording, !isPaused else { return }
        session.pause()
        if let segmentStartedAt {
            accumulated += Date().timeIntervalSince(segmentStartedAt)
        }
        segmentStartedAt = nil
        isPaused = true
        appLevel = 0
        micLevel = 0
    }

    func resume() {
        guard #available(macOS 14.4, *), let session, isRecording, isPaused else { return }
        session.resume()
        segmentStartedAt = Date()
        isPaused = false
    }

    func stop() {
        guard #available(macOS 14.4, *), let session, isRecording else { return }
        isRecording = false
        isPaused = false
        stopTimer()
        session.stop()
        self.session = nil

        let duration = session.activeDuration
        let title = "\(targetName) \(startedAt.formatted(date: .omitted, time: .shortened))"
        let appURL = session.appFileURL
        let micURL = session.hasMicTrack ? session.micFileURL : nil
        let micOffset = session.micOffsetSeconds ?? 0
        let sessionDirectory = session.directory
        let startDate = startedAt
        let destinationFolder = folderID
        let finished = onFinished
        onFinished = nil

        guard duration > 0.5 else {
            try? FileManager.default.removeItem(at: sessionDirectory)
            lastError = "Recording was too short to keep."
            return
        }

        isSaving = true
        Task {
            // Backstop: if the tap wrote with a mislabeled sample rate (the
            // decoded duration disagrees with the wall clock), relabel it
            // before anything else consumes it.
            let repairedAppURL = await Task.detached(priority: .userInitiated) {
                CaptureTimingRepair.repairIfMistimed(url: appURL, actualDuration: duration)
            }.value
            if repairedAppURL != appURL {
                self.lastError = "The capture's timing was off and has been corrected automatically."
            }

            var finalURL = repairedAppURL
            if let micURL, FileManager.default.fileExists(atPath: micURL.path) {
                do {
                    let mixURL = sessionDirectory.appendingPathComponent("mix.m4a")
                    finalURL = try await Task.detached(priority: .userInitiated) {
                        try MixdownExporter.export(
                            appURL: repairedAppURL, micURL: micURL,
                            micOffsetSeconds: micOffset, outputURL: mixURL
                        )
                    }.value
                } catch {
                    self.lastError = "Mic mixdown failed (\(error.localizedDescription)) — saved the app audio only."
                }
            }

            var tracks = ["track-app.m4a": repairedAppURL]
            if let micURL { tracks["track-mic.m4a"] = micURL }
            if repairedAppURL != appURL { tracks["track-app-raw.m4a"] = appURL }
            let recording = self.store?.addRecordedFile(
                at: finalURL, duration: duration, startedAt: startDate, title: title,
                folderID: destinationFolder, rawTracks: tracks
            )
            // LibraryStore owns cleanup, after all audio and metadata writes
            // succeed. Failures leave the complete capture available for retry.
            if recording == nil {
                self.lastError = self.store?.lastError ?? "Captured files are kept in Recovery."
            }
            self.isSaving = false
            if let recording { finished?(recording) }
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        // 20 Hz: matches the live waveform's expected sample rate.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard isRecording else { return }
        if let segmentStartedAt {
            elapsed = accumulated + Date().timeIntervalSince(segmentStartedAt)
        } else {
            elapsed = accumulated
        }
        if #available(macOS 14.4, *), let session, !isPaused {
            appLevel = session.takeRecentPeak()
            micLevel = session.takeRecentMicPeak()
            levels.append(appLevel)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
