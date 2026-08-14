import Foundation

/// Minimal client for fal.ai: file upload to fal storage + queue-based
/// inference against the ElevenLabs Scribe v2 speech-to-text endpoint.
struct FalClient {
    /// ElevenLabs Scribe v2 on fal — highest-accuracy STT with diarization.
    static let endpointId = "fal-ai/elevenlabs/speech-to-text/scribe-v2"

    let apiKey: String
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60
        self.session = URLSession(configuration: config)
    }

    enum FalError: LocalizedError {
        case http(status: Int, body: String)
        case fileTooLarge(bytes: Int64)
        case malformedResponse(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .http(let status, let body):
                if status == 401 || status == 403 {
                    return "fal.ai rejected the API key (HTTP \(status)). Check the key in Settings — it should look like `key_id:key_secret`."
                }
                let trimmed = body.prefix(300)
                return "fal.ai returned HTTP \(status): \(trimmed)"
            case .fileTooLarge(let bytes):
                let mb = Double(bytes) / 1_048_576
                return String(format: "File is %.0f MB — the app currently supports files up to 90 MB (roughly 3 hours of Voice Memos audio). Trim or compress the recording and try again.", mb)
            case .malformedResponse(let detail):
                return "Unexpected response from fal.ai: \(detail)"
            case .timeout:
                return "Transcription timed out after 30 minutes."
            }
        }
    }

    // MARK: - Upload

    private struct InitiateUploadResponse: Decodable {
        let uploadUrl: String
        let fileUrl: String
        enum CodingKeys: String, CodingKey {
            case uploadUrl = "upload_url"
            case fileUrl = "file_url"
        }
    }

    /// Uploads a local audio file to fal CDN storage and returns its public URL.
    func uploadFile(at url: URL, contentType: String) async throws -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        if size > 90 * 1024 * 1024 {
            throw FalError.fileTooLarge(bytes: size)
        }

        var initiate = URLRequest(url: URL(string: "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3")!)
        initiate.httpMethod = "POST"
        initiate.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        initiate.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initiate.httpBody = try JSONSerialization.data(withJSONObject: [
            "content_type": contentType,
            "file_name": url.lastPathComponent,
        ])

        let initiated: InitiateUploadResponse = try await request(initiate)

        guard let uploadURL = URL(string: initiated.uploadUrl) else {
            throw FalError.malformedResponse("bad upload_url")
        }
        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: put, fromFile: url)
        try checkHTTP(response, data: data)

        return initiated.fileUrl
    }

    // MARK: - Queue

    private struct SubmitResponse: Decodable {
        let requestId: String
        let statusUrl: String
        let responseUrl: String
        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case statusUrl = "status_url"
            case responseUrl = "response_url"
        }
    }

    private struct StatusResponse: Decodable {
        let status: String
        let queuePosition: Int?
        enum CodingKeys: String, CodingKey {
            case status
            case queuePosition = "queue_position"
        }
    }

    enum QueueUpdate {
        case queued(position: Int?)
        case inProgress
    }

    /// Submits the transcription job and polls until completion.
    func transcribe(
        audioURL: String,
        tagAudioEvents: Bool,
        languageCode: String?,
        onUpdate: @escaping (QueueUpdate) -> Void
    ) async throws -> FalTranscription {
        var input: [String: Any] = [
            "audio_url": audioURL,
            "diarize": true,
            "tag_audio_events": tagAudioEvents,
        ]
        if let languageCode, !languageCode.isEmpty {
            input["language_code"] = languageCode
        }

        var submit = URLRequest(url: URL(string: "https://queue.fal.run/\(Self.endpointId)")!)
        submit.httpMethod = "POST"
        submit.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submit.httpBody = try JSONSerialization.data(withJSONObject: input)

        let submitted: SubmitResponse = try await request(submit)

        guard let statusURL = URL(string: submitted.statusUrl),
              let responseURL = URL(string: submitted.responseUrl) else {
            throw FalError.malformedResponse("bad status/response URL")
        }

        let deadline = Date().addingTimeInterval(30 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            var statusReq = URLRequest(url: statusURL)
            statusReq.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
            let status: StatusResponse = try await request(statusReq)

            switch status.status {
            case "COMPLETED":
                var resultReq = URLRequest(url: responseURL)
                resultReq.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
                return try await request(resultReq)
            case "IN_PROGRESS":
                onUpdate(.inProgress)
            default:
                onUpdate(.queued(position: status.queuePosition))
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw FalError.timeout
    }

    // MARK: - Helpers

    private func request<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try checkHTTP(response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FalError.malformedResponse("\(error.localizedDescription) — body: \(String(data: data.prefix(300), encoding: .utf8) ?? "<binary>")")
        }
    }

    private func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw FalError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
