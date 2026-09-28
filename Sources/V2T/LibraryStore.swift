import Foundation
import AVFoundation

/// A user-created folder in the library.
struct RecordingFolder: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
}

/// What the folder sidebar has selected.
enum FolderSelection: Hashable {
    case all
    case favorites
    case folder(UUID)
}

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
    @Published private(set) var folders: [RecordingFolder] = []
    @Published var lastError: String?
    @Published private(set) var lastSavedRecordingID: UUID?
    @Published private(set) var recoveryDirectories: [URL] = []

    let rootURL: URL
    let recoveryRootURL: URL
    private let writeData: (Data, URL) throws -> Void
    private var transcriptCache: [UUID: Transcript] = [:]
    private var searchTextCache: [UUID: String] = [:]

    init(rootURL: URL? = nil, writeData: @escaping (Data, URL) throws -> Void = {
        try $0.write(to: $1, options: .atomic)
    }) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.rootURL = rootURL ?? appSupport.appendingPathComponent("V2T/Library", isDirectory: true)
        recoveryRootURL = self.rootURL.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true)
        self.writeData = writeData
        do {
            try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        } catch { lastError = "Couldn't open the recording library: \(error.localizedDescription)" }
        reload()
        loadFolders()
        refreshRecovery()
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

    // MARK: - Folders

    private var foldersURL: URL {
        rootURL.deletingLastPathComponent().appendingPathComponent("folders.json")
    }

    private func loadFolders() {
        guard let data = try? Data(contentsOf: foldersURL),
              let loaded = try? Self.decoder.decode([RecordingFolder].self, from: data) else {
            return
        }
        folders = loaded
    }

    private func saveFolders(_ updated: [RecordingFolder]) -> Bool {
        do {
            try writeData(Self.encoder.encode(updated), foldersURL)
            folders = updated
            return true
        } catch {
            lastError = "Couldn't save folders: \(error.localizedDescription)"
            return false
        }
    }

    func folder(with id: UUID) -> RecordingFolder? {
        folders.first { $0.id == id }
    }

    @discardableResult
    func createFolder(named name: String) -> RecordingFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = RecordingFolder(id: UUID(), name: trimmed)
        return saveFolders(folders + [folder]) ? folder : nil
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        var updated = folders
        updated[index].name = trimmed
        _ = saveFolders(updated)
    }

    /// Removes the folder; its recordings stay in the library (top level).
    func deleteFolder(_ id: UUID) {
        for recording in recordings where recording.folderID == id {
            var updated = recording
            updated.folderID = nil
            guard update(updated) else { return }
        }
        _ = saveFolders(folders.filter { $0.id != id })
    }

    func move(_ recordingID: UUID, toFolder folderID: UUID?) {
        guard var recording = recording(with: recordingID) else { return }
        recording.folderID = folderID
        update(recording)
    }

    func recordingCount(in selection: FolderSelection) -> Int {
        switch selection {
        case .all: return recordings.count
        case .favorites: return recordings.filter(\.isFavorite).count
        case .folder(let id): return recordings.filter { $0.folderID == id }.count
        }
    }

    // MARK: - Search

    /// Filters by folder, then by title and transcript text, like Voice
    /// Memos' "Titles, Transcripts" search.
    func filtered(search: String, folder: FolderSelection = .all) -> [Recording] {
        let base: [Recording]
        switch folder {
        case .all:
            base = recordings
        case .favorites:
            base = recordings.filter(\.isFavorite)
        case .folder(let id):
            base = recordings.filter { $0.folderID == id }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter { recording in
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
            try insert(recording)
            return recording
        } catch {
            try? FileManager.default.removeItem(at: folder)
            lastError = "Couldn't import \(fileName): \(error.localizedDescription)"
            return nil
        }
    }

    /// Capture files live outside the OS temporary directory until the complete
    /// recording (including metadata and raw tracks) is installed successfully.
    func makeCaptureDirectory() throws -> URL {
        let directory = recoveryRootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func refreshRecovery() {
        recoveryDirectories = ((try? FileManager.default.contentsOfDirectory(
            at: recoveryRootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Copy, verify required writes, and rename a staged directory into place.
    /// A failed copy or write cannot delete the source or expose a partial item.
    @discardableResult
    func addRecordedFile(at tempURL: URL, duration: Double, startedAt: Date,
                         title: String? = nil, folderID: UUID? = nil,
                         rawTracks: [String: URL] = [:]) -> Recording? {
        let directory = tempURL.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == recoveryRootURL.standardizedFileURL,
              rawTracks.values.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL }) else {
            lastError = "Capture files must be inside a V2T Recovery folder. No files were changed."
            return nil
        }
        let recording = Recording(
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title! : nextRecordingTitle(),
            createdAt: startedAt, duration: duration, audioFileName: "audio.m4a", folderID: folderID
        )
        let draft = CaptureDraft(recording: recording, audioFileName: tempURL.lastPathComponent,
                                 tracks: rawTracks.mapValues(\.lastPathComponent))
        do {
            try writeData(Self.encoder.encode(draft), directory.appendingPathComponent(CaptureDraft.manifestName))
            return try installCapture(draft, from: directory)
        } catch {
            lastError = "Couldn't save recording: \(error.localizedDescription). The captured files are kept in Recovery."
            refreshRecovery()
            return nil
        }
    }

    func retryRecoverableCaptures() -> [Recording] {
        var saved: [Recording] = []
        var failures: [String] = []
        lastError = nil
        for directory in recoveryDirectories {
            do {
                let data = try Data(contentsOf: directory.appendingPathComponent(CaptureDraft.manifestName))
                let draft = try Self.decoder.decode(CaptureDraft.self, from: data)
                saved.append(try installCapture(draft, from: directory))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        refreshRecovery()
        if let failure = failures.first {
            lastError = "Some captured files still need recovery: \(failure). Use Show Files to keep or import them."
        }
        return saved
    }

    private func installCapture(_ draft: CaptureDraft, from directory: URL) throws -> Recording {
        let fm = FileManager.default
        // Recovery manifests are data: never allow them to escape their folder.
        let names = [draft.audioFileName] + Array(draft.tracks.keys) + Array(draft.tracks.values)
        guard names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }),
              draft.tracks.keys.allSatisfy({ $0.hasPrefix("track-") && $0.hasSuffix(".m4a") }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var recording = draft.recording
        recording.audioFileName = "audio.m4a"
        // A folder may have been deleted since a failed save.
        if let id = recording.folderID, folder(with: id) == nil { recording.folderID = nil }
        let destination = folderURL(for: recording.id)
        if let existing = self.recording(with: recording.id) {
            // A previous install succeeded but cleanup failed. Do not duplicate it.
            try fm.removeItem(at: directory)
            return existing
        }
        let staging = rootURL.appendingPathComponent(".capture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: directory.appendingPathComponent(draft.audioFileName), to: staging.appendingPathComponent("audio.m4a"))
        for (name, source) in draft.tracks {
            try fm.copyItem(at: directory.appendingPathComponent(source), to: staging.appendingPathComponent(name))
        }
        try writeData(Self.encoder.encode(recording), staging.appendingPathComponent("meta.json"))
        try fm.moveItem(at: staging, to: destination)
        recordings.insert(recording, at: 0)
        recordings.sort { $0.createdAt > $1.createdAt }
        lastSavedRecordingID = recording.id
        lastError = nil
        do { try fm.removeItem(at: directory) }
        catch { lastError = "Recording saved; the extra recovery copy couldn't be removed: \(error.localizedDescription)" }
        refreshRecovery()
        return recording
    }

    private func insert(_ recording: Recording) throws {
        try writeMeta(recording)
        recordings.insert(recording, at: 0)
        recordings.sort { $0.createdAt > $1.createdAt }
    }

    // MARK: - Updating

    @discardableResult
    func update(_ recording: Recording) -> Bool {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return false }
        do {
            try writeMeta(recording)
            recordings[index] = recording
            return true
        } catch {
            lastError = "Couldn't save recording details: \(error.localizedDescription)"
            return false
        }
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
        do {
            try FileManager.default.removeItem(at: folderURL(for: id))
            recordings.removeAll { $0.id == id }
            transcriptCache[id] = nil
            searchTextCache[id] = nil
        } catch { lastError = "Couldn't delete recording: \(error.localizedDescription)" }
    }

    /// Swaps in edited audio (after trim), invalidating the waveform cache.
    /// When `transcriptTransform` is provided (pure time edits: trim/delete),
    /// the stored transcript is retimed and kept; otherwise it is
    /// invalidated. Ordered so a failure at any step can never leave the
    /// recording without its original audio: the new file is staged inside
    /// the library folder first, the old audio is moved aside (not deleted)
    /// until the swap succeeds.
    @discardableResult
    func replaceAudio(
        for id: UUID,
        with newFileURL: URL,
        duration: Double,
        transcriptTransform: ((Transcript) -> Transcript)? = nil
    ) -> Bool {
        guard var recording = recording(with: id) else { return false }
        // Read before any cache/file invalidation below.
        let preservedTranscript: Transcript? = transcriptTransform.flatMap { transform in
            transcript(for: id).map(transform)
        }
        let folder = folderURL(for: id)
        let staging = rootURL.appendingPathComponent(".edit-\(UUID().uuidString)", isDirectory: true)
        let backup = rootURL.appendingPathComponent(".edit-backup-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: staging) }
        do {
            // Prepare audio, transcript and metadata together. The original
            // directory and the editor's working file remain intact on failure.
            try fm.copyItem(at: folder, to: staging)
            let stagedOldAudio = staging.appendingPathComponent(recording.audioFileName)
            try fm.removeItem(at: stagedOldAudio)
            try fm.copyItem(at: newFileURL, to: staging.appendingPathComponent("audio.m4a"))
            let stagedWaveform = staging.appendingPathComponent("waveform.json")
            if fm.fileExists(atPath: stagedWaveform.path) { try fm.removeItem(at: stagedWaveform) }
            let stagedTranscript = staging.appendingPathComponent("transcript.json")
            recording.audioFileName = "audio.m4a"
            recording.duration = duration
            recording.hasTranscript = preservedTranscript?.segments.isEmpty == false
            if recording.hasTranscript, let preservedTranscript {
                try writeData(Self.encoder.encode(preservedTranscript), stagedTranscript)
            } else if fm.fileExists(atPath: stagedTranscript.path) {
                try fm.removeItem(at: stagedTranscript)
            }
            try writeData(Self.encoder.encode(recording), staging.appendingPathComponent("meta.json"))
            try fm.moveItem(at: folder, to: backup)
            do {
                try fm.moveItem(at: staging, to: folder)
            } catch {
                do { try fm.moveItem(at: backup, to: folder) }
                catch {
                    lastError = "The original recording is preserved at \(backup.path). Restore it before editing again."
                    return false
                }
                throw error
            }
            if let index = recordings.firstIndex(where: { $0.id == id }) { recordings[index] = recording }
            transcriptCache[id] = recording.hasTranscript ? preservedTranscript : nil
            searchTextCache[id] = nil
            try? fm.removeItem(at: backup)
            try? fm.removeItem(at: newFileURL)
            return true
        } catch {
            lastError = "Couldn't apply the edit: \(error.localizedDescription)"
            return false
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

    @discardableResult
    func saveTranscript(_ transcript: Transcript, for id: UUID) -> Bool {
        guard var recording = recording(with: id) else { return false }
        do {
            try writeData(Self.encoder.encode(transcript), transcriptURL(for: id))
            // Retranscriptions need only the atomic transcript write. If the
            // first metadata update fails, retain the result on disk for retry.
            transcriptCache[id] = nil
            searchTextCache[id] = nil
            if !recording.hasTranscript {
                recording.hasTranscript = true
                guard update(recording) else { return false }
            }
            transcriptCache[id] = transcript
            searchTextCache[id] = nil
            return true
        } catch {
            lastError = "Couldn't save transcript: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Persistence helpers

    private func writeMeta(_ recording: Recording) throws {
        try writeData(Self.encoder.encode(recording), metaURL(for: recording.id))
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
