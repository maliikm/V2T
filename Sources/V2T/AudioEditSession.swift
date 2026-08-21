import AVFoundation
import Foundation

/// State for the in-place edit mode: a working copy of the recording's
/// audio that Trim / Delete / Replace / Resume operate on, with per-step
/// undo. Done commits the working file back into the library; every edit
/// is previewed live through the shared player.
@MainActor
final class AudioEditSession: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var workingDuration: Double = 0
    @Published private(set) var workingWaveform: WaveformData?
    @Published private(set) var canUndo = false
    @Published private(set) var isProcessing = false
    /// Mic capture for Replace/Resume in progress.
    @Published private(set) var isReplacing = false
    @Published private(set) var replaceElapsed: Double = 0
    @Published var error: String?

    // Trim tool state.
    @Published var showTrimTool = false
    @Published var selectionStart: Double = 0
    @Published var selectionEnd: Double = 1

    private var recordingID: UUID?
    private var originalURL: URL?
    /// nil while the audio is still the untouched original.
    private var workingURL: URL?
    private var undoStack: [URL?] = []
    private var tempFiles: Set<URL> = []
    private weak var player: AudioPlayerController?

    private var micRecorder: AVAudioRecorder?
    private var micTempURL: URL?
    private var micCancelled = false
    private var micTimer: Timer?
    private var replaceAt: Double = 0

    var currentURL: URL? { workingURL ?? originalURL }
    var hasEdits: Bool { workingURL != nil }

    // MARK: - Lifecycle

    func begin(recording: Recording, store: LibraryStore, player: AudioPlayerController, initialWaveform: WaveformData?) {
        guard !isActive else { return }
        recordingID = recording.id
        originalURL = store.audioURL(for: recording)
        self.player = player
        workingURL = nil
        undoStack = []
        tempFiles = []
        workingDuration = recording.duration
        workingWaveform = initialWaveform
        selectionStart = 0
        selectionEnd = 1
        showTrimTool = false
        canUndo = false
        error = nil
        isActive = true
    }

    /// Ends the session. With `commit`, an edited working file replaces the
    /// library audio (invalidating the transcript); otherwise edits are
    /// discarded.
    func end(commit: Bool, store: LibraryStore) {
        guard isActive else { return }
        if isReplacing { cancelReplace() }
        if commit, let final = workingURL, let id = recordingID {
            tempFiles.remove(final)
            store.replaceAudio(for: id, with: final, duration: workingDuration)
        }
        for file in tempFiles {
            try? FileManager.default.removeItem(at: file)
        }
        tempFiles = []
        undoStack = []
        workingURL = nil
        originalURL = nil
        recordingID = nil
        showTrimTool = false
        canUndo = false
        isReplacing = false
        isProcessing = false
        error = nil
        isActive = false
    }

    // MARK: - Undo

    func undo() {
        guard !isProcessing, !isReplacing, let previous = undoStack.popLast() else { return }
        if let discarded = workingURL {
            tempFiles.remove(discarded)
            try? FileManager.default.removeItem(at: discarded)
        }
        workingURL = previous
        canUndo = !undoStack.isEmpty
        let keepTime = player?.currentTime ?? 0
        Task { await refreshDerived(seekTo: keepTime) }
    }

    private func pushWorking(_ url: URL) {
        undoStack.append(workingURL)
        workingURL = url
        tempFiles.insert(url)
        canUndo = true
    }

    // MARK: - Trim tool

    func applyTrim(keepSelection: Bool) async {
        guard !isProcessing, !isReplacing, let base = currentURL else { return }
        let lower = min(selectionStart, selectionEnd) * workingDuration
        let upper = max(selectionStart, selectionEnd) * workingDuration
        let range = lower...max(upper, lower + 0.01)
        guard range.upperBound - range.lowerBound >= 0.2 else {
            error = "Selection is too short."
            return
        }
        error = nil
        isProcessing = true
        do {
            let result: URL
            if keepSelection {
                result = try await AudioEditor.trim(url: base, keeping: range)
            } else {
                result = try await AudioEditor.deleteRange(url: base, removing: range, totalDuration: workingDuration)
            }
            let newDuration = await AudioEditor.duration(of: result)
            guard newDuration > 0.1 else {
                error = "That edit would leave no audio."
                try? FileManager.default.removeItem(at: result)
                isProcessing = false
                return
            }
            pushWorking(result)
            selectionStart = 0
            selectionEnd = 1
            await refreshDerived(seekTo: keepSelection ? 0 : range.lowerBound)
        } catch {
            self.error = error.localizedDescription
        }
        isProcessing = false
    }

    // MARK: - Replace / Resume

    /// Starts recording the microphone over the audio from `time`
    /// (or appending, when `time` is at the end).
    func beginReplace(at time: Double) {
        guard isActive, !isReplacing, !isProcessing else { return }
        player?.pause()
        replaceAt = max(0, min(time, workingDuration))
        error = nil
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                self.error = "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone."
                return
            }
            guard !self.isReplacing else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("V2T-replace-\(UUID().uuidString).m4a")
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
                    self.error = "Couldn't start recording."
                    return
                }
                self.micRecorder = recorder
                self.micTempURL = url
                self.micCancelled = false
                self.replaceElapsed = 0
                self.isReplacing = true
                self.startMicTimer()
            } catch {
                self.error = "Couldn't start recording: \(error.localizedDescription)"
            }
        }
    }

    func stopReplace() {
        micRecorder?.stop() // splicing continues in the delegate callback
    }

    private func cancelReplace() {
        micCancelled = true
        micRecorder?.stop()
    }

    private func finishReplace(successfully: Bool) {
        stopMicTimer()
        isReplacing = false
        let temp = micTempURL
        let cancelled = micCancelled
        micRecorder = nil
        micTempURL = nil
        micCancelled = false

        guard !cancelled, successfully, let temp, let base = currentURL else {
            if let temp { try? FileManager.default.removeItem(at: temp) }
            if !successfully && !cancelled { error = "Recording failed." }
            return
        }
        isProcessing = true
        let insertAt = replaceAt
        let total = workingDuration
        Task {
            do {
                let additionDuration = await AudioEditor.duration(of: temp)
                guard additionDuration > 0.2 else {
                    try? FileManager.default.removeItem(at: temp)
                    self.isProcessing = false
                    return
                }
                let result: URL
                if insertAt >= total - 0.3 {
                    result = try await AudioEditor.append(original: base, addition: temp)
                } else {
                    result = try await AudioEditor.replaceSection(
                        original: base, at: insertAt,
                        additionURL: temp, additionDuration: additionDuration,
                        totalDuration: total
                    )
                }
                try? FileManager.default.removeItem(at: temp)
                self.pushWorking(result)
                await self.refreshDerived(seekTo: insertAt + additionDuration)
            } catch {
                self.error = error.localizedDescription
            }
            self.isProcessing = false
        }
    }

    // MARK: - Derived state

    /// Recomputes duration/waveform of the working audio and reloads it into
    /// the shared player.
    private func refreshDerived(seekTo: Double?) async {
        guard let url = currentURL, let id = recordingID else { return }
        let duration = await AudioEditor.duration(of: url)
        if duration > 0 { workingDuration = duration }
        let waveform = try? await WaveformLoader.load(audioURL: url, cacheURL: nil)
        workingWaveform = waveform
        if let player {
            player.unloadIfLoaded(id)
            player.load(recordingID: id, url: url)
            player.silentRanges = waveform.map { WaveformLoader.silentRanges(in: $0) } ?? []
            if let seekTo {
                player.seek(to: max(0, min(seekTo, workingDuration - 0.05)))
            }
        }
    }

    // MARK: - Mic timer

    private func startMicTimer() {
        stopMicTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.micRecorder, self.isReplacing else { return }
                self.replaceElapsed = recorder.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        micTimer = timer
    }

    private func stopMicTimer() {
        micTimer?.invalidate()
        micTimer = nil
    }
}

extension AudioEditSession: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.finishReplace(successfully: flag)
        }
    }
}
