import AVFoundation
import Foundation

/// Only audio and service control frames go to Deepgram. Never attach calendar
/// data, recording titles, or API keys to URLs or diagnostic messages.
enum DeepgramLiveRequest {
    static func make(apiKey: String, language: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else {
            throw DeepgramClient.DeepgramError.invalidKey
        }
        var url = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        url.queryItems = [
            .init(name: "model", value: "nova-3"),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "channels", value: "1"),
            .init(name: "interim_results", value: "true"),
            .init(name: "smart_format", value: "true"),
            .init(name: "endpointing", value: "300"),
            .init(name: "mip_opt_out", value: "true"),
            .init(name: "language", value: language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "multi" : language.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 20
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        return request
    }
}

@MainActor
protocol LiveWebSocket: AnyObject {
    var httpStatus: Int? { get }
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel()
}

@MainActor
final class DeepgramWebSocket: LiveWebSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    var httpStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }
    init(request: URLRequest) {
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1_048_576
    }
    func resume() { task.resume() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func cancel() { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
}

struct DeepgramLiveResult: Decodable {
    let type: String
    let start: Double?
    let is_final: Bool?
    let channel: Channel?
    struct Channel: Decodable { let alternatives: [Alternative] }
    struct Alternative: Decodable { let transcript: String }
}

/// Convert every capture format to the exact format advertised to the service.
/// Each sink owns its converter; a device switch recreates it without resetting
/// the transcript or changing the format of an open network stream.
final class LivePCMEncoder {
    static let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func encode(_ input: AVAudioPCMBuffer) throws -> Data {
        guard input.frameLength > 0, input.format.sampleRate > 0, input.format.channelCount > 0 else { return Data() }
        if sourceFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: Self.output)
            converter?.primeMethod = .none
            sourceFormat = input.format
        }
        guard let converter else { throw LiveStreamError.audioFormat }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.output, frameCapacity: capacity) else { throw LiveStreamError.audioFormat }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, result != .error, let samples = output.int16ChannelData else { throw LiveStreamError.audioFormat }
        return Data(bytes: samples[0], count: Int(output.frameLength) * 2)
    }

    func flush() throws -> Data {
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: Self.output, frameCapacity: 4096) else { return Data() }
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            status.pointee = .endOfStream; return nil
        }
        guard error == nil, result != .error, let samples = output.int16ChannelData else { throw LiveStreamError.audioFormat }
        self.converter = nil
        sourceFormat = nil
        return Data(bytes: samples[0], count: Int(output.frameLength) * 2)
    }
}

enum LiveStreamError: Error, Equatable {
    case audioFormat, bufferOverflow, invalidResponse, service
}

/// A bounded queue prevents a slow/disconnected service from growing memory or
/// blocking audio capture. The audio files are written independently of this.
final class LiveAudioSink {
    struct Packet { let data: Data; let capturedAt: TimeInterval }
    private let lock = NSLock()
    private var encoder = LivePCMEncoder()
    private var packets: [Packet] = []
    private var byteCount = 0
    private var accepting = false
    private var failure: LiveStreamError?
    static let maximumBytes = 160_000 // Five seconds of 16 kHz mono PCM16.

    func start() { lock.withLock { packets = []; byteCount = 0; failure = nil; encoder = LivePCMEncoder(); accepting = true } }
    func end() {
        lock.withLock {
            guard accepting else { return }
            accepting = false
            if let data = try? encoder.flush(), !data.isEmpty, byteCount + data.count <= Self.maximumBytes {
                packets.append(Packet(data: data, capturedAt: ProcessInfo.processInfo.systemUptime))
                byteCount += data.count
            }
        }
    }
    func discard() { lock.withLock { accepting = false; packets = []; byteCount = 0; failure = nil } }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard accepting, failure == nil else { return }
            do {
                let data = try encoder.encode(buffer)
                guard !data.isEmpty else { return }
                guard byteCount + data.count <= Self.maximumBytes else {
                    failure = .bufferOverflow; packets = []; byteCount = 0; return
                }
                packets.append(Packet(data: data, capturedAt: ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / buffer.format.sampleRate))
                byteCount += data.count
            } catch { failure = .audioFormat }
        }
    }
    func next() throws -> Packet? {
        try lock.withLock {
            if let failure { throw failure }
            guard !packets.isEmpty else { return nil }
            let packet = packets.removeFirst()
            byteCount -= packet.data.count
            return packet
        }
    }
}

/// Diagnostics are deliberately metadata-only, bounded, and readable without
/// Console/admin access. Never pass service payloads, speech text, or URLs here.
enum LiveDiagnostics {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/V2T/live-transcription.log")
    private static let queue = DispatchQueue(label: "V2T.live-diagnostics")
    static func write(_ event: String) {
        queue.async {
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber, size.intValue > 256_000 {
                    try Data().write(to: url)
                }
                if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("\(Date().ISO8601Format()) \(event)\n".utf8))
            } catch { /* Diagnostics must never interrupt recording. */ }
        }
    }
}
