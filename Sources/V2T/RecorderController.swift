import AVFoundation
import Foundation

/// In-app voice recording (the red button), capturing AAC m4a like Voice
/// Memos. While a session is active it publishes live meter levels for the
/// recording screen, and supports pause/resume before finishing with stop().
@MainActor
final class RecorderController: NSObject, ObservableObject {
    /// True for the whole session, including while paused.
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: Double = 0
    /// Live microphone levels (0...1), sampled ~20×/second while recording.
    @Published private(set) var levels: [Float] = []
    @Published private(set) var sessionTitle = ""
    @Published private(set) var sessionStartedAt: Date?
    @Published var lastError: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt = Date()
    private var tempURL: URL?
    private weak var store: LibraryStore?
    private var onFinished: ((Recording) -> Void)?
    /// Guards the async gap between the record click and the microphone
    /// permission response, so a double-click can't start two recorders.
    private var isStarting = false

    func toggle(store: LibraryStore, onFinished: ((Recording) -> Void)? = nil) {
        if isRecording {
            stop()
        } else {
            start(store: store, onFinished: onFinished)
        }
    }

    func start(store: LibraryStore, onFinished: ((Recording) -> Void)? = nil) {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        self.store = store
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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("V2T-rec-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                lastError = "Couldn't start recording."
                return
            }
            self.recorder = recorder
            tempURL = url
            startedAt = Date()
            sessionStartedAt = startedAt
            sessionTitle = store?.nextRecordingTitle() ?? "New Recording"
            elapsed = 0
            levels = []
            isPaused = false
            isRecording = true
            lastError = nil
            startTimer()
        } catch {
            lastError = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func pause() {
        guard isRecording, !isPaused, let recorder else { return }
        recorder.pause()
        elapsed = recorder.currentTime
        isPaused = true
    }

    func resume() {
        guard isRecording, isPaused, let recorder else { return }
        if recorder.record() {
            isPaused = false
        } else {
            lastError = "Couldn't resume recording."
        }
    }

    func stop() {
        guard let recorder, isRecording else { return }
        elapsed = recorder.currentTime
        isRecording = false
        isPaused = false
        stopTimer()
        recorder.stop() // finalization continues in the delegate callback
    }

    private func finishedWriting(successfully: Bool) {
        // The recording can also end without stop() being called (encoder or
        // disk error), so reset ALL state here unconditionally.
        // `elapsed` is fresh in both paths: stop() captured it, and the
        // timer kept it current if the recorder ended on its own.
        let finishedTempURL = tempURL
        let finishedElapsed = elapsed
        let finishedTitle = sessionTitle
        let callback = onFinished
        recorder = nil
        tempURL = nil
        onFinished = nil
        isRecording = false
        isPaused = false
        sessionStartedAt = nil
        stopTimer()

        guard successfully, let finishedTempURL, let store else {
            if !successfully { lastError = "Recording failed to save." }
            return
        }
        let recording = store.addRecordedFile(
            at: finishedTempURL,
            duration: finishedElapsed,
            startedAt: startedAt,
            title: finishedTitle
        )
        if let recording {
            callback?(recording)
        }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
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
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        // Perceptual mapping of -60dB...0dB onto 0...1.
        let level = max(0, min(1, (db + 60) / 60))
        levels.append(level)
    }
}

extension RecorderController: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.finishedWriting(successfully: flag)
        }
    }
}
