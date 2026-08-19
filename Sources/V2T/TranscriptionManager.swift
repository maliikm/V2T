import Foundation

enum TranscribeStatus: Equatable {
    case preparing
    case uploading
    case queued(position: Int?)
    case transcribing
    case parts(done: Int, total: Int)

    var label: String {
        switch self {
        case .preparing: return "Preparing…"
        case .uploading: return "Uploading…"
        case .queued(let position):
            if let position { return "Waiting in queue (position \(position))…" }
            return "Waiting in queue…"
        case .transcribing: return "Transcribing…"
        case .parts(let done, let total): return "Transcribing — part \(done) of \(total) done…"
        }
    }
}

/// Runs fal.ai transcriptions per recording (several can run at once) and
/// writes results into the library.
@MainActor
final class TranscriptionManager: ObservableObject {
    @Published private(set) var active: [UUID: TranscribeStatus] = [:]
    @Published private(set) var errors: [UUID: String] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]

    func isBusy(_ id: UUID) -> Bool {
        active[id] != nil
    }

    func status(for id: UUID) -> TranscribeStatus? {
        active[id]
    }

    func error(for id: UUID) -> String? {
        errors[id]
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        active[id] = nil
    }

    func transcribe(_ recording: Recording, store: LibraryStore, settings: AppSettings) {
        let id = recording.id
        guard !isBusy(id) else { return }
        guard settings.hasAPIKey else {
            errors[id] = "Add your fal.ai API key in Settings (⌘,) first."
            return
        }
        errors[id] = nil
        active[id] = .preparing

        let client = FalClient(apiKey: settings.apiKey)
        let audioURL = store.audioURL(for: recording)
        let tagEvents = settings.tagAudioEvents
        let language = settings.languageCode.trimmingCharacters(in: .whitespaces)
        // Per-recording choice wins outright (including an explicit 0 =
        // auto-detect); the global default applies only when never set.
        let hint = recording.numSpeakersHint ?? settings.defaultNumSpeakers
        let numSpeakers = hint > 1 ? hint : nil
        let fileName = recording.title

        tasks[id] = Task {
            var chunks: [AudioChunk] = []
            defer { AudioChunker.cleanup(chunks) }
            do {
                chunks = try await AudioChunker.chunks(for: audioURL)
                try Task.checkCancellation()

                let results: [(transcription: FalTranscription, offset: Double)]
                if chunks.count == 1, let chunk = chunks.first {
                    self.setStatus(.uploading, for: id)
                    let contentType = chunk.isTemporary ? "audio/mp4" : Self.mimeType(for: audioURL)
                    let remoteURL = try await client.uploadFile(at: chunk.url, contentType: contentType)
                    try Task.checkCancellation()

                    self.setStatus(.queued(position: nil), for: id)
                    let result = try await client.transcribe(
                        audioURL: remoteURL,
                        tagAudioEvents: tagEvents,
                        languageCode: language.isEmpty ? nil : language,
                        numSpeakers: numSpeakers
                    ) { update in
                        Task { @MainActor in
                            guard self.isBusy(id) else { return }
                            switch update {
                            case .queued(let position): self.setStatus(.queued(position: position), for: id)
                            case .inProgress: self.setStatus(.transcribing, for: id)
                            }
                        }
                    }
                    results = [(result, 0)]
                } else {
                    self.setStatus(.parts(done: 0, total: chunks.count), for: id)
                    results = try await client.transcribeChunks(
                        chunks,
                        tagAudioEvents: tagEvents,
                        languageCode: language.isEmpty ? nil : language,
                        numSpeakers: numSpeakers
                    ) { done, total in
                        Task { @MainActor in
                            guard self.isBusy(id) else { return }
                            self.setStatus(.parts(done: done, total: total), for: id)
                        }
                    }
                }
                try Task.checkCancellation()

                let transcript = Transcript.build(fromChunks: results, sourceFileName: fileName)
                store.saveTranscript(transcript, for: id)
                self.active[id] = nil
                self.tasks[id] = nil
            } catch is CancellationError {
                // cancel(_:) already cleared this run's entries; a restarted
                // run may own them now, so don't touch the dictionaries here.
            } catch {
                if Task.isCancelled { return } // same: cancel() already cleaned up
                self.errors[id] = error.localizedDescription
                self.active[id] = nil
                self.tasks[id] = nil
            }
        }
    }

    private func setStatus(_ status: TranscribeStatus, for id: UUID) {
        if active[id] != nil {
            active[id] = status
        }
    }

    private static func mimeType(for url: URL) -> String {
        Self.mimeTypes[url.pathExtension.lowercased()] ?? "audio/mp4"
    }

    private static let mimeTypes: [String: String] = [
        "m4a": "audio/mp4", "mp4": "audio/mp4", "aac": "audio/aac",
        "mp3": "audio/mpeg", "wav": "audio/wav", "aiff": "audio/aiff",
        "aif": "audio/aiff", "flac": "audio/flac", "ogg": "audio/ogg",
        "caf": "audio/x-caf",
    ]
}
