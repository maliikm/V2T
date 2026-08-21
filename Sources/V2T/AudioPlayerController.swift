import AppKit
import AVFoundation
import Foundation

/// Playback for the selected recording: play/pause, seek, ±15s, playback
/// speed, and Skip Silence (jumping over precomputed quiet ranges).
@MainActor
final class AudioPlayerController: NSObject, ObservableObject {
    @Published private(set) var currentRecordingID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    @Published var rate: Double {
        didSet {
            UserDefaults.standard.set(rate, forKey: "playbackRate")
            player?.rate = Float(rate)
        }
    }
    @Published var skipSilence: Bool {
        didSet { UserDefaults.standard.set(skipSilence, forKey: "skipSilence") }
    }

    /// Quiet ranges of the loaded recording, from WaveformLoader.
    var silentRanges: [ClosedRange<Double>] = []

    private var player: AVAudioPlayer?
    private var loadedURL: URL?
    private var timer: Timer?

    override init() {
        let defaults = UserDefaults.standard
        let storedRate = defaults.double(forKey: "playbackRate")
        rate = storedRate == 0 ? 1.0 : min(2.0, max(0.5, storedRate))
        skipSilence = defaults.bool(forKey: "skipSilence")
        super.init()
    }

    // MARK: - Loading

    func load(recordingID: UUID, url: URL) {
        // Also compare the URL: after an edit the same recording's audio is a
        // DIFFERENT file, and an id-only guard would keep playing the old one
        // through the still-open handle.
        guard currentRecordingID != recordingID || loadedURL != url else { return }
        unload()
        currentRecordingID = recordingID
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.rate = Float(rate)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            loadedURL = url
            duration = player.duration
            currentTime = 0
        } catch {
            player = nil
            loadedURL = nil
            duration = 0
            currentTime = 0
        }
    }

    func unload() {
        stopTimer()
        player?.stop()
        player = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentRecordingID = nil
        silentRanges = []
    }

    /// Stops playback if the given recording is loaded (e.g. before deletion).
    func unloadIfLoaded(_ recordingID: UUID) {
        if currentRecordingID == recordingID {
            unload()
        }
    }

    // MARK: - Transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        if player.currentTime >= player.duration - 0.05 {
            player.currentTime = 0
        }
        player.rate = Float(rate)
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        currentTime = player?.currentTime ?? currentTime
    }

    func seek(to time: Double) {
        guard let player else { return }
        let clamped = min(max(0, time), max(0, player.duration - 0.01))
        player.currentTime = clamped
        currentTime = clamped
    }

    func skip(_ delta: Double) {
        seek(to: currentTime + delta)
    }

    // MARK: - Timer

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
        guard let player, isPlaying else { return }
        var time = player.currentTime
        if skipSilence,
           let range = silentRanges.first(where: { $0.contains(time) }),
           range.upperBound - time > 0.25,
           range.upperBound < duration - 0.3 {
            player.currentTime = range.upperBound
            time = range.upperBound
        }
        currentTime = time
    }
}

/// App-wide space-bar play/pause. A local key monitor (rather than a menu
/// shortcut) so typing a space in any text field still works: events are
/// passed through whenever a text view has keyboard focus.
@MainActor
enum SpaceKeyPlaybackMonitor {
    private static var installed = false

    static func install(player: AudioPlayerController, recorder: RecorderController) {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, // space
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  !recorder.isRecording,
                  player.currentRecordingID != nil
            else { return event }
            player.togglePlay()
            return nil
        }
    }
}

extension AudioPlayerController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTimerFromDelegate()
            self.currentTime = self.duration
        }
    }

    private func stopTimerFromDelegate() {
        stopTimer()
    }
}
