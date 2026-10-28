import AVFoundation
import Foundation

struct CaptureNotice: Equatable {
    enum Severity { case information, error }
    let message: String
    let severity: Severity
}

/// Silence is a signal observation, never proof of denied permission or a
/// reason to destroy a healthy tap. Read/write state crosses audio/UI queues.
final class CaptureSignalMonitor {
    private let lock = NSLock()
    private var lastSignal: TimeInterval?
    func ingest(peak: Float, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if peak > 0.00001 { lock.withLock { lastSignal = now } }
    }
    func isQuiet(now: TimeInterval, activeSince: TimeInterval) -> Bool {
        lock.withLock { now - max(lastSignal ?? activeSince, activeSince) >= 10 }
    }
}

/// Successful disk writes, not the running UI timer, determine capture health.
final class CaptureProgress {
    struct Snapshot {
        let lastWrite: TimeInterval?
        let secondsWritten: Double
        let writeError: Int?
        func isStalled(now: TimeInterval, activeSince: TimeInterval) -> Bool {
            now - max(lastWrite ?? activeSince, activeSince) > 3
        }
    }
    private let lock = NSLock()
    private var lastWrite: TimeInterval?
    private var secondsWritten = 0.0
    private var writeError: Int?
    func wrote(frames: AVAudioFrameCount, sampleRate: Double, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard frames > 0, sampleRate > 0 else { return }
        lock.withLock { lastWrite = now; secondsWritten += Double(frames) / sampleRate; writeError = nil }
    }
    func failed(_ error: Error) { lock.withLock { writeError = (error as NSError).code } }
    var snapshot: Snapshot { lock.withLock { Snapshot(lastWrite: lastWrite, secondsWritten: secondsWritten, writeError: writeError) } }
}

enum CaptureValidation {
    static func duration(at url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
    static func warning(expected: Double, actual: Double) -> String? {
        guard expected > 3, actual < expected - max(3, expected * 0.03) else { return nil }
        return "Incomplete recording: only \(TranscriptFormatter.recordingClock(actual)) of audio was saved during a \(TranscriptFormatter.recordingClock(expected)) session. Captured tracks have been preserved."
    }
    /// Validate each source: a full-length mic track can conceal a truncated
    /// call track in the mixed file, and vice versa.
    static func sessionWarning(expected: Double, callDuration: Double, microphoneExpected: Double?, microphoneDuration: Double?, mixFailed: Bool) -> String? {
        var warnings: [String] = []
        if let call = warning(expected: expected, actual: callDuration) { warnings.append("Call audio — " + call) }
        if let expectedMic = microphoneExpected, let actualMic = microphoneDuration,
           let mic = warning(expected: expectedMic, actual: actualMic) { warnings.append("Microphone — " + mic) }
        if mixFailed { warnings.append("Microphone mixdown failed. Playback contains call audio only; the separate captured tracks have been preserved.") }
        return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }
}
