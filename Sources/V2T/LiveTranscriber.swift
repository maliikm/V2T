import AVFoundation
import Speech
import SwiftUI

/// The capture callbacks append directly under a lock, without queueing an
/// unbounded number of audio buffers on the main actor.
final class LiveAudioSink {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var format: AVAudioFormat?
    private var formatChangeHandler: (() -> Void)?
    var onFormatChange: (() -> Void)? {
        get { lock.withLock { formatChangeHandler } }
        set { lock.withLock { formatChangeHandler = newValue } }
    }

    func replaceRequest(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock {
            request?.endAudio()
            request = newRequest
            format = nil
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        var changed = false
        lock.withLock {
            guard let request, buffer.frameLength > 0 else { return }
            if let format, format != buffer.format {
                request.endAudio()
                self.request = nil
                changed = true
                return
            }
            format = buffer.format
            request.append(buffer)
        }
        if changed { onFormatChange?() }
    }
}

struct LiveTranscriptEntry: Identifiable {
    let id: UUID
    let source: String
    let startedAt: Double
    var text: String
}

@MainActor
final class LiveTranscriber: ObservableObject {
    @Published private(set) var entries: [LiveTranscriptEntry] = []
    @Published private(set) var status = "Live transcript is off."
    @Published private(set) var isRunning = false
    let callSink = LiveAudioSink()
    let micSink = LiveAudioSink()
    private var channels: [LiveSpeechChannel] = []
    private var microphoneChannel: LiveSpeechChannel?
    private var isPaused = false
    private var micEnabled = false
    private var generation = UUID()
    private var timer: Timer?
    private var elapsed: () -> Double = { 0 }

    var text: String {
        entries.sorted { $0.startedAt < $1.startedAt }.map {
            "\($0.source) [\(TranscriptFormatter.timestamp($0.startedAt))]: \($0.text)"
        }.joined(separator: "\n\n")
    }

    func start(enabled: Bool, locale: String, includesCall: Bool, elapsed: @escaping () -> Double) {
        stop()
        entries = []
        isPaused = false
        micEnabled = !includesCall
        self.elapsed = elapsed
        guard enabled else { status = "Live transcript is off. Enable it in Settings."; return }
        let token = UUID()
        generation = token
        status = "Preparing on-device speech recognition…"
        Task {
            let permission = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard generation == token else { return }
            guard permission == .authorized else {
                status = "Allow Speech Recognition for V2T in System Settings to see a live transcript. Audio is still recording."
                return
            }
            let sources: [(String, LiveAudioSink)] = includesCall
                ? [("Call audio", callSink), ("My microphone", micSink)]
                : [("Microphone", micSink)]
            for (name, sink) in sources {
                guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
                      recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
                    status = "On-device speech recognition isn't available for this language. Audio is still recording; the final transcript is available after stopping."
                    channels.forEach { $0.stop() }
                    channels = []
                    return
                }
                let channel = LiveSpeechChannel(recognizer: recognizer, sink: sink, elapsed: elapsed)
                channel.onText = { [weak self] id, start, text in
                    guard let self else { return }
                    self.status = "On-device preview · speaker labels and wording may change in the final transcript."
                    if let index = self.entries.firstIndex(where: { $0.id == id }) {
                        self.entries[index].text = text
                    } else if !text.isEmpty {
                        self.entries.append(.init(id: id, source: name, startedAt: start, text: text))
                    }
                }
                channel.onFailure = { [weak self] in
                    self?.status = "Retrying live recognition for \(name.lowercased())… Audio is still recording."
                }
                channels.append(channel)
                if sink === micSink { microphoneChannel = channel }
                if isPaused || (sink === micSink && !micEnabled) { channel.pause() }
            }
            isRunning = true
            status = "On-device preview · speaker labels and wording may change in the final transcript."
            channels.forEach { $0.start() }
            let timer = Timer(timeInterval: 50, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.channels.forEach { $0.rotate() } }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func pause() { isPaused = true; channels.forEach { $0.pause() } }
    func resume() {
        isPaused = false
        channels.forEach { $0.resume() }
        if !micEnabled { microphoneChannel?.pause() }
    }
    func setMicrophoneEnabled(_ enabled: Bool) {
        micEnabled = enabled
        if enabled && !isPaused { microphoneChannel?.resume() }
        else { microphoneChannel?.pause() }
    }

    @discardableResult
    func stop() -> String {
        generation = UUID()
        timer?.invalidate()
        timer = nil
        channels.forEach { $0.stop() }
        channels = []
        microphoneChannel = nil
        isRunning = false
        return text
    }
}

@MainActor
private final class LiveSpeechChannel {
    let recognizer: SFSpeechRecognizer
    let sink: LiveAudioSink
    let elapsed: () -> Double
    var onText: ((UUID, Double, String) -> Void)?
    var onFailure: (() -> Void)?
    private var task: SFSpeechRecognitionTask?
    private var restart: Task<Void, Never>?
    private var token = UUID()
    private var active = false
    private var paused = false
    private var failures = 0

