import AVFoundation
import Foundation
import Testing
@testable import V2T

struct LiveAudioTests {
    @Test func requestUsesDeepgramStreamingAndKeepsCredentialsOutOfURL() throws {
        let request = try DeepgramLiveRequest.make(apiKey: " test-key ", language: "")
        #expect(request.url?.scheme == "wss")
        #expect(request.url?.host == "api.deepgram.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token test-key")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        for (name, value) in ["model": "nova-3", "interim_results": "true", "mip_opt_out": "true", "encoding": "linear16", "sample_rate": "16000", "channels": "1", "language": "multi"] {
            #expect(query.contains(.init(name: name, value: value)))
        }
        #expect(!request.url!.absoluteString.contains("test-key"))
        #expect(throws: DeepgramClient.DeepgramError.invalidKey) { try DeepgramLiveRequest.make(apiKey: "x\r\ny", language: "en") }
    }
    @Test func encoderResamplesStereoAndHandlesDeviceFormatChanges() throws {
        let encoder = LivePCMEncoder()
        for rate in [48_000.0, 44_100.0, 16_000.0] {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 10)))
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 { for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = 0.2 } }
            let encoded = try encoder.encode(buffer) + encoder.flush()
            #expect(abs(encoded.count - 3_200) < 200)
            #expect(encoded.contains { $0 != 0 })
            #expect(buffer.floatChannelData![0][100] == 0.2)
        }
    }
    @Test func queueIsBoundedAndDiscardPreventsPausedOrMutedAudioSending() throws {
        let sink = LiveAudioSink()
        let buffer = try liveBuffer()
        sink.append(buffer)
        #expect(try sink.next() == nil)
        sink.start()
        sink.append(buffer)
        #expect(try sink.next()?.data.isEmpty == false)
        for _ in 0..<100 { sink.append(buffer) }
        #expect(throws: LiveStreamError.bufferOverflow) { try sink.next() }
        sink.discard()
        sink.append(buffer)
        #expect(try sink.next() == nil)
        sink.start()
        sink.append(buffer)
        sink.end()
        #expect(try sink.next() != nil) // Drain the last words at stop.
        #expect(try sink.next() == nil)
    }
}

@MainActor
struct LiveTranscriptionTests {
    @Test func updatesInterimTextThenPreservesFinalTextWithoutDuplicates() async throws {
        var sockets: [MockLiveSocket] = []
        let live = LiveTranscriber { _ in let socket = MockLiveSocket(); sockets.append(socket); return socket }
        live.start(enabled: true, apiKey: "test", language: "en", includesCall: true, elapsed: { 10 })
        defer { live.stop() }
        #expect(sockets.count == 1) // Mic starts off; no second paid stream yet.
        live.callSink.append(try liveBuffer())
        try await waitFor { !sockets[0].sent.isEmpty }
        sockets[0].result("Hello", final: false)
        try await waitFor { live.entries.count == 1 }
        sockets[0].result("Hello, team.", final: true)
        try await waitFor { live.entries.first?.text == "Hello, team." }
        #expect(live.entries.count == 1)
        sockets[0].result("Next point.", start: 2, final: true)
        try await waitFor { live.entries.count == 2 }
        #expect(live.text.contains("Hello, team."))
        #expect(live.entries[1].startedAt > live.entries[0].startedAt)
        live.setMicrophoneEnabled(true)
        #expect(sockets.count == 2)
        live.setMicrophoneEnabled(false)
        #expect(sockets[1].cancelled)
        live.pause()
        #expect(sockets[0].cancelled)
        live.resume()
        #expect(sockets.count == 3) // Muted mic stays disconnected after resume.
        #expect(live.entries.count == 2)
    }
    @Test func stopDrainsAudioAndSavesServiceFinalWords() async throws {
        let socket = MockLiveSocket()
        socket.finalizeText = "Last words."
        let live = LiveTranscriber { _ in socket }
        live.start(enabled: true, apiKey: "test", language: "en", includesCall: false, elapsed: { 0 })
        live.micSink.append(try liveBuffer())
        let saved = await live.finish()
        #expect(saved.contains("Last words."))
        #expect(socket.cancelled)
        #expect(socket.sent.contains { if case .string(let s) = $0 { return s.contains("CloseStream") }; return false })
        #expect(!live.isRunning)
    }
    @Test func authFailureIsActionableAndDoesNotRetryContinuously() async throws {
        var count = 0
        let socket = MockLiveSocket()
        socket.httpStatus = 401
        let live = LiveTranscriber { _ in count += 1; return socket }
        live.start(enabled: true, apiKey: "test", language: "en", includesCall: false, elapsed: { 0 })
        defer { live.stop() }
        socket.fail()
        try await waitFor { live.canRetry }
        #expect(live.status.contains("API key"))
        #expect(count == 1)
        #expect(live.isRunning)
    }
    @Test func missingKeyOrDisabledLiveModeDoesNotCreateSockets() {
        var count = 0
        let live = LiveTranscriber { _ in count += 1; return MockLiveSocket() }
        live.start(enabled: true, apiKey: "", language: "en", includesCall: false, elapsed: { 0 })
        #expect(!live.isRunning && count == 0)
        #expect(live.status.contains("API key"))
        live.start(enabled: false, apiKey: "test", language: "en", includesCall: false, elapsed: { 0 })
        #expect(!live.isRunning && count == 0)
    }
    @Test func retryUsesTheCorrectedKeyAndLanguage() async throws {
        var requests: [URLRequest] = []
        var sockets: [MockLiveSocket] = []
        let live = LiveTranscriber { request in
            requests.append(request)
            let socket = MockLiveSocket(); sockets.append(socket); return socket
        }
        live.start(enabled: true, apiKey: "old-test", language: "en", includesCall: false, elapsed: { 0 })
        defer { live.stop() }
        sockets[0].httpStatus = 401
        sockets[0].fail()
        try await waitFor { live.canRetry }
        live.retry(apiKey: "corrected-test", language: "es")
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Token corrected-test")
        #expect(requests.last?.url?.query?.contains("language=es") == true)
    }
}

private func liveBuffer() throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
    buffer.frameLength = 1_600
    for frame in 0..<1_600 { buffer.floatChannelData![0][frame] = 0.1 }
    return buffer
}

@MainActor
private func waitFor(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(predicate())
}

@MainActor
private final class MockLiveSocket: LiveWebSocket {
    var httpStatus: Int? = 101
    var cancelled = false
    var sent: [URLSessionWebSocketTask.Message] = []
    var finalizeText: String?
    var incoming: [Result<URLSessionWebSocketTask.Message, Error>] = []
    var pending: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        sent.append(message)
        if case .string(let s) = message, s.contains("CloseStream") {
            if let finalizeText { result(finalizeText, final: true) }
            deliver(.success(.string(#"{"type":"Metadata"}"#)))
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !incoming.isEmpty { return try incoming.removeFirst().get() }
        if cancelled { throw CancellationError() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func cancel() { cancelled = true; pending?.resume(throwing: CancellationError()); pending = nil }
    func fail() { deliver(.failure(URLError(.userAuthenticationRequired))) }
    func result(_ text: String, start: Double = 0, final: Bool) {
        let json: [String: Any] = ["type": "Results", "start": start, "is_final": final, "channel": ["alternatives": [["transcript": text]]]]
        deliver(.success(.data(try! JSONSerialization.data(withJSONObject: json))))
    }
    func deliver(_ value: Result<URLSessionWebSocketTask.Message, Error>) {
        if let pending { self.pending = nil; pending.resume(with: value) }
        else { incoming.append(value) }
    }
}
