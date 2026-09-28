import Foundation
import Testing
@testable import V2T

struct RecordingConfigurationTests {
    @Test func exactSelectionSurvivesReorderingAndDoesNotFallBack() throws {
        let selected = AudioProcess(id: "app.one", name: "One", bundleID: "app.one", objectIDs: [1], pids: [], hasActiveOutput: false)
        let other = AudioProcess(id: "app.two", name: "Two", bundleID: "app.two", objectIDs: [2], pids: [], hasActiveOutput: true)
        let config = RecordingConfiguration(source: .application, includesMicrophone: false, appID: selected.id, appName: selected.name)
        #expect(try config.target(in: [other, selected])?.id == selected.id)
        #expect(throws: RecordingConfiguration.SelectionError.self) { try config.target(in: [other]) }
        #expect(throws: RecordingConfiguration.SelectionError.self) { try config.target(in: []) }
    }

    @Test func microphoneIntentIsIndependentOfSource() throws {
        for source in RecordingSource.allCases {
            for includeMic in [true, false] {
                let config = RecordingConfiguration(source: source, includesMicrophone: includeMic)
                #expect(config.usesMicrophone == (source == .microphone || includeMic))
                if source != .application { #expect(try config.target(in: []) == nil) }
            }
        }
    }

    @Test func sharedSelectionPersistsAndMigratesLegacyPreferences() throws {
        let name = "V2TTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for legacy in ["mic", "appAudio", "appAudioMic", "systemMic", "invalid"] {
            defaults.set(legacy, forKey: "recordSource")
            defaults.set("app.one", forKey: "appAudioLastTarget")
            let config = RecordingConfiguration.load(from: defaults)
            #expect(config.includesMicrophone == (legacy != "appAudio"))
            #expect(config.source == (legacy == "systemMic" ? .system : ["appAudio", "appAudioMic"].contains(legacy) ? .application : .microphone))
        }
        let saved = RecordingConfiguration(source: .system, includesMicrophone: false, appID: "app.two", appName: "Two")
        saved.save(to: defaults)
        #expect(RecordingConfiguration.load(from: defaults) == saved)
    }
}

/// Fixtures contain synthetic bytes, never real recordings. No hardware, live
/// library, Keychain or paid transcription services are used by these tests.
@MainActor
struct LibraryPersistenceTests {
    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("V2TTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func capture(_ store: LibraryStore) throws -> URL {
        let file = try store.makeCaptureDirectory().appendingPathComponent("capture.m4a")
        try Data("original audio".utf8).write(to: file)
        return file
    }

    private var transcript: Transcript {
        Transcript(sourceFileName: "audio.m4a", languageCode: "en",
                   segments: [TranscriptSegment(speakerId: "speaker_0", start: 0, end: 5, text: "Hello")],
                   speakerIds: ["speaker_0"], words: nil)
    }