    init(recognizer: SFSpeechRecognizer, sink: LiveAudioSink, elapsed: @escaping () -> Double) {
        self.recognizer = recognizer
        self.sink = sink
        self.elapsed = elapsed
        sink.onFormatChange = { [weak self] in Task { @MainActor in self?.rotate() } }
    }

    func start() { active = true; beginRequest() }
    func pause() { paused = true; cancelRequest() }
    func resume() { paused = false; beginRequest() }
    func rotate() { cancelRequest(); beginRequest() }
    func stop() { active = false; cancelRequest(); sink.onFormatChange = nil }

    private func cancelRequest() {
        token = UUID()
        restart?.cancel()
        restart = nil
        sink.replaceRequest(nil)
        task?.cancel()
        task = nil
    }

    private func beginRequest() {
        guard active, !paused, task == nil else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        let current = UUID()
        token = current
        let start = elapsed()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.token == current, self.active else { return }
                if let result {
                    self.failures = 0
                    self.onText?(current, start + (result.bestTranscription.segments.first?.timestamp ?? 0), result.bestTranscription.formattedString)
                }
                if error != nil || result?.isFinal == true {
                    self.sink.replaceRequest(nil)
                    self.task = nil
                    self.token = UUID()
                    if error != nil { self.failures += 1 }
                    if self.failures >= 3 { self.onFailure?() }
                    let delay = UInt64(min(30, max(1, self.failures * 2))) * 1_000_000_000
                    self.restart = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: delay)
                        guard !Task.isCancelled else { return }
                        self?.beginRequest()
                    }
                }
            }
        }
        sink.replaceRequest(request)
    }
}

/// A separate, transient input tap feeds previews for AVAudioRecorder sessions.
/// Call captures use their existing tap and processed mic buffers instead.
final class MicrophonePreviewInput {
    private let engine = AVAudioEngine()
    private var installed = false
    func start(sink: LiveAudioSink) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicTrackRecorder.MicError.invalidInputFormat }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in sink.append(buffer) }
        installed = true
        do { try engine.start() } catch { stop(); throw error }
    }
    func stop() {
        if installed { engine.inputNode.removeTap(onBus: 0) }
        installed = false
        engine.stop()
    }
}

struct LiveTranscriptView: View {
    @ObservedObject var transcriber: LiveTranscriber
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live Transcript").font(.headline)
                Spacer()
                Button("Copy Preview") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcriber.text, forType: .string)
                }
                .disabled(transcriber.entries.isEmpty)
            }
            Text(transcriber.status).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(transcriber.entries.sorted { $0.startedAt < $1.startedAt }) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(entry.source) · \(TranscriptFormatter.timestamp(entry.startedAt))")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
    }
}
