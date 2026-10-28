import AVFoundation
import CoreAudio
import Testing
@testable import V2T

struct CaptureHealthTests {
    @Test func updatingChromeProcessesPreservesTapIdentityAndScope() throws {
        guard #available(macOS 14.4, *) else { return }
        let original = CATapDescription(stereoMixdownOfProcesses: [1, 2])
        original.uuid = UUID()
        original.name = "Test capture"
        original.isPrivate = true
        original.muteBehavior = .unmuted
        let updated = ProcessTap.appDescription(updating: original, processes: [2, 3])
        #expect(updated.uuid == original.uuid)
        #expect(updated.processes == [2, 3])
        #expect(original.processes == [1, 2])
        #expect(!updated.isExclusive && updated.isMixdown && !updated.isMono)
        #expect(updated.isPrivate && updated.muteBehavior == .unmuted)
    }
    @Test func silenceIsTemporaryInformationAndResetsWhenSoundReturns() {
        let signal = CaptureSignalMonitor()
        #expect(!signal.isQuiet(now: 9, activeSince: 0))
        #expect(signal.isQuiet(now: 11, activeSince: 0))
        signal.ingest(peak: 0.02, now: 12)
        #expect(!signal.isQuiet(now: 12, activeSince: 0))
        #expect(signal.isQuiet(now: 22, activeSince: 0))
        #expect(!signal.isQuiet(now: 100, activeSince: 99)) // Resume grace.
        signal.ingest(peak: 0, now: 101)
        #expect(signal.isQuiet(now: 110, activeSince: 99))
    }
    @Test func detectsMissingCallbacksButExcludesPausedTimeAndStartupGrace() {
        let progress = CaptureProgress()
        #expect(!progress.snapshot.isStalled(now: 12, activeSince: 10))
        #expect(progress.snapshot.isStalled(now: 14, activeSince: 10))
        progress.wrote(frames: 48_000, sampleRate: 48_000, now: 15)
        #expect(progress.snapshot.secondsWritten == 1)
        #expect(!progress.snapshot.isStalled(now: 16, activeSince: 10))
        #expect(progress.snapshot.isStalled(now: 19, activeSince: 10))
        #expect(!progress.snapshot.isStalled(now: 100, activeSince: 99))
    }
    @Test func warnsAboutTruncatedCaptureWithoutStretchingAudio() {
        #expect(CaptureValidation.warning(expected: 892.6, actual: 3.22)?.contains("00:00:03") == true)
        #expect(CaptureValidation.warning(expected: 900, actual: 899) == nil)
        #expect(CaptureValidation.warning(expected: 900, actual: 0) != nil)
        #expect(TranscriptFormatter.recordingClock(3599.99) == "00:59:59")
        #expect(TranscriptFormatter.recordingClock(3600) == "01:00:00")
        #expect(TranscriptFormatter.recordingClock(7265.9) == "02:01:05")
        #expect(TranscriptFormatter.recordingClock(-1) == "00:00:00")
        #expect(TranscriptFormatter.recordingClock(.nan) == "00:00:00")
    }
    @Test func tapWriterDrainsQueuedAudioAndClosesPlayableFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("V2T-writer-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
        let recorder = try ProcessTapRecorder(fileURL: url, tapFormat: format, captureFormat: .m4a)
        let block = recorder.makeIOBlock(tapFormat: format)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        for channel in 0..<2 { for frame in 0..<1_600 { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) / 10)) * 0.1 } }
        var timestamp = AudioTimeStamp()
        withUnsafePointer(to: &timestamp) { stamp in
            for _ in 0..<150 { block(stamp, buffer.audioBufferList, stamp, buffer.mutableAudioBufferList, stamp) }
        }
        recorder.finish()
        #expect(abs(CaptureValidation.duration(at: url) - 15) < 0.1)
        #expect(abs(recorder.progress.snapshot.secondsWritten - 15) < 0.1)
    }
    @Test func aHealthyTrackDoesNotConcealTheOtherTracksFailure() {
        #expect(CaptureValidation.sessionWarning(expected: 900, callDuration: 3, microphoneExpected: 900, microphoneDuration: 900, mixFailed: false)?.contains("Call audio") == true)
        #expect(CaptureValidation.sessionWarning(expected: 900, callDuration: 900, microphoneExpected: 800, microphoneDuration: 3, mixFailed: false)?.contains("Microphone") == true)
        #expect(CaptureValidation.sessionWarning(expected: 900, callDuration: 900, microphoneExpected: 800, microphoneDuration: 800, mixFailed: false) == nil)
        #expect(CaptureValidation.sessionWarning(expected: 900, callDuration: 900, microphoneExpected: 800, microphoneDuration: 800, mixFailed: true)?.contains("mixdown failed") == true)
    }
}
