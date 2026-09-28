import Foundation

enum TranscribeStatus: Equatable {
    case preparing, uploading, transcribing, processing
    case queued(position: Int?)
    case parts(done: Int, total: Int)

    var label: String {
        switch self {
        case .preparing: return "Preparing…"
        case .uploading: return "Uploading…"
        case .transcribing: return "Transcribing…"
        case .processing: return "Uploading and transcribing…"
        case .queued(let position):
            return position.map { "Waiting in queue (position \($0))…" } ?? "Waiting in queue…"
        case .parts(let done, let total): return "Transcribing — part \(done) of \(total) done…"
        }
    }
}

/// Snapshots provider, credentials and options per job. Changing Settings does
/// not reroute an in-flight request, and cancellation never starts a fallback.
@MainActor
final class TranscriptionManager: ObservableObject {
    typealias ServiceFactory = (TranscriptionProvider, String) -> any TranscriptionService
    @Published private(set) var active: [UUID: TranscribeStatus] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var providers: [UUID: TranscriptionProvider] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var runs: [UUID: UUID] = [:]
    private let makeService: ServiceFactory

    init(makeService: @escaping ServiceFactory = { provider, key in
        switch provider {
        case .fal: return FalTranscriptionService(client: FalClient(apiKey: key))
        case .deepgram: return DeepgramClient(apiKey: key)
        }
    }) { self.makeService = makeService }

    func isBusy(_ id: UUID) -> Bool { active[id] != nil }
    func status(for id: UUID) -> TranscribeStatus? { active[id] }
    func error(for id: UUID) -> String? { errors[id] }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        finish(id)
    }

    func transcribe(_ recording: Recording, store: LibraryStore, settings: AppSettings) {
        let id = recording.id
        guard !isBusy(id) else { return }
        let provider = settings.provider
        guard settings.hasAPIKey else {
            errors[id] = "Add your \(provider.name) API key in Settings (⌘,) first."
            return
        }
        let service = makeService(provider, settings.apiKey)
        let hint = recording.numSpeakersHint ?? settings.defaultNumSpeakers
        let options = TranscriptionOptions(languageCode: settings.selectedLanguageCode,
            tagAudioEvents: provider == .fal && settings.tagAudioEvents,
            numSpeakers: provider == .fal && hint > 1 ? hint : nil)
        let audioURL = store.audioURL(for: recording)
        let run = UUID()
        runs[id] = run
        providers[id] = provider
        errors[id] = nil
        active[id] = .preparing

        tasks[id] = Task {
            do {
                let transcript = try await service.transcribe(file: audioURL, title: recording.title, options: options) { status in
                    Task { @MainActor in
                        guard self.runs[id] == run else { return }
                        self.active[id] = status
                    }
                }
                try Task.checkCancellation()
                guard runs[id] == run else { return }
                if !store.saveTranscript(transcript, for: id) {
                    errors[id] = store.lastError ?? "Couldn't save the transcript."
                }
                finish(id)
            } catch {
                guard runs[id] == run else { return }
                if !Task.isCancelled {
                    errors[id] = "\(provider.name): \(error.localizedDescription)"
                }
                finish(id)
            }
        }
    }

    private func finish(_ id: UUID) {
        tasks[id] = nil
        runs[id] = nil
        active[id] = nil
        providers[id] = nil
    }
}
