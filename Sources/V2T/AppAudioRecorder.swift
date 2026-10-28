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
    let liveTranscript = LiveTranscriber()
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var targetName = ""
    /// True when the current session also records the microphone.
    @Published private(set) var sessionHasMic = false
    @Published private(set) var isMicEnabled = false
    @Published private(set) var isChangingMicrophone = false
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
        settings: AppSettings,
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
        session.callAudioSink = liveTranscript.callSink
        session.micAudioSink = liveTranscript.micSink
        session.onSuspectedPermissionDenial = { [weak self] in
            self?.lastError = Self.permissionMessage
        }
        let wantsMic = withMic
        do {
            try session.start()
        } catch {
            session.stop()
            lastError = "Couldn't start capture: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: session.directory)
            return
        }

        self.session = session
        targetName = target.displayName
        sessionHasMic = session.hasMicTrack
        isMicEnabled = false
        startedAt = Date()
        accumulated = 0
        segmentStartedAt = startedAt
        elapsed = 0
        isPaused = false
        isRecording = true
        startTimer()
        liveTranscript.start(enabled: settings.liveTranscriptionEnabled,
                             locale: settings.liveTranscriptionLocale, includesCall: true) { [weak self] in
            self?.elapsed ?? 0
        }

        if wantsMic { setMicrophoneEnabled(true) }
    }

    func toggleMicrophone() {
        setMicrophoneEnabled(!isMicEnabled)
    }

    /// Permission can be requested after capture starts. A late response must
    /// never enable the mic in a stopped or replacement session.
    func setMicrophoneEnabled(_ enabled: Bool) {
        guard #available(macOS 14.4, *), let session, isRecording,
              !isChangingMicrophone, enabled != isMicEnabled else { return }
        if !enabled {
            try? session.setMicrophoneEnabled(false)
            isMicEnabled = false
            liveTranscript.setMicrophoneEnabled(false)
            return
        }
        isChangingMicrophone = true
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard self.session === session, self.isRecording else { return }
            defer { self.isChangingMicrophone = false }
            guard granted else {
                self.lastError = "Microphone access is off. Enable V2T in System Settings → Privacy & Security → Microphone. The call is still recording."
                return
            }
            do {
                try session.setMicrophoneEnabled(true)
                self.isMicEnabled = true
                self.sessionHasMic = true
                self.liveTranscript.setMicrophoneEnabled(true)
            } catch {
                self.lastError = "Couldn't enable the microphone: \(error.localizedDescription). The call is still recording."
            }
        }
    }

    func pause() {
        guard #available(macOS 14.4, *), let session, isRecording, !isPaused else { return }
        session.pause()
        liveTranscript.pause()
        if let segmentStartedAt {
            accumulated += Date().timeIntervalSince(segmentStartedAt)
        }
        segmentStartedAt = nil
        isPaused = true
    }

    func resume() {
        guard #available(macOS 14.4, *), let session, isRecording, isPaused else { return }
        session.resume()
        liveTranscript.resume()
        segmentStartedAt = Date()
        isPaused = false
    }

    func stop() {
        guard #available(macOS 14.4, *), let session, isRecording else { return }
        isRecording = false
        isPaused = false
        isMicEnabled = false
        isChangingMicrophone = false
        stopTimer()
        session.stop()
        let livePreview = liveTranscript.stop()
        self.session = nil

        let duration = session.activeDuration
        let endedAt = Date()
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
                folderID: destinationFolder, rawTracks: tracks, endedAt: endedAt
            )
            // LibraryStore owns cleanup, after all audio and metadata writes
            // succeed. Failures leave the complete capture available for retry.
            if recording == nil {
                self.lastError = self.store?.lastError ?? "Captured files are kept in Recovery."
            }
            if let recording { self.store?.saveLivePreview(livePreview, for: recording.id) }
            self.isSaving = false
            if let recording { finished?(recording) }
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
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
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
