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
    @Published private(set) var availableApps: [AudioProcess] = []
    @Published private(set) var isSaving = false
    @Published var lastError: String?
    /// Record the microphone alongside the app audio (meetings: them + you).
    @Published var recordMicToo: Bool {
        didSet { UserDefaults.standard.set(recordMicToo, forKey: "appAudioRecordMic") }
    }

    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    private var timer: Timer?
    private var startedAt = Date()
    private var accumulated: Double = 0
    private var segmentStartedAt: Date?

    private weak var store: LibraryStore?
    private weak var settings: AppSettings?
    private weak var transcriber: TranscriptionManager?

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

    override init() {
        recordMicToo = UserDefaults.standard.object(forKey: "appAudioRecordMic") as? Bool ?? true
        super.init()
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
        store: LibraryStore,
        settings: AppSettings,
        transcriber: TranscriptionManager
    ) {
        guard !isRecording, !isSaving else { return }
        guard #available(macOS 14.4, *) else {
            lastError = Self.unsupportedMessage
            return
        }
        self.store = store
        self.settings = settings
        self.transcriber = transcriber
        lastError = nil

        let target: CaptureTarget = app.map { .app($0) } ?? .systemAudio
        // Remembered so the ⌘⌥R hotkey repeats the last choice.
        UserDefaults.standard.set(app?.id ?? "", forKey: "appAudioLastTarget")
        let session = TapRecordingSession(
            target: target,
            baseDirectory: FileManager.default.temporaryDirectory
        )
        session.onSuspectedPermissionDenial = { [weak self] in
            self?.lastError = Self.permissionMessage
        }
        do {
            try session.start(withMic: recordMicToo)
        } catch {
            lastError = "Couldn't start capture: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: session.directory)
            return
        }

        self.session = session
        targetName = target.displayName
        startedAt = Date()
        accumulated = 0
        segmentStartedAt = startedAt
        elapsed = 0
        isPaused = false
        isRecording = true
        startTimer()

        if recordMicToo && !session.hasMicTrack {
            lastError = "Microphone track couldn't start — recording app audio only."
        }
    }

    /// ⌘⌥R behavior: stop if recording, otherwise start with the last-used
    /// target (falling back to System Audio if that app is gone).
    func toggleFromHotkey(store: LibraryStore, settings: AppSettings, transcriber: TranscriptionManager) {
        if isRecording {
            stop()
            return
        }
        guard !isSaving else { return }
        Task {
            await refreshApps()
            let savedID = UserDefaults.standard.string(forKey: "appAudioLastTarget") ?? ""
            let app = savedID.isEmpty ? nil : availableApps.first { $0.id == savedID }
            start(app: app, store: store, settings: settings, transcriber: transcriber)
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

        guard duration > 0.5 else {
            try? FileManager.default.removeItem(at: sessionDirectory)
            lastError = "Recording was too short to keep."
            return
        }

        isSaving = true
        Task {
            var finalURL = appURL
            if let micURL, FileManager.default.fileExists(atPath: micURL.path) {
                do {
                    let mixURL = sessionDirectory.appendingPathComponent("mix.m4a")
                    finalURL = try await Task.detached(priority: .userInitiated) {
                        try MixdownExporter.export(
                            appURL: appURL, micURL: micURL,
                            micOffsetSeconds: micOffset, outputURL: mixURL
                        )
                    }.value
                } catch {
                    self.lastError = "Mic mixdown failed (\(error.localizedDescription)) — saved the app audio only."
                }
            }

            let recording = self.store?.addRecordedFile(
                at: finalURL, duration: duration, startedAt: startDate, title: title
            )
            try? FileManager.default.removeItem(at: sessionDirectory)
            self.isSaving = false

            if let recording, let store = self.store, let settings = self.settings,
               let transcriber = self.transcriber,
               settings.autoTranscribe, settings.hasAPIKey {
                transcriber.transcribe(recording, store: store, settings: settings)
            }
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                if let segmentStartedAt = self.segmentStartedAt {
                    self.elapsed = self.accumulated + Date().timeIntervalSince(segmentStartedAt)
                } else {
                    self.elapsed = self.accumulated
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
