import AVFoundation
import Testing
@testable import V2T

@Suite struct CaptureTimelineTests {
    @Test func testLateMicExcludesEarlierPauses() {
        var timeline = CaptureTimeline()
        timeline.pause(at: 20)
        timeline.resume(at: 50)
        timeline.pause(at: 60)
        timeline.resume(at: 70)
        expectEqual(timeline.offset(from: 10, to: 80), 30)
        expectEqual(timeline.offset(from: 80, to: 10), -30)
    }
    @Test func testOpenAndOverlappingPauseBoundaries() {
        var timeline = CaptureTimeline()
        timeline.pause(at: 20)
        timeline.pause(at: 25)
        expectEqual(timeline.offset(from: 10, to: 30), 10)
        timeline.resume(at: 40)
        expectEqual(timeline.offset(from: 30, to: 50), 10)
        expectEqual(timeline.offset(from: 10, to: 15), 5)
    }
}

@Suite struct MicrophoneTrackWriterTests {
    @Test func testMutePreservesLengthAndSilencesAllChannelsWhilePauseDropsTime() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let writer = MicrophoneTrackWriter(file: try AVAudioFile(forWriting: url, settings: format.settings))
        let buffer = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        for channel in 0..<2 {
            for i in 0..<480 { buffer.floatChannelData![channel][i] = channel == 0 ? 0.4 : -0.3 }
        }
        writer.isPaused = true
        expectFalse(try writer.append(buffer, hostTime: 1))
        expectNil(writer.firstBufferHostTime)
        writer.isPaused = false
        expectTrue(try writer.append(buffer, hostTime: 2))
        writer.isMuted = true
        expectFalse(try writer.append(buffer, hostTime: 3))
        writer.isPaused = true
        expectFalse(try writer.append(buffer, hostTime: 4))
        writer.isPaused = false
        writer.isMuted = false
        expectTrue(try writer.append(buffer, hostTime: 5))
        writer.finish()
        expectFalse(try writer.append(buffer, hostTime: 6))
        expectEqual(writer.firstBufferHostTime, 2)
        let read = try AVAudioFile(forReading: url)
        expectEqual(read.length, 1440)
        let result = try require(AVAudioPCMBuffer(pcmFormat: read.processingFormat, frameCapacity: 1440))
        try read.read(into: result)
        for channel in 0..<2 {
            expectNotEqual(result.floatChannelData![channel][100], 0)
            for frame in 480..<960 { expectEqual(result.floatChannelData![channel][frame], 0) }
            expectNotEqual(result.floatChannelData![channel][1100], 0)
        }
        // Muting never mutates the engine-owned source buffer.
        expectEqual(buffer.floatChannelData![0][100], 0.4)
    }
}

