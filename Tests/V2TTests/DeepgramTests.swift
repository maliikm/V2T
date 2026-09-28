import Foundation
import Testing
@testable import V2T

private func deepgramResponse(speaker: Bool = true) throws -> Data {
    var first: [String: Any] = ["word": "hello", "punctuated_word": "Hello.", "start": 0.2, "end": 0.6]
    if speaker { first["speaker"] = 4 }
    return try JSONSerialization.data(withJSONObject: ["results": ["channels": [[
        "detected_language": "en", "alternatives": [["words": [first,
            ["word": "yes", "punctuated_word": "Yes!", "start": 1.2, "end": 1.6, "speaker": 9]]]]
    ]]]])
}

struct DeepgramClientTests {
    private let options = TranscriptionOptions(languageCode: "en", tagAudioEvents: false, numSpeakers: nil)

    @Test func requestUsesDirectUploadPrivacyAndVersionedDiarization() throws {
        let file = URL(fileURLWithPath: "/fixture/audio.m4a")
        let client = DeepgramClient(apiKey: "fixture-key")
        let request = try client.request(for: file, language: " en ")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.host == "api.deepgram.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token fixture-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/mp4")
        #expect(request.httpBody == nil)
        let items = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query == ["model": "nova-3", "diarize_model": "v2", "smart_format": "true", "mip_opt_out": "true", "language": "en"])
        let auto = try client.request(for: file, language: "")
        #expect(auto.url?.query?.contains("detect_language=true") == true)
        #expect(auto.url?.query?.contains("language=en") == false)
        #expect(try client.request(for: file, language: "multi").url?.query?.contains("language=multi") == true)
    }

    @Test func adapterPreservesWordsSpeakersPunctuationAndEditProvenance() throws {
        let transcript = try DeepgramClient.decode(deepgramResponse(), title: "Meeting", language: "")
        #expect(transcript.sourceFileName == "Meeting")
        #expect(transcript.languageCode == "en")
        #expect(transcript.provider == "deepgram")
        #expect(transcript.model == "nova-3")
        #expect(transcript.speakerIds == ["speaker_4", "speaker_9"])
        #expect(transcript.words?.map(\.text) == ["Hello.", "Yes!"])
        #expect(transcript.segments.count == 2)
        #expect(transcript.segments.first?.start == 0.2)
        let trimmed = transcript.retimed(keepingOnly: 1...2)
        #expect(trimmed.provider == "deepgram")
        #expect(trimmed.model == "nova-3")
        #expect(trimmed.words?.first?.start == 0.2 || abs((trimmed.words?.first?.start ?? 0) - 0.2) < 0.0001)
        #expect(try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript)).words == transcript.words)
    }

    @Test func malformedSilentAndUndiarizedResultsCannotOverwriteTranscript() throws {
        #expect(throws: DeepgramClient.DeepgramError.invalidResponse) {
            try DeepgramClient.decode(Data("{}".utf8), title: "Test", language: "en")
        }
        #expect(throws: DeepgramClient.DeepgramError.missingSpeakers) {
            try DeepgramClient.decode(deepgramResponse(speaker: false), title: "Test", language: "en")
        }
        let empty = Data(#"{"results":{"channels":[{"alternatives":[{"words":[]}]}]}}"#.utf8)
        #expect(throws: DeepgramClient.DeepgramError.noSpeech) {
            try DeepgramClient.decode(empty, title: "Test", language: "en")
        }
        let invalidTime = Data(#"{"results":{"channels":[{"alternatives":[{"words":[{"word":"test","start":3,"end":1,"speaker":0}]}]}]}}"#.utf8)
        #expect(throws: DeepgramClient.DeepgramError.invalidResponse) {
            try DeepgramClient.decode(invalidTime, title: "Test", language: "en")
        }
    }

    @Test func directFileTransportAndHTTPErrorsUseOneRequestWithoutFallback() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("V2T-DG-\(UUID()).m4a")
        try Data("synthetic audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for status in [200, 400, 401, 403, 413, 429, 500, 504] {
            var uploads = 0
            let client = DeepgramClient(apiKey: "fixture") { request, uploadedFile in
                uploads += 1
                #expect(uploadedFile == file)
                return (try deepgramResponse(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            if status == 200 {
                #expect(try await client.transcribe(file: file, title: "Fixture", options: options, onProgress: { _ in }).provider == "deepgram")
            } else {
                await #expect(throws: DeepgramClient.DeepgramError.http(status)) {
                    try await client.transcribe(file: file, title: "Fixture", options: options, onProgress: { _ in })
                }
            }
            #expect(uploads == 1)
        }
    }

    @Test func fileAndKeyValidationPreventUploads() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("V2T-DG-\(UUID()).m4a")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var uploads = 0
        let client = DeepgramClient(apiKey: "fixture") { _, _ in
            uploads += 1
            throw URLError(.cannotConnectToHost)
        }
        await #expect(throws: DeepgramClient.DeepgramError.emptyFile) {
            try await client.transcribe(file: file, title: "Empty", options: options, onProgress: { _ in })
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(DeepgramClient.maximumBytes + 1))
        try handle.close()
        await #expect(throws: DeepgramClient.DeepgramError.fileTooLarge) {
            try await client.transcribe(file: file, title: "Large", options: options, onProgress: { _ in })
        }
        #expect(uploads == 0)
        #expect(throws: DeepgramClient.DeepgramError.invalidKey) {
            try DeepgramClient(apiKey: "").request(for: file, language: "en")
        }
    }

    @Test func oldTranscriptJSONStillDecodes() throws {
        let old = Data(#"{"sourceFileName":"Old","languageCode":"eng","segments":[],"speakerIds":[]}"#.utf8)
        let transcript = try JSONDecoder().decode(Transcript.self, from: old)
        #expect(transcript.provider == nil)
        #expect(transcript.words == nil)
    }
}

