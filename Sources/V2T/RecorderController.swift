import AVFoundation
import Foundation

/// In-app voice recording (the red button), capturing AAC m4a like Voice Memos.
@MainActor
final class RecorderController: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
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
            guard recorder.record() else {
                lastError = "Couldn't start recording."
                return
            }
            self.recorder = recorder
            tempURL = url
            startedAt = Date()
            elapsed = 0
            isRecording = true
            lastError = nil
            startTimer()
        } catch {
            lastError = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard let recorder, isRecording else { return }
        elapsed = recorder.currentTime
        isRecording = false
        stopTimer()
        recorder.stop() // finalization continues in the delegate callback
    }

    private func finishedWriting(successfully: Bool) {
        // The recording can also end without stop() being called (encoder or
        // disk error), so reset ALL state here unconditionally.
        // `elapsed` is fresh in both paths: stop() captured it, and the
        // 0.1s timer kept it current if the recorder ended on its own.
        let finishedTempURL = tempURL
        let finishedElapsed = elapsed
        let callback = onFinished
        recorder = nil
        tempURL = nil
        onFinished = nil
        isRecording = false
        stopTimer()

        guard successfully, let finishedTempURL, let store else {
            if !successfully { lastError = "Recording failed to save." }
            return
        }
        let recording = store.addRecordedFile(at: finishedTempURL, duration: finishedElapsed, startedAt: startedAt)
        if let recording {
            callback?(recording)
        }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder, self.isRecording else { return }
                self.elapsed = recorder.currentTime
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

extension RecorderController: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.finishedWriting(successfully: flag)
        }
    }
}
