import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TranscriptionModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case uploading
        case queued(position: Int?)
        case transcribing
        case done
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .uploading, .queued, .transcribing: return true
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

        phase = .uploading
        task = Task {
            do {
                let contentType = Self.mimeType(for: file)
                let remoteURL = try await client.uploadFile(at: file, contentType: contentType)
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
                try Task.checkCancellation()

                self.transcript = Transcript.build(from: result, sourceFileName: file.lastPathComponent)
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