    @Test func failedMetadataSaveKeepsCaptureAndRetriesAfterRestart() throws {
        try withFixture { root in
            let library = root.appendingPathComponent("Library")
            let store = LibraryStore(rootURL: library) { data, url in
                if url.lastPathComponent == "meta.json" { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
            let folder = try #require(store.createFolder(named: "Meetings"))
            let file = try capture(store)
            #expect(store.addRecordedFile(at: file, duration: 5, startedAt: Date(), folderID: folder.id) == nil)
            #expect(store.recordings.isEmpty)
            #expect(try Data(contentsOf: file) == Data("original audio".utf8))
            #expect(store.recoveryDirectories.count == 1)
            #expect(store.lastError != nil)
            let reopened = LibraryStore(rootURL: library)
            let recovered = try #require(reopened.retryRecoverableCaptures().first)
            #expect(recovered.folderID == folder.id)
            #expect(reopened.lastSavedRecordingID == recovered.id)
            #expect(reopened.recoveryDirectories.isEmpty)
            #expect(reopened.retryRecoverableCaptures().isEmpty)
            #expect(reopened.recordings.count == 1)
            #expect(LibraryStore(rootURL: library).recordings.first?.id == recovered.id)
        }
    }

    @Test func missingTrackCannotPublishPartialRecordingOrLoseOriginals() throws {
        try withFixture { root in
            let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
            let file = try capture(store)
            let mic = file.deletingLastPathComponent().appendingPathComponent("mic.m4a")
            #expect(store.addRecordedFile(at: file, duration: 5, startedAt: Date(), rawTracks: ["track-app.m4a": file, "track-mic.m4a": mic]) == nil)
            #expect(store.recordings.isEmpty)
            #expect(FileManager.default.fileExists(atPath: file.path))
            try Data("mic audio".utf8).write(to: mic)
            let saved = try #require(store.retryRecoverableCaptures().first)
            let folder = store.folderURL(for: saved.id)
            #expect(try Data(contentsOf: folder.appendingPathComponent("track-mic.m4a")) == Data("mic audio".utf8))
            #expect(try Data(contentsOf: folder.appendingPathComponent("track-app.m4a")) == Data("original audio".utf8))
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func metadataAndTranscriptFailuresAreReportedWithoutFalseSuccess() throws {
        try withFixture { root in
            var failingName: String?
            let store = LibraryStore(rootURL: root.appendingPathComponent("Library")) { data, url in
                if url.lastPathComponent == failingName { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            }
            let file = try capture(store)
            let saved = try #require(store.addRecordedFile(at: file, duration: 5, startedAt: Date(), title: "Original"))
            failingName = "meta.json"
            store.rename(saved.id, to: "Must not stick")
            #expect(store.recording(with: saved.id)?.title == "Original")
            failingName = "transcript.json"
            #expect(!store.saveTranscript(transcript, for: saved.id))
            #expect(store.recording(with: saved.id)?.hasTranscript == false)
            #expect(store.transcript(for: saved.id) == nil)
            failingName = "meta.json"
            #expect(!store.saveTranscript(transcript, for: saved.id))
            #expect(store.recording(with: saved.id)?.hasTranscript == false)
            #expect(store.transcript(for: saved.id)?.segments.first?.text == "Hello")
            failingName = nil
            #expect(store.saveTranscript(transcript, for: saved.id))
            #expect(store.recording(with: saved.id)?.hasTranscript == true)
        }
    }

    @Test func editFailureRetainsOriginalAudioTranscriptAndWorkingFile() throws {
        try withFixture { root in
            var fail = false
            let store = LibraryStore(rootURL: root.appendingPathComponent("Library")) { data, url in
                if fail && url.lastPathComponent == "meta.json" { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
            let file = try capture(store)
            let saved = try #require(store.addRecordedFile(at: file, duration: 5, startedAt: Date()))
            #expect(store.saveTranscript(transcript, for: saved.id))
            let edited = root.appendingPathComponent("edited.m4a")
            try Data("edited audio".utf8).write(to: edited)
            fail = true
            #expect(!store.replaceAudio(for: saved.id, with: edited, duration: 3))
            #expect(try Data(contentsOf: store.audioURL(for: saved)) == Data("original audio".utf8))
            #expect(FileManager.default.fileExists(atPath: edited.path))
            #expect(store.recording(with: saved.id)?.duration == 5)
            #expect(store.transcript(for: saved.id)?.segments.first?.text == "Hello")
            fail = false
            #expect(store.replaceAudio(for: saved.id, with: edited, duration: 3, transcriptTransform: { $0.retimed(keepingOnly: 1...4) }))
            #expect(try Data(contentsOf: store.audioURL(for: saved)) == Data("edited audio".utf8))
            #expect(store.recording(with: saved.id)?.duration == 3)
            #expect(store.recording(with: saved.id)?.hasTranscript == true)
            #expect(!FileManager.default.fileExists(atPath: edited.path))
        }
    }

    @Test func failedManifestWriteStillPreservesAudioForManualRecovery() throws {
        try withFixture { root in
            let store = LibraryStore(rootURL: root.appendingPathComponent("Library")) { data, url in
                if url.lastPathComponent == CaptureDraft.manifestName { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
            let file = try capture(store)
            #expect(store.addRecordedFile(at: file, duration: 5, startedAt: Date()) == nil)
            #expect(store.recoveryDirectories.count == 1)
            #expect(store.retryRecoverableCaptures().isEmpty)
            #expect(store.lastError?.contains("Show Files") == true)
            #expect(try Data(contentsOf: file) == Data("original audio".utf8))
        }
    }

    @Test func retryOfAlreadyInstalledCaptureDoesNotDuplicateIt() throws {
        try withFixture { root in
            let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
            let file = try capture(store)
            let saved = try #require(store.addRecordedFile(at: file, duration: 5, startedAt: Date()))
            let duplicate = try capture(store)
            let draft = CaptureDraft(recording: saved, audioFileName: duplicate.lastPathComponent, tracks: [:])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(draft).write(to: duplicate.deletingLastPathComponent().appendingPathComponent(CaptureDraft.manifestName))
            store.refreshRecovery()
            #expect(store.retryRecoverableCaptures().first?.id == saved.id)
            #expect(store.recordings.count == 1)
            #expect(store.recoveryDirectories.isEmpty)
            #expect(FileManager.default.fileExists(atPath: store.audioURL(for: saved).path))
        }
    }

    @Test func recoveryManifestCannotReferenceFilesOutsideItsCapture() throws {
        try withFixture { root in
            let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
            let file = try capture(store)
            let draft = CaptureDraft(recording: Recording(title: "Invalid", createdAt: Date(), duration: 5, audioFileName: "audio.m4a"),
                                     audioFileName: "../outside.m4a", tracks: [:])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(draft).write(to: file.deletingLastPathComponent().appendingPathComponent(CaptureDraft.manifestName))
            store.refreshRecovery()
            #expect(store.retryRecoverableCaptures().isEmpty)
            #expect(store.recordings.isEmpty)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func captureOutsideRecoveryIsNeverRemoved() throws {
        try withFixture { root in
            let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
            let file = root.appendingPathComponent("outside.m4a")
            try Data("keep me".utf8).write(to: file)
            #expect(store.addRecordedFile(at: file, duration: 5, startedAt: Date()) == nil)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }
}
