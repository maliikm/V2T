import Foundation

/// Batch transcription only. Uploads the file directly over HTTPS, with no
/// public storage URL, automatic retries, provider fallback, or audio logging.
struct DeepgramClient: TranscriptionService {
    typealias Upload = (URLRequest, URL) async throws -> (Data, HTTPURLResponse)
    let apiKey: String
    private let upload: Upload
    static let maximumBytes: Int64 = 2_000_000_000

    init(apiKey: String, upload: Upload? = nil) {
        self.apiKey = apiKey
        self.upload = upload ?? { request, file in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15 * 60
            config.timeoutIntervalForResource = 60 * 60
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.upload(for: request, fromFile: file)
            guard let response = response as? HTTPURLResponse else { throw DeepgramError.invalidResponse }
            return (data, response)
        }
    }

    enum DeepgramError: LocalizedError, Equatable {
        case invalidKey, emptyFile, fileTooLarge, invalidResponse, noSpeech, missingSpeakers
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .invalidKey: return "Deepgram rejected the API key. Check the Deepgram key and permissions in Settings (⌘,)."
            case .emptyFile: return "The audio file is empty. No audio was uploaded."
            case .fileTooLarge: return "Deepgram accepts files up to 2 GB. Export a smaller audio file and try again."
            case .invalidResponse: return "Deepgram returned an invalid transcript. Your existing transcript has not been replaced."
            case .noSpeech: return "Deepgram found no speech. Your existing transcript has not been replaced."
            case .missingSpeakers: return "Deepgram didn't return the requested speaker labels. Your existing transcript has not been replaced."
            case .http(401), .http(403): return DeepgramError.invalidKey.errorDescription
            case .http(413): return DeepgramError.fileTooLarge.errorDescription
            case .http(429): return "Deepgram's request or account limit was reached. Check your account or try again later."
            case .http(504): return "Deepgram timed out processing this recording. Try a shorter recording. No automatic retry was made."
            case .http(400): return "Deepgram couldn't process the request. Check the audio format and Deepgram language code in Settings."
            case .http(let status): return "Deepgram returned HTTP \(status). No automatic retry was made; your existing transcript is unchanged."
            }
        }
    }

    func request(for file: URL, language: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw DeepgramError.invalidKey }
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var query = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "diarize_model", value: "v2"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "mip_opt_out", value: "true"),
        ]
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        query.append(language.isEmpty
            ? URLQueryItem(name: "detect_language", value: "true")
            : URLQueryItem(name: "language", value: language))
        components.queryItems = query
        guard let url = components.url else { throw DeepgramError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15 * 60
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(AudioMIME.type(for: file), forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func transcribe(file: URL, title: String, options: TranscriptionOptions,
                    onProgress: @escaping @Sendable (TranscribeStatus) -> Void) async throws -> Transcript {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw DeepgramError.emptyFile }
        guard size <= Self.maximumBytes else { throw DeepgramError.fileTooLarge }
        let request = try request(for: file, language: options.languageCode)
        onProgress(.processing)
        let (data, response) = try await upload(request, file)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw DeepgramError.http(response.statusCode) }
        return try Self.decode(data, title: title, language: options.languageCode)
    }

    static func decode(_ data: Data, title: String, language: String) throws -> Transcript {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw DeepgramError.invalidResponse }
        guard response.results.channels.count == 1,
              let channel = response.results.channels.first,
              let result = channel.alternatives.first else { throw DeepgramError.invalidResponse }
        guard !result.words.isEmpty else { throw DeepgramError.noSpeech }
        guard result.words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else {
            throw DeepgramError.invalidResponse
        }
        guard result.words.allSatisfy({ ($0.speaker ?? -1) >= 0 }) else { throw DeepgramError.missingSpeakers }
        let words = result.words.map {
            TranscriptWord(text: $0.punctuatedWord ?? $0.word, start: $0.start, end: $0.end,
                           speakerId: "speaker_\($0.speaker!)", isEvent: false)
        }
        guard words.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DeepgramError.noSpeech
        }
        var transcript = Transcript.build(words: words, sourceFileName: title,
            languageCode: channel.detectedLanguage ?? (language.isEmpty ? nil : language))
        transcript.provider = TranscriptionProvider.deepgram.rawValue
        transcript.model = "nova-3"
        return transcript
    }

    private struct Response: Decodable {
        let results: Results
        struct Results: Decodable { let channels: [Channel] }
        struct Channel: Decodable {
            let alternatives: [Alternative]
            let detectedLanguage: String?
            enum CodingKeys: String, CodingKey { case alternatives; case detectedLanguage = "detected_language" }
        }
        struct Alternative: Decodable { let words: [Word] }
        struct Word: Decodable {
            let word: String
            let punctuatedWord: String?
            let start: Double
            let end: Double
            let speaker: Int?
            enum CodingKeys: String, CodingKey { case word, start, end, speaker; case punctuatedWord = "punctuated_word" }
        }
    }
}
