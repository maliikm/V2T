import AVFoundation
import Combine
import Foundation

/// All user entry points route through this coordinator to prevent competing
/// engines and to snapshot the source and destination at the start of a take.
@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published var configuration: RecordingConfiguration {
        didSet { configuration.save(to: defaults) }
    }
    @Published private(set) var isStarting = false
    @Published var lastError: String?
    @Published var selectedFolderID: UUID?

    let recorder: RecorderController
    let appAudio: AppAudioRecorder
    private let store: LibraryStore
    private let settings: AppSettings
    private let transcriber: TranscriptionManager
    private let defaults: UserDefaults
    private let requestMicrophoneAccess: () async -> Bool
    private var observations = Set<AnyCancellable>()

    init(store: LibraryStore, settings: AppSettings, recorder: RecorderController,
         appAudio: AppAudioRecorder, transcriber: TranscriptionManager,
         defaults: UserDefaults = .standard,
         requestMicrophoneAccess: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.store = store
        self.settings = settings
        self.recorder = recorder
        self.appAudio = appAudio
        self.transcriber = transcriber
        self.defaults = defaults
        self.requestMicrophoneAccess = requestMicrophoneAccess
        configuration = .load(from: defaults)
        recorder.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        appAudio.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
    }

    var isRecording: Bool { recorder.isRecording || appAudio.isRecording }
    var isPaused: Bool { recorder.isRecording ? recorder.isPaused : appAudio.isPaused }
    var isSaving: Bool { recorder.isSaving || appAudio.isSaving }
    var isBusy: Bool { isStarting || recorder.isStarting || isRecording || isSaving }
    var elapsed: Double { recorder.isRecording ? recorder.elapsed : appAudio.elapsed }
    var error: String? { lastError ?? recorder.lastError ?? appAudio.lastError }

    var summary: String {
        let source = configuration.source == .application
            ? configuration.appName ?? appAudio.availableApps.first(where: { $0.id == configuration.appID })?.name ?? "Choose an application"
            : configuration.source.title
        return configuration.source == .microphone ? source
            : "\(source) · Mic \(configuration.includesMicrophone ? "on" : "off")"
    }

    func choose(_ app: AudioProcess) {
        guard !isBusy else { return }
        configuration.appID = app.id
        configuration.appName = app.name
    }

    func toggleRecording() {
        if recorder.isRecording { recorder.stop(); return }
        if appAudio.isRecording { appAudio.stop(); return }
        start()
    }

    func start() {
        guard !isBusy else { return }
        let chosen = configuration
        let folderID = selectedFolderID
        isStarting = true
        lastError = nil
        recorder.lastError = nil
        appAudio.lastError = nil
        Task {
            defer { isStarting = false }
            do {
                if chosen.source != .microphone {
                    guard AppAudioRecorder.isSupported else {
                        lastError = "Application and Mac audio recording require macOS 14.4 or later."
                        return
                    }
                    await appAudio.refreshApps()
                }
                // Resolve the exact selection. Never substitute another app or
                // broaden a missing application to all system audio.
                let app = try chosen.target(in: appAudio.availableApps)
                if chosen.usesMicrophone {
                    guard await requestMicrophoneAccess() else {
                        lastError = "Microphone access is off. Enable V2T in System Settings → Privacy & Security → Microphone."
                        return
                    }
                }
                let finished: (Recording) -> Void = { [weak self] recording in
                    self?.didSave(recording)
                }
                if chosen.source == .microphone {
                    recorder.start(store: store, folderID: folderID, onFinished: finished)
                } else {
                    appAudio.start(app: app, withMic: chosen.includesMicrophone,
                                   store: store, folderID: folderID, onFinished: finished)
                }
            } catch { lastError = error.localizedDescription }
        }
    }

    func togglePause() {
        if recorder.isRecording {
            recorder.isPaused ? recorder.resume() : recorder.pause()
        } else if appAudio.isRecording {
            appAudio.isPaused ? appAudio.resume() : appAudio.pause()
        }
    }

    func retrySaves() {
        guard !isBusy else { return }
        lastError = nil
        recorder.lastError = nil
        appAudio.lastError = nil
        for recording in store.retryRecoverableCaptures() { didSave(recording) }
    }

    private func didSave(_ recording: Recording) {
        if settings.autoTranscribe && settings.hasAPIKey {
            transcriber.transcribe(recording, store: store, settings: settings)
        }
    }
}
