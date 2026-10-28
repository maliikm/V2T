import AVFoundation
import Foundation

/// In-app voice recording (the red button), capturing AAC m4a like Voice
/// Memos, with an optional Deepgram live transcript and pause/resume.
@MainActor
final class RecorderController: NSObject, ObservableObject {
    let liveTranscript = LiveTranscriber()
    private var previewInput: MicrophonePreviewInput?
    private var livePreview = ""
    private weak var appSettings: AppSettings?
    /// True for the whole session, including while paused.
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var sessionTitle = ""
    @Published private(set) var sessionStartedAt: Date?
    @Published var lastError: String?
    @Published private(set) var isSaving = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt = Date()
    private var tempURL: URL?
    private weak var store: LibraryStore?
    private var onFinished: ((Recording) -> Void)?
    /// Guards the async gap between the record click and the microphone
    /// permission response, so a double-click can't start two recorders.
    @Published private(set) var isStarting = false
    private var folderID: UUID?

    func start(store: LibraryStore, settings: AppSettings? = nil, folderID: UUID? = nil, onFinished: ((Recording) -> Void)? = nil) {
        guard !isRecording, !isStarting, !isSaving else { return }
        isStarting = true
        self.store = store
        self.appSettings = settings
        self.folderID = folderID
        self.onFinished = onFinished
        Task {
            defer { self.isStarting = false }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                self.lastError = "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone."
                return
            }
            guard self.recorder == nil else { return }
            self.beginRecording()
        }
    }

    private func beginRecording() {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        do {
            guard let store else { return }
            let directory = try store.makeCaptureDirectory()
            let url = directory.appendingPathComponent("audio.m4a")
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.record() else {
                lastError = "Couldn't start recording."
                return
            }
            self.recorder = recorder
            tempURL = url
            startedAt = Date()
            sessionStartedAt = startedAt
            sessionTitle = store.nextRecordingTitle()
            elapsed = 0
            isPaused = false
            isRecording = true
            lastError = nil
            startTimer()
            livePreview = ""
            let previewEnabled = appSettings?.liveTranscriptionEnabled ?? false
            liveTranscript.start(enabled: previewEnabled,
                                 apiKey: appSettings?.deepgramAPIKey ?? "",
                                 language: appSettings?.deepgramLanguageCode ?? "en",
                                 includesCall: false) { [weak self] in self?.elapsed ?? 0 }
            if liveTranscript.isRunning {
                let input = MicrophonePreviewInput()
                do { try input.start(sink: liveTranscript.micSink); previewInput = input }
                catch { lastError = "Live preview input is unavailable. Audio is still recording." }
            }
        } catch {
            lastError = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func pause() {
        guard isRecording, !isPaused, let recorder else { return }
        recorder.pause()
        liveTranscript.pause()
        elapsed = recorder.currentTime
        isPaused = true
    }

    func resume() {
        guard isRecording, isPaused, let recorder else { return }
        if recorder.record() {
            isPaused = false
            liveTranscript.resume()
        } else {
            lastError = "Couldn't resume recording."
        }
    }

    func stop() {
        guard let recorder, isRecording else { return }
        elapsed = recorder.currentTime
        isRecording = false
        isSaving = true
        isPaused = false
        stopTimer()
        previewInput?.stop()
        previewInput = nil
        recorder.stop() // finalization continues in the delegate callback
    }

    private func finishedWriting(successfully: Bool) async {
        defer { isSaving = false }
        // The recording can also end without stop() being called (encoder or
        // disk error), so reset ALL state here unconditionally.
        // `elapsed` is fresh in both paths: stop() captured it, and the
        // timer kept it current if the recorder ended on its own.
        let finishedTempURL = tempURL
        let finishedElapsed = elapsed
        let finishedTitle = sessionTitle
        let callback = onFinished
        previewInput?.stop()
        previewInput = nil
        livePreview = await liveTranscript.finish()
        recorder = nil
        tempURL = nil
        onFinished = nil
        isRecording = false
        isPaused = false
        sessionStartedAt = nil
        stopTimer()

        guard successfully, let finishedTempURL, let store else {
            if !successfully { lastError = "Recording failed to save." }
            store?.refreshRecovery()
            return
        }
        let recording = store.addRecordedFile(
            at: finishedTempURL,
            duration: finishedElapsed,
            startedAt: startedAt,
            title: finishedTitle,
            folderID: folderID, endedAt: Date()
        )
        if let recording {
            store.saveLivePreview(livePreview, for: recording.id)
            callback?(recording)
        } else {
            lastError = store.lastError ?? "Captured files are kept in Recovery. Open V2T to retry saving."
        }
    }

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

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let recorder, isRecording else { return }
        guard !isPaused else { return }
        elapsed = recorder.currentTime
    }
}

extension RecorderController: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            await self.finishedWriting(successfully: flag)
        }
    }
}
