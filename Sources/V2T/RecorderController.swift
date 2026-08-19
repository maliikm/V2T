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

    func toggle(store: LibraryStore, onFinished: ((Recording) -> Void)? = nil) {
        if isRecording {
            stop()
        } else {
            start(store: store, onFinished: onFinished)
        }
    }

    func start(store: LibraryStore, onFinished: ((Recording) -> Void)? = nil) {
        guard !isRecording else { return }
        self.store = store
        self.onFinished = onFinished
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                self.lastError = "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone."
                return
            }
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
        defer {
            recorder = nil
            tempURL = nil
        }
        guard successfully, let tempURL, let store else {
            if !successfully { lastError = "Recording failed to save." }
            return
        }
        let recording = store.addRecordedFile(at: tempURL, duration: elapsed, startedAt: startedAt)
        if let recording {
            onFinished?(recording)
        }
        onFinished = nil
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
