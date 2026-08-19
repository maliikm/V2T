import Foundation
import AVFoundation

/// Owns the on-disk recording library and the in-memory list.
///
/// Layout: `~/Library/Application Support/V2T/Library/<uuid>/`
///   - the audio file (original extension preserved on import)
///   - `meta.json` — the `Recording` metadata
///   - `transcript.json` — the diarized transcript, when present
///   - `waveform.json` — cached waveform buckets
@MainActor
final class LibraryStore: ObservableObject {
    /// Newest first.
    @Published private(set) var recordings: [Recording] = []
    @Published var lastError: String?

    let rootURL: URL
    private var transcriptCache: [UUID: Transcript] = [:]
    private var searchTextCache: [UUID: String] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        rootURL = appSupport.appendingPathComponent("V2T/Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Paths

    func folderURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioURL(for recording: Recording) -> URL {
        folderURL(for: recording.id).appendingPathComponent(recording.audioFileName)
    }

    private func metaURL(for id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent("meta.json")
    }

    private func transcriptURL(for id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent("transcript.json")
    }

    func waveformCacheURL(for id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent("waveform.json")
    }

    // MARK: - Loading

    func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var loaded: [Recording] = []
        for folder in contents {
            let meta = folder.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: meta),
                  let recording = try? Self.decoder.decode(Recording.self, from: data) else {
                continue
            }
            loaded.append(recording)
        }
        recordings = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func recording(with id: UUID?) -> Recording? {
        guard let id else { return nil }
        return recordings.first { $0.id == id }
    }

    // MARK: - Search

    /// Filters by title and transcript text, like Voice Memos' "Titles, Transcripts" search.
    func filtered(search: String) -> [Recording] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return recordings }
        return recordings.filter { recording in
            if recording.title.localizedCaseInsensitiveContains(query) { return true }
            guard recording.hasTranscript else { return false }
            return transcriptSearchText(for: recording).localizedCaseInsensitiveContains(query)
        }
    }

    private func transcriptSearchText(for recording: Recording) -> String {
        if let cached = searchTextCache[recording.id] { return cached }
        let text = transcript(for: recording.id)?.segments.map(\.text).joined(separator: " ") ?? ""
        searchTextCache[recording.id] = text
        return text
    }

    // MARK: - Creating

    func nextRecordingTitle() -> String {
        let base = "New Recording"
        let numbers = recordings.compactMap { recording -> Int? in
            guard recording.title.hasPrefix(base) else { return nil }
            let suffix = recording.title.dropFirst(base.count).trimmingCharacters(in: .whitespaces)
            return suffix.isEmpty ? 1 : Int(suffix)
        }
        let next = (numbers.max() ?? 0) + 1
        return next == 1 ? base : "\(base) \(next)"
    }

    /// Copies an external audio file into the library.
    @discardableResult
    func importAudio(from source: URL) async -> Recording? {
        let id = UUID()
        let folder = folderURL(for: id)
        let fileName = source.lastPathComponent
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(fileName)
            let accessing = source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: source, to: destination)

            let asset = AVURLAsset(url: destination)
            let duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)

            var title = source.deletingPathExtension().lastPathComponent
            if title.isEmpty { title = nextRecordingTitle() }
            let recording = Recording(
                id: id, title: title, createdAt: Date(), duration: duration,
                audioFileName: fileName
            )
            insert(recording)
            return recording
        } catch {
            try? FileManager.default.removeItem(at: folder)
            lastError = "Couldn't import \(fileName): \(error.localizedDescription)"
            return nil
        }
    }

    /// Moves a freshly captured recording (from RecorderController) into the library.
    @discardableResult
    func addRecordedFile(at tempURL: URL, duration: Double, startedAt: Date) -> Recording? {
        let id = UUID()
        let folder = folderURL(for: id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("audio.m4a")
            try FileManager.default.moveItem(at: tempURL, to: destination)
            let recording = Recording(
                id: id, title: nextRecordingTitle(), createdAt: startedAt,
                duration: duration, audioFileName: "audio.m4a"
            )
            insert(recording)
            return recording
        } catch {
            lastError = "Couldn't save recording: \(error.localizedDescription)"
            return nil
        }
    }

    private func insert(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        recordings.sort { $0.createdAt > $1.createdAt }
        writeMeta(recording)
    }

    // MARK: - Updating

    func update(_ recording: Recording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[index] = recording
        writeMeta(recording)
    }

    func rename(_ id: UUID, to title: String) {
        guard var recording = recording(with: id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        recording.title = trimmed.isEmpty ? recording.title : trimmed
        update(recording)
    }

    func toggleFavorite(_ id: UUID) {
        guard var recording = recording(with: id) else { return }
        recording.isFavorite.toggle()
        update(recording)
    }

    func setSpeakerNames(_ names: [String: String], for id: UUID) {
        guard var recording = recording(with: id) else { return }
        recording.speakerNames = names
        update(recording)
    }

    func setNumSpeakersHint(_ count: Int, for id: UUID) {
        guard var recording = recording(with: id) else { return }
        recording.numSpeakersHint = count
        update(recording)
    }

    func delete(_ id: UUID) {
        recordings.removeAll { $0.id == id }
        transcriptCache[id] = nil
        searchTextCache[id] = nil
        try? FileManager.default.removeItem(at: folderURL(for: id))
    }

    /// Swaps in edited audio (after trim), invalidating the now-stale
    /// transcript and waveform cache.
    func replaceAudio(for id: UUID, with newFileURL: URL, duration: Double) {
        guard var recording = recording(with: id) else { return }
        let folder = folderURL(for: id)
        let destination = folder.appendingPathComponent("audio.m4a")
        do {
            let oldURL = audioURL(for: recording)
            try? FileManager.default.removeItem(at: oldURL)
            if FileManager.default.fileExists(atPath: destination.path) && destination != oldURL {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: newFileURL, to: destination)
            recording.audioFileName = "audio.m4a"
            recording.duration = duration
            recording.hasTranscript = false
            update(recording)
            transcriptCache[id] = nil
            searchTextCache[id] = nil
            try? FileManager.default.removeItem(at: transcriptURL(for: id))
            try? FileManager.default.removeItem(at: waveformCacheURL(for: id))
        } catch {
            lastError = "Couldn't apply the edit: \(error.localizedDescription)"
        }
    }

    // MARK: - Transcripts

    func transcript(for id: UUID) -> Transcript? {
        if let cached = transcriptCache[id] { return cached }
        guard let data = try? Data(contentsOf: transcriptURL(for: id)),
              let transcript = try? Self.decoder.decode(Transcript.self, from: data) else {
            return nil
        }
        transcriptCache[id] = transcript
        return transcript
    }

    func saveTranscript(_ transcript: Transcript, for id: UUID) {
        guard var recording = recording(with: id) else { return }
        transcriptCache[id] = transcript
        searchTextCache[id] = nil
        if let data = try? Self.encoder.encode(transcript) {
            try? data.write(to: transcriptURL(for: id), options: .atomic)
        }
        recording.hasTranscript = true
        update(recording)
    }

    // MARK: - Persistence helpers

    private func writeMeta(_ recording: Recording) {
        guard let data = try? Self.encoder.encode(recording) else { return }
        try? data.write(to: metaURL(for: recording.id), options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