@MainActor
struct ProviderSettingsTests {
    @Test func keysLanguagesAndLegacyPreferencesRemainIndependent() throws {
        let domain = "V2T-Settings-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("eng", forKey: "languageCode")
        var saved: [(String, TranscriptionProvider)] = []
        let settings = AppSettings(defaults: defaults, loadAPIKey: { "existing-fal" }, loadDeepgramAPIKey: { nil },
                                   persistKey: { saved.append(($0, $1)) })
        #expect(settings.provider == .fal)
        #expect(settings.hasAPIKey)
        #expect(settings.selectedLanguageCode == "eng")
        settings.provider = .deepgram
        #expect(!settings.hasAPIKey)
        #expect(settings.selectedLanguageCode == "en")
        try settings.saveAPIKey("  deepgram-fixture \n")
        #expect(saved.count == 1 && saved[0].0 == "deepgram-fixture" && saved[0].1 == .deepgram)
        #expect(settings.hasAPIKey)
        settings.deepgramLanguageCode = "es"
        settings.provider = .fal
        #expect(settings.apiKey == "existing-fal")
        #expect(settings.selectedLanguageCode == "eng")
        #expect(settings.deepgramLanguageCode == "es")
        #expect(TranscriptionProvider.fal.keychainService == "com.wielventures.v2t.fal-api-key")
        #expect(TranscriptionProvider.deepgram.keychainService != TranscriptionProvider.fal.keychainService)
        settings.provider = .deepgram
        let reopened = AppSettings(defaults: defaults, loadAPIKey: { nil }, loadDeepgramAPIKey: { "deepgram-fixture" })
        #expect(reopened.provider == .deepgram && reopened.selectedLanguageCode == "es")
        #expect(!defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "deepgram-fixture" })
    }

    @Test func failedKeychainSaveDoesNotClaimSuccessOrReplaceKey() throws {
        let domain = "V2T-Settings-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults, loadAPIKey: { nil }, loadDeepgramAPIKey: { "old" },
                                   persistKey: { _, _ in throw Keychain.SaveError(status: -1) })
        settings.provider = .deepgram
        #expect(throws: Keychain.SaveError.self) { try settings.saveAPIKey("new") }
        #expect(settings.apiKey == "old")
    }
}
