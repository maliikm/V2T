import AVFoundation
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import V2T

struct TrimSelectionTests {
    @Test func selectionIsOrderedClampedAndFinite() {
        #expect(TrimSelection(duration: 10, start: 0.8, end: 0.2).range == 2...8)
        #expect(TrimSelection(duration: 10, start: -1, end: 2).range == 0...10)
        #expect(TrimSelection(duration: .nan, start: .nan, end: .infinity).range == 0...0)
        #expect(!TrimSelection(duration: 0, start: 0, end: 1).canKeep)
    }

    @Test func fullEmptyAndTinySelectionsCannotDestroyAudio() {
        let full = TrimSelection(duration: 10, start: 0, end: 1)
        #expect(!full.canKeep)
        #expect(!full.canRemove)
        for end in [0.0, 0.019] {
            let tiny = TrimSelection(duration: 10, start: 0, end: end)
            #expect(!tiny.canKeep)
            #expect(!tiny.canRemove)
        }
        let nearlyFull = TrimSelection(duration: 10, start: 0, end: 0.99)
        #expect(nearlyFull.canKeep)
        #expect(!nearlyFull.canRemove)
    }

    @Test func longRecordingsAllowPreciseSubsecondSelections() {
        let selection = TrimSelection(duration: 3600, start: 1800 / 3600, end: 1800.2 / 3600)
        #expect(abs(selection.minimumFraction - 0.2 / 3600) < 1e-12)
        #expect(selection.canKeep)
        #expect(selection.canRemove)
        #expect(abs(selection.selectedDuration - 0.2) < 1e-9)
        #expect(abs(selection.remainingDuration - 3599.8) < 1e-9)
    }

    @Test func timeInputsCannotCrossHandlesOrLeaveTheRecording() {
        let selection = TrimSelection(duration: 10, start: 0.2, end: 0.8)
        #expect(selection.movingStart(to: -10) == 0)
        #expect(selection.movingEnd(to: 100) == 1)
        #expect(abs(selection.movingStart(to: 9) - 0.78) < 1e-9)
        #expect(abs(selection.movingEnd(to: 1) - 0.22) < 1e-9)
    }

    @Test func markdownRetainsSpeakerNamesAndTimestampsWithoutAppBranding() {
        let transcript = Transcript(sourceFileName: "meeting.wav", languageCode: "en",
            segments: [TranscriptSegment(speakerId: "speaker_0", start: 62, end: 63, text: "Hello.")],
            speakerIds: ["speaker_0"], words: nil)
        let markdown = TranscriptFormatter.markdown(transcript, names: ["speaker_0": "Maliik"])
        #expect(markdown.contains("# Meeting transcript: meeting.wav"))
        #expect(markdown.contains("**Maliik** _[1:02]_: Hello."))
        #expect(!markdown.contains("Claude"))
    }
}

