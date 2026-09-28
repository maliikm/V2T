import Foundation
import Testing
@testable import V2T

private struct StubTranscriber: TranscriptionService {
    var perform: (URL, String, TranscriptionOptions, @escaping @Sendable (TranscribeStatus) -> Void) async throws -> Transcript
    func transcribe(file: URL, title: String, options: TranscriptionOptions,
                    onProgress: @escaping @Sendable (TranscribeStatus) -> Void) async throws -> Transcript {
        try await perform(file, title, options, onProgress)
    }
}

@MainActor
struct TranscriptionIntegrationTests {
    private func transcript(_ provider: String = "fal", text: String = "Original") -> Transcript {
        var result = Transcript.build(words: [TranscriptWord(text: text, start: 0, end: 1, speakerId: "speaker_0", isEvent: false)],
                                      sourceFileName: "Fixture", languageCode: "en")
        result.provider = provider
        return result
    }

    private func recording(_ store: LibraryStore) throws -> Recording {
        let url = try store.makeCaptureDirectory().appendingPathComponent("audio.m4a")
        try Data("synthetic fixture".utf8).write(to: url)
        return try #require(store.addRecordedFile(at: url, duration: 1, startedAt: Date()))
    }

    @Test func retranscriptionArchivesOldTextAndNamesBeforeClearingAssignments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("V2T-History-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let item = try recording(store)
        #expect(store.saveTranscript(transcript(), for: item.id))
        store.setSpeakerNames(["speaker_0": "Original Person"], for: item.id)
        #expect(store.saveTranscript(transcript("deepgram", text: "Replacement"), for: item.id))
        #expect(store.recording(with: item.id)?.speakerNames.isEmpty == true)
        #expect(store.transcript(for: item.id)?.provider == "deepgram")
        let history = store.folderURL(for: item.id).appendingPathComponent("Transcript History")
        let version = try #require(FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil).first)
        let old = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: version.appendingPathComponent("transcript.json")))
        #expect(old.provider == "fal" && old.segments.first?.text == "Original")
        let markdown = try String(contentsOf: version.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(markdown.contains("Original Person"))
        #expect(markdown.contains("Original"))
    }

    @Test func archiveOrMetadataFailureDoesNotReplaceExistingTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("V2T-History-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var failArchive = false
        var failMeta = false
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library")) { data, url in
            if failArchive && url.path.contains("Transcript History") { throw CocoaError(.fileWriteOutOfSpace) }
            if failMeta && url.lastPathComponent == "meta.json" && !url.path.contains("Transcript History") {
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        }
        let item = try recording(store)
        #expect(store.saveTranscript(transcript(), for: item.id))
        store.setSpeakerNames(["speaker_0": "Keep Name"], for: item.id)
        failArchive = true
        #expect(!store.saveTranscript(transcript("deepgram", text: "New"), for: item.id))
        #expect(store.transcript(for: item.id)?.provider == "fal")
        failArchive = false
        failMeta = true
        #expect(!store.saveTranscript(transcript("deepgram", text: "New"), for: item.id))
        #expect(store.transcript(for: item.id)?.provider == "fal")
        #expect(store.recording(with: item.id)?.speakerNames["speaker_0"] == "Keep Name")
        #expect(LibraryStore(rootURL: store.rootURL).transcript(for: item.id)?.provider == "fal")
    }

    @Test func managerSnapshotsProviderKeyAndOptionsWithoutFalFallback() async throws {
        let domain = "V2T-Provider-\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let item = try recording(store)
        let settings = AppSettings(defaults: defaults, loadAPIKey: { "fal-fixture" }, loadDeepgramAPIKey: { "deepgram-fixture" })
        settings.provider = .deepgram
        settings.deepgramLanguageCode = "es"
        settings.tagAudioEvents = true
        settings.defaultNumSpeakers = 4
        let expected = transcript("deepgram")
        var calls = 0
        let manager = TranscriptionManager { provider, key in
            #expect(provider == .deepgram && key == "deepgram-fixture")
            calls += 1
            return StubTranscriber { file, _, options, progress in
                #expect(file == store.audioURL(for: item))
                #expect(options.languageCode == "es")
                #expect(!options.tagAudioEvents && options.numSpeakers == nil)
                progress(.processing)
                return expected
            }
        }
        manager.transcribe(item, store: store, settings: settings)
        settings.provider = .fal
        manager.transcribe(item, store: store, settings: settings) // busy: cannot enqueue another job
        for _ in 0..<1000 where manager.isBusy(item.id) { await Task.yield() }
        #expect(!manager.isBusy(item.id))
        #expect(calls == 1)
        #expect(store.transcript(for: item.id)?.provider == "deepgram")
    }

    @Test func missingSelectedProviderKeyDoesNotUseOtherCredential() throws {
        let domain = "V2T-Provider-\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let item = try recording(store)
        let settings = AppSettings(defaults: defaults, loadAPIKey: { "fal-fixture" }, loadDeepgramAPIKey: { nil })
        settings.provider = .deepgram
        var called = false
        let manager = TranscriptionManager { _, _ in
            called = true
            return StubTranscriber { _, _, _, _ in throw URLError(.unknown) }
        }
        manager.transcribe(item, store: store, settings: settings)
        #expect(!called && !manager.isBusy(item.id))
        #expect(manager.error(for: item.id)?.contains("Deepgram API key") == true)
    }

    @Test func cancelledJobCannotOverwriteRestartedJobOrItsProgress() async throws {
        let domain = "V2T-Provider-\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let item = try recording(store)
        let settings = AppSettings(defaults: defaults, loadAPIKey: { "fixture" }, loadDeepgramAPIKey: { nil })
        var continuation: CheckedContinuation<Transcript, Never>?
        var oldProgress: (@Sendable (TranscribeStatus) -> Void)?
        var calls = 0
        let fresh = transcript(text: "Fresh")
        let manager = TranscriptionManager { _, _ in
            calls += 1
            let old = calls == 1
            return StubTranscriber { _, _, _, progress in
                if old {
                    oldProgress = progress
                    return await withCheckedContinuation { continuation = $0 }
                }
                return fresh
            }
        }
        manager.transcribe(item, store: store, settings: settings)
        for _ in 0..<1000 where continuation == nil { await Task.yield() }
        let suspended = try #require(continuation)
        manager.cancel(item.id)
        manager.transcribe(item, store: store, settings: settings)
        oldProgress?(.queued(position: 99))
        suspended.resume(returning: transcript(text: "Stale"))
        for _ in 0..<1000 where manager.isBusy(item.id) { await Task.yield() }
        #expect(!manager.isBusy(item.id))
        #expect(store.transcript(for: item.id)?.segments.first?.text == "Fresh")
        #expect(manager.error(for: item.id) == nil)
    }
}
