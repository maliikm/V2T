import Foundation

enum TranscriptionProvider: String, Codable, CaseIterable, Identifiable {
    case fal, deepgram
    var id: String { rawValue }
    var title: String { self == .fal ? "fal · ElevenLabs Scribe v2" : "Deepgram · Nova-3" }
    var name: String { self == .fal ? "fal.ai" : "Deepgram" }
    var keyURL: URL {
        URL(string: self == .fal ? "https://fal.ai/dashboard/keys" : "https://console.deepgram.com/")!
    }
    // Keep fal's existing identifiers so upgrading doesn't lose its key.
    var keychainService: String { "com.wielventures.v2t.\(rawValue)-api-key" }
}

struct TranscriptionOptions {
    let languageCode: String
    let tagAudioEvents: Bool
    let numSpeakers: Int?
}

protocol TranscriptionService {
    func transcribe(file: URL, title: String, options: TranscriptionOptions,
                    onProgress: @escaping @Sendable (TranscribeStatus) -> Void) async throws -> Transcript
}

struct FalTranscriptionService: TranscriptionService {
    let client: FalClient

    func transcribe(file: URL, title: String, options: TranscriptionOptions,
                    onProgress: @escaping @Sendable (TranscribeStatus) -> Void) async throws -> Transcript {
        let chunks = try await AudioChunker.chunks(for: file)
        defer { AudioChunker.cleanup(chunks) }
        try Task.checkCancellation()
        let results: [(transcription: FalTranscription, offset: Double)]
        if chunks.count == 1, let chunk = chunks.first {
            onProgress(.uploading)
            let remote = try await client.uploadFile(at: chunk.url, contentType: AudioMIME.type(for: chunk.url))
            try Task.checkCancellation()
            onProgress(.queued(position: nil))
            let result = try await client.transcribe(audioURL: remote, tagAudioEvents: options.tagAudioEvents,
                languageCode: options.languageCode.isEmpty ? nil : options.languageCode,
                numSpeakers: options.numSpeakers) { update in
                    switch update {
                    case .queued(let position): onProgress(.queued(position: position))
                    case .inProgress: onProgress(.transcribing)
                    }
                }
            results = [(result, 0)]
        } else {
            onProgress(.parts(done: 0, total: chunks.count))
            results = try await client.transcribeChunks(chunks, tagAudioEvents: options.tagAudioEvents,
                languageCode: options.languageCode.isEmpty ? nil : options.languageCode,
                numSpeakers: options.numSpeakers) { done, total in onProgress(.parts(done: done, total: total)) }
        }
        var transcript = Transcript.build(fromChunks: results, sourceFileName: title)
        transcript.provider = TranscriptionProvider.fal.rawValue
        transcript.model = "scribe-v2"
        return transcript
    }
}

enum AudioMIME {
    static func type(for url: URL) -> String {
        let types = ["m4a": "audio/mp4", "mp4": "audio/mp4", "aac": "audio/aac",
         "mp3": "audio/mpeg", "wav": "audio/wav", "aiff": "audio/aiff",
         "aif": "audio/aiff", "flac": "audio/flac", "ogg": "audio/ogg", "caf": "audio/x-caf"]
        return types[url.pathExtension.lowercased()] ?? "application/octet-stream"
    }
}