/// Generated silent WAV fixtures exercise AVFoundation, not capture hardware.
@MainActor
struct TrimAudioTests {
    /// Optional visual smoke check, isolated from the user's running app/library.
    private func renderPreviews(session: AudioEditSession, recording: Recording, store: LibraryStore,
                                player: AudioPlayerController) throws {
        guard let directory = ProcessInfo.processInfo.environment["V2T_TRIM_PREVIEW_DIRECTORY"] else { return }
        _ = NSApplication.shared
        session.showTrimTool = true
        session.selectionStart = 0.2
        session.selectionEnd = 0.8
        defer { session.selectionStart = 0; session.selectionEnd = 1 }
        for width in [900, 430] {
            let content = EditModeView(session: session, recording: recording, onDone: {})
                .environmentObject(store).environmentObject(player)
                .frame(width: CGFloat(width), height: 480).background(Color.white)
            let view = NSHostingView(rootView: content)
            view.appearance = NSAppearance(named: .aqua)
            view.frame = NSRect(x: 0, y: 0, width: width, height: 480)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("trim-\(width).png"))
        }
    }

    private func writeAudio(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        samples.update(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    @Test func keepUndoRemoveAndSavePreserveAudioAndRetimeTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("V2TTrimTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("generated.wav")
        try writeAudio(to: source)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let imported = await store.importAudio(from: source)
        let recording = try #require(imported)
        let original = try Data(contentsOf: store.audioURL(for: recording))
        let words = (0..<4).map { index in
            TranscriptWord(text: "Word\(index)", start: Double(index) + 0.25,
                end: Double(index) + 0.5, speakerId: "speaker_0", isEvent: false)
        }
        var transcript = Transcript.build(words: words, sourceFileName: "generated.wav", languageCode: "en")
        transcript.provider = "deepgram"
        #expect(store.saveTranscript(transcript, for: recording.id))
        let player = AudioPlayerController()
        let session = AudioEditSession()
        let waveform = WaveformData(samples: (0..<1000).map { Float(0.1 + abs(sin(Double($0) * 0.22)) * 0.3) }, duration: 4)
        session.begin(recording: recording, store: store, player: player, initialWaveform: waveform)
        defer { session.end(commit: false, store: store) }
        try renderPreviews(session: session, recording: recording, store: store, player: player)

        // Removing all audio is rejected without touching either working or saved audio.
        await session.applyTrim(keepSelection: false)
        #expect(session.error != nil)
        #expect(!session.hasEdits)
        session.setSelectionStart(seconds: 1)
        session.setSelectionEnd(seconds: 3)
        await session.applyTrim(keepSelection: true)
        #expect(session.error == nil)
        #expect(session.hasEdits && session.canUndo)
        #expect(abs(session.workingDuration - 2) < 0.06)
        #expect(try Data(contentsOf: store.audioURL(for: recording)) == original)

        session.undo()
        for _ in 0..<500 where session.isProcessing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!session.isProcessing)
        #expect(!session.hasEdits && !session.canUndo)
        #expect(abs(session.workingDuration - 4) < 0.01)
        #expect(session.selectionStart == 0 && session.selectionEnd == 1)

        session.setSelectionStart(seconds: 1)
        session.setSelectionEnd(seconds: 3)
        await session.applyTrim(keepSelection: false)
        #expect(session.error == nil)
        #expect(abs(session.workingDuration - 2) < 0.06)
        session.end(commit: true, store: store)
        #expect(!session.isActive)
        let saved = try #require(store.recording(with: recording.id))
        #expect(abs(saved.duration - 2) < 0.06)
        let retimed = try #require(store.transcript(for: recording.id))
        #expect(retimed.words?.map(\.text) == ["Word0", "Word3"])
        #expect(retimed.words?.last?.start == 1.25)
        #expect(retimed.provider == "deepgram")
        let audioDuration = await AudioEditor.duration(of: store.audioURL(for: saved))
        #expect(abs(audioDuration - 2) < 0.06)
    }

    @Test(arguments: [false, true])
    func cancellingTrimPreservesOriginalAndCannotMutateNextSession(duringExport: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("V2TTrimCancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("generated.wav")
        try writeAudio(to: source)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let imported = await store.importAudio(from: source)
        let recording = try #require(imported)
        let original = try Data(contentsOf: store.audioURL(for: recording))
        let transcript = Transcript(sourceFileName: "generated.wav", languageCode: "en",
            segments: [TranscriptSegment(speakerId: "speaker_0", start: 1, end: 2, text: "Unchanged")],
            speakerIds: ["speaker_0"], words: nil)
        #expect(store.saveTranscript(transcript, for: recording.id))
        let player = AudioPlayerController()
        let session = AudioEditSession()
        session.begin(recording: recording, store: store, player: player, initialWaveform: nil)
        session.showTrimTool = true
        session.setSelectionStart(seconds: 1)
        session.setSelectionEnd(seconds: 3)
        let task = Task { await session.applyTrim(keepSelection: true) }
        if duringExport {
            for _ in 0..<100 where !session.isProcessing && !session.hasEdits { await Task.yield() }
            #expect(session.isProcessing)
        } else {
            await task.value
            #expect(session.hasEdits)
        }
        session.end(commit: false, store: store)
        #expect(!session.isActive && !session.hasEdits)
        session.begin(recording: recording, store: store, player: player, initialWaveform: nil)
        await task.value
        #expect(session.isActive && !session.hasEdits && !session.isProcessing)
        #expect(session.error == nil)
        #expect(session.workingDuration == recording.duration)
        #expect(try Data(contentsOf: store.audioURL(for: recording)) == original)
        #expect(store.transcript(for: recording.id) == transcript)
        session.end(commit: false, store: store)
    }
}
