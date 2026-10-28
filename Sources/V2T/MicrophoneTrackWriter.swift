import AVFoundation
import Foundation

/// Serializes mute/pause changes with writes. Muted audio is never saved to
/// the raw mic track either; silence keeps later speech at its original time.
final class MicrophoneTrackWriter {
    private let lock = NSLock()
    let progress: CaptureProgress
    private var file: AVAudioFile?
    private var muted = false
    private var paused = false
    private var firstHostTime: UInt64?

    var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }
    var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }
    var firstBufferHostTime: UInt64? { lock.withLock { firstHostTime } }

    init(file: AVAudioFile, progress: CaptureProgress = CaptureProgress()) { self.file = file; self.progress = progress }

    /// Returns true only for audible mic buffers, for the live transcript.
    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) throws -> Bool {
        try lock.withLock {
            guard let file, !paused, buffer.frameLength > 0 else { return false }
            if firstHostTime == nil { firstHostTime = hostTime }
            if muted {
                guard let silence = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                silence.frameLength = buffer.frameLength
                for channel in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                    if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
                }
                try file.write(from: silence)
            } else {
                try file.write(from: buffer)
            }
            progress.wrote(frames: buffer.frameLength, sampleRate: buffer.format.sampleRate)
            return !muted
        }
    }

    func finish() { lock.withLock { file = nil } }
}