@Suite struct SpeakerCorrectionTests {
    static func transcript() -> Transcript {
        Transcript(sourceFileName: "Call", languageCode: "eng", segments: [
            .init(speakerId: "a", start: 0, end: 2, text: "First passage"),
            .init(speakerId: "a", start: 2, end: 4, text: "Second passage"),
            .init(speakerId: "b", start: 4, end: 6, text: "Response"),
        ], speakerIds: ["a", "b"], words: [
            .init(text: "First", start: 0, end: 1, speakerId: "a", isEvent: false),
            .init(text: "passage", start: 1, end: 2, speakerId: "a", isEvent: false),
            .init(text: "Second", start: 2, end: 3, speakerId: "a", isEvent: false),
            .init(text: "passage", start: 3, end: 4, speakerId: "a", isEvent: false),
            .init(text: "Response", start: 4, end: 6, speakerId: "b", isEvent: false),
        ])
    }
    @Test func testOnlyChosenPassageChangesIncludingWordBoundary() {
        var original = Self.transcript()
        original.provider = "deepgram"
        original.model = "nova-3"
        let updated = original.reassigningSpeaker(at: 0, to: "b")
        expectEqual(updated.provider, "deepgram")
        expectEqual(updated.model, "nova-3")
        expectEqual(updated.segments.map(\.speakerId), ["b", "a", "b"])
        expectEqual(updated.words?.map(\.speakerId), ["b", "b", "a", "a", "b"])
        expectEqual(updated.segments.map(\.id), original.segments.map(\.id))
        expectEqual(updated.segments.map(\.text), original.segments.map(\.text))
        expectEqual(updated.speakerIds, original.speakerIds)
    }
    @Test func testCorrectionsSurviveTrimming() {
        let updated = Self.transcript().reassigningSpeaker(at: 0, to: "b").retimed(keepingOnly: 0...1.9)
        expectEqual(updated.words?.map(\.speakerId), ["b", "b"])
        expectTrue(updated.segments.allSatisfy { $0.speakerId == "b" })
    }
    @Test func testReassignAllAndLegacyWithoutWords() {
        let original = Self.transcript()
        let all = original.reassigningSpeaker(at: 0, to: "b", allOccurrences: true)
        expectTrue(all.segments.allSatisfy { $0.speakerId == "b" })
        expectTrue(all.words!.allSatisfy { $0.speakerId == "b" })
        let legacy = Transcript(sourceFileName: "Old", languageCode: nil, segments: original.segments, speakerIds: original.speakerIds, words: nil)
        expectEqual(legacy.reassigningSpeaker(at: 1, to: "b").segments.map(\.speakerId), ["a", "b", "b"])
    }
    @Test func testInvalidTargetIsNoOp() {
        let original = Self.transcript()
        expectEqual(original.reassigningSpeaker(at: -1, to: "b"), original)
        expectEqual(original.reassigningSpeaker(at: 0, to: "missing"), original)
    }
}

@Suite struct CalendarMatchingTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    @Test func testChoosesOverlappingMeetingAndIgnoresUnrelatedTime() {
        let end = start.addingTimeInterval(3600)
        let meeting = CalendarMeeting(title: "Weekly Production", start: start, end: end)
        let old = CalendarMeeting(title: "Yesterday", start: start.addingTimeInterval(-7200), end: start.addingTimeInterval(-3600))
        let ranked = RecordingTitleMatcher.ranked([old, meeting], start: start, end: end, transcript: "")
        expectEqual(ranked.count, 1)
        expectEqual(RecordingTitleMatcher.confidentMatch(ranked), meeting)
    }
    @Test func testAmbiguousCalendarEventsNeedTranscriptEvidence() {
        let end = start.addingTimeInterval(3600)
        let a = CalendarMeeting(title: "Budget Planning", start: start, end: end)
        let b = CalendarMeeting(title: "Creative Review", start: start, end: end)
        expectNil(RecordingTitleMatcher.confidentMatch(RecordingTitleMatcher.ranked([a,b], start: start, end: end, transcript: "")))
        expectEqual(RecordingTitleMatcher.confidentMatch(RecordingTitleMatcher.ranked([a,b], start: start, end: end, transcript: "We are planning the budget today.")), a)
    }
    @Test func testRejectsEmptyLongOrMultilineModelOutput() {
        expectNil(RecordingTitleMatcher.cleanTitle("   "))
        expectNil(RecordingTitleMatcher.cleanTitle(String(repeating: "x", count: 91)))
        expectNil(RecordingTitleMatcher.cleanTitle("Title\nExplanation"))
        expectEqual(RecordingTitleMatcher.cleanTitle(" \"Production Check-in\" "), "Production Check-in")
    }
}

