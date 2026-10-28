import AVFoundation
import SwiftUI

struct LiveTranscriptEntry: Identifiable {
    let id: UUID
    let source: String
    var startedAt: Double
    var text: String
}

@MainActor
final class LiveTranscriber: ObservableObject {
    @Published private(set) var entries: [LiveTranscriptEntry] = []
    @Published private(set) var status = "Live transcript is off."
    @Published private(set) var isRunning = false
    @Published private(set) var canRetry = false
    let callSink = LiveAudioSink()
    let micSink = LiveAudioSink()
    private var channels: [DeepgramLiveChannel] = []
    private var microphoneChannel: DeepgramLiveChannel?
    private var states: [String: String] = [:]
    private var isPaused = false
    private var micEnabled = false
    private let makeSocket: (URLRequest) -> LiveWebSocket

    init(makeSocket: ((URLRequest) -> LiveWebSocket)? = nil) {
        self.makeSocket = makeSocket ?? { DeepgramWebSocket(request: $0) }
    }

    var text: String {
        entries.sorted { $0.startedAt < $1.startedAt }.map {
            "\($0.source) [\(TranscriptFormatter.timestamp($0.startedAt))]: \($0.text)"
        }.joined(separator: "\n\n")
    }

    func start(enabled: Bool, apiKey: String, language: String, includesCall: Bool, elapsed: @escaping () -> Double) {
        stop()
        entries = []
        states = [:]
        isPaused = false
        micEnabled = !includesCall
        guard enabled else { status = "Live transcript is off. Enable it in Settings."; return }
        let request: URLRequest
        do { request = try DeepgramLiveRequest.make(apiKey: apiKey, language: language) }
        catch { status = "Add your Deepgram API key in Settings to see live transcripts. Audio is still recording."; return }
        let sources: [(String, LiveAudioSink)] = includesCall
            ? [("Call audio", callSink), ("My microphone", micSink)] : [("Microphone", micSink)]
        for (name, sink) in sources {
            let channel = DeepgramLiveChannel(name: name, request: request, sink: sink, elapsed: elapsed, makeSocket: makeSocket)
            channel.onText = { [weak self] id, start, text in
                guard let self else { return }
                if let index = self.entries.firstIndex(where: { $0.id == id }) {
                    if text.isEmpty { self.entries.remove(at: index) }
                    else { self.entries[index].text = text; self.entries[index].startedAt = start }
                } else if !text.isEmpty {
                    self.entries.append(.init(id: id, source: name, startedAt: start, text: text))
                }
            }
            channel.onStatus = { [weak self] message in
                self?.states[name] = message
                self?.updateStatus()
            }
            channels.append(channel)
            if sink === micSink { microphoneChannel = channel }
        }
        isRunning = true
        for channel in channels {
            if channel === microphoneChannel && !micEnabled { continue }
            channel.resume()
        }
        updateStatus()
    }

    private func updateStatus() {
        if isPaused { status = "Live transcript paused." }
        else {
            let problems = states.keys.sorted().compactMap { name -> String? in
                guard let value = states[name], !value.isEmpty else { return nil }
                return "\(name): \(value)"
            }
            status = problems.isEmpty ? "Deepgram live transcript · wording may update as you speak." : problems.joined(separator: "\n")
        }
        canRetry = isRunning && !isPaused && channels.contains { $0.needsRetry }
    }
    func pause() { isPaused = true; channels.forEach { $0.pause() }; updateStatus() }
    func resume() {
        isPaused = false
        for channel in channels where channel !== microphoneChannel || micEnabled { channel.resume() }
        updateStatus()
    }
    func setMicrophoneEnabled(_ enabled: Bool) {
        micEnabled = enabled
        if enabled && !isPaused { microphoneChannel?.resume() }
        else { microphoneChannel?.pause() }
        updateStatus()
    }
    func retry(apiKey: String, language: String) {
        guard !isPaused else { return }
        let request: URLRequest
        do { request = try DeepgramLiveRequest.make(apiKey: apiKey, language: language) }
        catch { status = "Add your Deepgram API key in Settings, then retry. Audio is still recording."; return }
        for channel in channels where channel.needsRetry { channel.resume(request: request) }
        updateStatus()
    }
    /// Capture stops immediately; give the service a short, bounded window to
    /// finalize its last words before saving the preview alongside the audio.
    func finish() async -> String {
        let finishing = channels
        await withTaskGroup(of: Void.self) { group in
            for channel in finishing { group.addTask { await channel.finish() } }
        }
        return stop()
    }
    @discardableResult
    func stop() -> String {
        channels.forEach { $0.stop() }
        channels = []
        microphoneChannel = nil
        isRunning = false
        canRetry = false
        return text
    }
}

