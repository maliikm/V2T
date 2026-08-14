import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TranscriptionModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case uploading
        case queued(position: Int?)
        case transcribing
        /// Multi-chunk flow for recordings over fal's 20-minute limit.
        case processingParts(done: Int, total: Int)
        case done
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparing, .uploading, .queued, .transcribing, .processingParts: return true
            default: return false
            }
        }
    }

    @Published var apiKey: String
    @Published var selectedFile: URL?
    @Published var phase: Phase = .idle
    @Published var transcript: Transcript?
    @Published var speakerNames: [String: String] = [:]
    @Published var tagAudioEvents = false
    @Published var languageCode = ""
    @Published var copiedFeedback = false

    private var task: Task<Void, Never>?

    static let supportedTypes: [UTType] = {
        var types: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        if let m4a = UTType(filenameExtension: "m4a") { types.append(m4a) }
        return types
    }()

    init() {
        self.apiKey = Keychain.loadAPIKey() ?? ""
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveAPIKey(_ key: String) {
        apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.saveAPIKey(apiKey)
    }

    func select(file: URL) {
        guard !phase.isBusy else { return }
        selectedFile = file
        transcript = nil
        speakerNames = [:]
        phase = .idle
    }

    func reset() {
        task?.cancel()
        task = nil
        selectedFile = nil
        transcript = nil
        speakerNames = [:]
        phase = .idle
    }

    func startTranscription() {
        guard let file = selectedFile, hasAPIKey, !phase.isBusy else { return }
        let client = FalClient(apiKey: apiKey)
        let tagEvents = tagAudioEvents
        let language = languageCode.trimmingCharacters(in: .whitespaces)

        phase = .preparing
        task = Task {
            var chunks: [AudioChunk] = []
            defer { AudioChunker.cleanup(chunks) }
            do {
                // Recordings over fal's 20-minute cap are split into
                // overlapping chunks and stitched back together afterwards.
                chunks = try await AudioChunker.chunks(for: file)
                try Task.checkCancellation()

                let results: [(transcription: FalTranscription, offset: Double)]
                if chunks.count == 1, let chunk = chunks.first {
                    self.phase = .uploading
                    let contentType = chunk.isTemporary ? "audio/mp4" : Self.mimeType(for: file)
                    let remoteURL = try await client.uploadFile(at: chunk.url, contentType: contentType)
                    try Task.checkCancellation()

                    self.phase = .queued(position: nil)
                    let result = try await client.transcribe(
                        audioURL: remoteURL,
                        tagAudioEvents: tagEvents,
                        languageCode: language.isEmpty ? nil : language
                    ) { update in
                        Task { @MainActor in
                            guard self.phase.isBusy else { return }
                            switch update {
                            case .queued(let position): self.phase = .queued(position: position)
                            case .inProgress: self.phase = .transcribing
                            }
                        }
                    }
                    results = [(result, 0)]
                } else {
                    self.phase = .processingParts(done: 0, total: chunks.count)
                    results = try await client.transcribeChunks(
                        chunks,
                        tagAudioEvents: tagEvents,
                        languageCode: language.isEmpty ? nil : language
                    ) { done, total in
                        Task { @MainActor in
                            guard self.phase.isBusy else { return }
                            self.phase = .processingParts(done: done, total: total)
                        }
                    }
                }
                try Task.checkCancellation()

                self.transcript = Transcript.build(fromChunks: results, sourceFileName: file.lastPathComponent)
                self.phase = .done
            } catch is CancellationError {
                // reset()/cancel() already handled state
            } catch {
                // URLSession surfaces cancellation as URLError.cancelled
                if Task.isCancelled { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase.isBusy { phase = .idle }
    }

    // MARK: - Export

    func copyForClaude() {
        guard let transcript else { return }
        let markdown = TranscriptFormatter.markdownForClaude(transcript, names: speakerNames)
        copyToPasteboard(markdown)
    }

    func copyPlainText() {
        guard let transcript else { return }
        copyToPasteboard(TranscriptFormatter.plainText(transcript, names: speakerNames))
    }

    var exportMarkdown: String {
        guard let transcript else { return "" }
        return TranscriptFormatter.markdownForClaude(transcript, names: speakerNames)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        copiedFeedback = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.copiedFeedback = false
        }
    }

    static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "audio/m4a"
    }
}