@MainActor
@Suite struct LibraryWorkflowTests {
    @Test func testSpeakerChangesPersistAndUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let file = try store.makeCaptureDirectory().appendingPathComponent("test.m4a")
        try Data().write(to: file)
        let recording = try require(store.addRecordedFile(at: file, duration: 6, startedAt: Date()))
        expectTrue(store.saveTranscript(SpeakerCorrectionTests.transcript(), for: recording.id))
        store.setSpeakerNames(["a": "Alice", "b": "Bob"], for: recording.id)
        store.reassignSpeaker(for: recording.id, segmentIndex: 0, to: "b")
        let reopened = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        expectEqual(reopened.transcript(for: recording.id)?.segments.first?.speakerId, "b")
        expectEqual(reopened.recording(with: recording.id)?.speakerNames["b"], "Bob")
        expectTrue(TranscriptFormatter.plainText(reopened.transcript(for: recording.id)!, names: ["b":"Bob"]).hasPrefix("Bob"))
        store.undoSpeakerEdit(for: recording.id)
        expectEqual(store.transcript(for: recording.id)?.segments.first?.speakerId, "a")
    }
    @Test func testAutomaticTitleNeverOverwritesManualRenameOrStaleResult() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let file = try store.makeCaptureDirectory().appendingPathComponent("test.m4a")
        try Data().write(to: file)
        let recording = try require(store.addRecordedFile(at: file, duration: 6, startedAt: Date()))
        expectFalse(store.applyAutomaticTitle("Meeting", source: "AI", for: recording.id, expectedTitle: "stale"))
        expectTrue(store.applyAutomaticTitle("Meeting", source: "AI", for: recording.id, expectedTitle: recording.title))
        store.rename(recording.id, to: "My Title")
        expectFalse(store.applyAutomaticTitle("New AI Title", source: "AI", for: recording.id, expectedTitle: "My Title"))
        expectEqual(store.recording(with: recording.id)?.title, "My Title")
    }
    @Test func testLegacyMetadataLoadsAndAlwaysShowsActualDate() throws {
        let original = Recording(title: "Weekly Meeting", createdAt: Date(), audioFileName: "audio.m4a")
        let data = try JSONEncoder().encode(original)
        let loaded = try JSONDecoder().decode(Recording.self, from: data)
        expectNil(loaded.automaticTitleEligible)
        expectEqual(loaded.dateLabel, original.createdAt.formatted(date: .abbreviated, time: .omitted))
        expectFalse(["Today", "Yesterday"].contains(loaded.dateLabel))
        expectFalse(loaded.timeLabel.isEmpty)
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T) { #expect(actual == expected) }
private func expectNotEqual<T: Equatable>(_ actual: T, _ expected: T) { #expect(actual != expected) }
private func expectTrue(_ value: Bool) { #expect(value) }
private func expectFalse(_ value: Bool) { #expect(!value) }
private func expectNil<T>(_ value: T?) { #expect(value == nil) }
private func require<T>(_ value: T?) throws -> T { try #require(value) }
private func expectThrows<T>(_ value: @autoclosure () throws -> T) {
    do { _ = try value(); Issue.record("Expected an error") } catch { }
}

@Suite struct MixdownTests {
    @Test func testLateMicrophoneStartsAtItsOffset() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let appURL = folder.appendingPathComponent("app.wav")
        let micURL = folder.appendingPathComponent("mic.wav")
        let outputURL = folder.appendingPathComponent("mix.m4a")
        let format = try require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        func write(_ url: URL, frames: AVAudioFrameCount, audible: Bool) throws {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            for channel in 0..<2 {
                for frame in 0..<Int(frames) {
                    buffer.floatChannelData![channel][frame] = audible ? Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.25 : 0
                }
            }
            try file.write(from: buffer)
        }
        try write(appURL, frames: 48_000, audible: false)
        try write(micURL, frames: 24_000, audible: true)
        _ = try MixdownExporter.export(appURL: appURL, micURL: micURL, micOffsetSeconds: 0.5, outputURL: outputURL)
        let file = try AVAudioFile(forReading: outputURL)
        let result = try require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: result)
        let rate = file.processingFormat.sampleRate
        func peak(_ a: Double, _ b: Double) -> Float {
            (Int(a * rate)..<Int(b * rate)).map { abs(result.floatChannelData![0][$0]) }.max() ?? 0
        }
        #expect(peak(0.1, 0.4) < 0.01)
        #expect(peak(0.6, 0.9) > 0.1)
        #expect(abs(Double(file.length) / rate - 1) < 0.1)
    }
}