@MainActor
final class DeepgramLiveChannel {
    let name: String
    var onText: ((UUID, Double, String) -> Void)?
    var onStatus: ((String) -> Void)?
    private(set) var needsRetry = false
    private var request: URLRequest
    private let sink: LiveAudioSink
    private let elapsed: () -> Double
    private let makeSocket: (URLRequest) -> LiveWebSocket
    private var socket: LiveWebSocket?
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var generation = UUID()
    private var partialID = UUID()
    private var streamOffset: Double?
    private var active = false
    private var finishing = false
    private var finished = false
    private var failures = 0

    init(name: String, request: URLRequest, sink: LiveAudioSink, elapsed: @escaping () -> Double,
         makeSocket: @escaping (URLRequest) -> LiveWebSocket) {
        self.name = name; self.request = request; self.sink = sink; self.elapsed = elapsed; self.makeSocket = makeSocket
    }
    func resume(request: URLRequest? = nil) {
        guard !active || needsRetry else { return }
        if let request { self.request = request }
        failures = 0; needsRetry = false; active = true
        open()
    }
    func pause() { active = false; disconnect(); needsRetry = false; onStatus?("") }
    func stop() { active = false; disconnect(); needsRetry = false }

    func finish() async {
        guard active, socket != nil else { stop(); return }
        finishing = true
        sink.end()
        retryTask?.cancel()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !finished && socket != nil && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if Task.isCancelled { break }
        }
        stop()
    }

    private func disconnect() {
        generation = UUID()
        sender?.cancel(); sender = nil
        receiver?.cancel(); receiver = nil
        retryTask?.cancel(); retryTask = nil
        sink.discard()
        socket?.cancel(); socket = nil
    }
    private func open() {
        disconnect()
        guard active else { return }
        finishing = false; finished = false; streamOffset = nil; partialID = UUID()
        let token = generation
        let connection = makeSocket(request)
        socket = connection
        sink.start()
        onStatus?("Connecting to Deepgram…")
        LiveDiagnostics.write("\(name): connecting")
        connection.resume()
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive()
                    guard let self, self.generation == token else { return }
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    let result = try JSONDecoder().decode(DeepgramLiveResult.self, from: data)
                    if result.type == "Error" { throw LiveStreamError.service }
                    if result.type == "Metadata", self.finishing { self.finished = true; return }
                    guard result.type == "Results", let start = result.start, start.isFinite, start >= 0,
                          let text = result.channel?.alternatives.first?.transcript else { continue }
                    self.failures = 0
                    self.onStatus?("")
                    self.onText?(self.partialID, (self.streamOffset ?? self.elapsed()) + start, text)
                    if result.is_final == true { self.partialID = UUID() }
                }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.failed(error, httpStatus: connection.httpStatus)
            }
        }
        sender = Task { [weak self] in
            var lastSend = ProcessInfo.processInfo.systemUptime
            do {
                while !Task.isCancelled {
                    guard let self, self.generation == token else { return }
                    if let packet = try self.sink.next() {
                        if self.streamOffset == nil {
                            self.streamOffset = max(0, self.elapsed() - (ProcessInfo.processInfo.systemUptime - packet.capturedAt))
                        }
                        try await connection.send(.data(packet.data))
                        guard self.generation == token else { return }
                        lastSend = ProcessInfo.processInfo.systemUptime
                        self.onStatus?("")
                    } else if self.finishing {
                        try await connection.send(.string(#"{"type":"CloseStream"}"#))
                        return
                    } else {
                        if ProcessInfo.processInfo.systemUptime - lastSend >= 3 {
                            try await connection.send(.string(#"{"type":"KeepAlive"}"#))
                            lastSend = ProcessInfo.processInfo.systemUptime
                        }
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.failed(error, httpStatus: connection.httpStatus)
            }
        }
    }
    private func failed(_ error: Error, httpStatus: Int?) {
        let wasFinishing = finishing
        disconnect()
        guard active, !wasFinishing else { finished = true; return }
        failures += 1
        let nsError = error as NSError
        LiveDiagnostics.write("\(name): failure http=\(httpStatus ?? 0) domain=\(nsError.domain) code=\(nsError.code) attempt=\(failures)")
        let permanent = [400, 401, 402, 403, 429].contains(httpStatus ?? 0) || (error as? LiveStreamError) == .audioFormat
        if permanent || failures > 3 {
            needsRetry = true
            let message: String
            switch httpStatus {
            case 401, 403: message = "Check the Deepgram API key and permissions in Settings."
            case 402, 429: message = "Check your Deepgram account balance or usage limit."
            case 400: message = "Check the Deepgram language code in Settings."
            default: message = "Live connection unavailable. Check your network and retry."
            }
            onStatus?(message + " Audio is still recording.")
        } else {
            onStatus?("Connection interrupted; reconnecting… Audio is still recording.")
            let token = generation
            let delay = UInt64(1 << (failures - 1)) * 1_000_000_000
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self, self.generation == token, self.active else { return }
                self.open()
            }
        }
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
    @EnvironmentObject private var settings: AppSettings
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
            if transcriber.canRetry {
                Button("Retry Live Transcript") { transcriber.retry(apiKey: settings.deepgramAPIKey, language: settings.deepgramLanguageCode) }
            }
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
