import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Records another app's audio (or all system audio) via ScreenCaptureKit,
/// for the menu bar "record app audio" feature. Finished recordings are
/// saved into the library like any other recording.
///
/// Requires the Screen Recording permission (macOS gates system-audio
/// capture behind it); the first start triggers the system prompt.
@MainActor
final class AppAudioRecorder: NSObject, ObservableObject {
    struct CapturableApp: Identifiable, Equatable {
        let id: pid_t
        let name: String
        let bundleIdentifier: String
    }

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var targetName = ""
    @Published private(set) var availableApps: [CapturableApp] = []
    @Published var lastError: String?

    private var stream: SCStream?
    /// Shared with the capture callback thread, hence the locked box.
    private let writerBox = WriterBox()
    private var timer: Timer?
    private var startedAt = Date()
    private let sampleQueue = DispatchQueue(label: "v2t.app-audio-capture")

    private weak var store: LibraryStore?
    private weak var settings: AppSettings?
    private weak var transcriber: TranscriptionManager?

    // MARK: - App discovery

    /// Apps that own at least one on-screen window, i.e. plausible audio sources.
    func refreshApps() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let windowedPIDs = Set(content.windows.compactMap { $0.owningApplication?.processID })
            let apps = content.applications
                .filter { app in
                    windowedPIDs.contains(app.processID)
                        && !app.applicationName.isEmpty
                        && app.bundleIdentifier != Bundle.main.bundleIdentifier
                }
                .map { CapturableApp(id: $0.processID, name: $0.applicationName, bundleIdentifier: $0.bundleIdentifier) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            availableApps = apps
        } catch {
            lastError = Self.friendlyCaptureError(error)
        }
    }

    // MARK: - Recording

    /// Starts capturing audio of `app`, or all system audio when nil.
    func start(
        app: CapturableApp?,
        store: LibraryStore,
        settings: AppSettings,
        transcriber: TranscriptionManager
    ) {
        guard !isRecording else { return }
        self.store = store
        self.settings = settings
        self.transcriber = transcriber
        lastError = nil

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    lastError = "No display available for capture."
                    return
                }

                let filter: SCContentFilter
                if let app, let scApp = content.applications.first(where: { $0.processID == app.id }) {
                    filter = SCContentFilter(display: display, including: [scApp], exceptingWindows: [])
                    targetName = app.name
                } else {
                    filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                    targetName = "System Audio"
                }

                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                // Audio-only intent: keep the mandatory video leg negligible.
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("V2T-appaudio-\(UUID().uuidString).m4a")
                let writer = try CapturedAudioFileWriter(outputURL: outputURL)

                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                try await stream.startCapture()

                self.stream = stream
                self.writerBox.set(writer)
                self.startedAt = Date()
                self.elapsed = 0
                self.isRecording = true
                self.startTimer()
            } catch {
                lastError = Self.friendlyCaptureError(error)
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        stopTimer()
        let stream = stream
        let writer = writerBox.get()
        self.stream = nil
        self.writerBox.set(nil)

        Task {
            try? await stream?.stopCapture()
            writer?.finish {
                Task { @MainActor in
                    self.finalize(writer: writer)
                }
            }
        }
    }

    private func finalize(writer: CapturedAudioFileWriter?) {
        guard let writer else { return }
        guard writer.succeeded, elapsed > 0.5 else {
            lastError = writer.succeeded ? "Recording was too short to keep." : "Saving the capture failed."
            try? FileManager.default.removeItem(at: writer.outputURL)
            return
        }
        guard let store else { return }
        let time = startedAt.formatted(date: .omitted, time: .shortened)
        let recording = store.addRecordedFile(
            at: writer.outputURL,
            duration: elapsed,
            startedAt: startedAt,
            title: "\(targetName) \(time)"
        )
        if let recording, let settings, let transcriber,
           settings.autoTranscribe, settings.hasAPIKey {
            transcriber.transcribe(recording, store: store, settings: settings)
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private static func friendlyCaptureError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            return "Screen & System Audio Recording permission is needed to capture app audio. Allow V2T in System Settings → Privacy & Security → Screen Recording, then try again."
        }
        return "Couldn't capture audio: \(error.localizedDescription)"
    }
}

// MARK: - Stream callbacks

extension AppAudioRecorder: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer) else { return }
        writerBox.get()?.append(sampleBuffer)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            if self.isRecording {
                self.lastError = Self.friendlyCaptureError(error)
                self.stop()
            }
        }
    }

}

/// Lock-guarded handoff of the writer between the main actor (start/stop)
/// and the capture sample queue (append).
private final class WriterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: CapturedAudioFileWriter?

    func set(_ newValue: CapturedAudioFileWriter?) {
        lock.lock()
        writer = newValue
        lock.unlock()
    }

    func get() -> CapturedAudioFileWriter? {
        lock.lock()
        defer { lock.unlock() }
        return writer
    }
}

/// Transcodes captured PCM sample buffers into an AAC m4a. All appends
/// happen on the capture sample queue; `finish` is called once afterwards.
final class CapturedAudioFileWriter: @unchecked Sendable {
    let outputURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var startedSession = false

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "V2T", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't start the audio file writer."
            ])
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        if !startedSession {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            startedSession = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func finish(completion: @escaping () -> Void) {
        guard writer.status == .writing else {
            completion()
            return
        }
        input.markAsFinished()
        writer.finishWriting(completionHandler: completion)
    }

    var succeeded: Bool {
        writer.status == .completed && startedSession
    }
}
