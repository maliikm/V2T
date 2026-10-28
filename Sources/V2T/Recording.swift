import Foundation

/// One recording in the library. Each recording lives in its own folder
/// under the library root: audio file + meta.json + transcript.json.
struct Recording: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var duration: Double
    var isFavorite: Bool
    var audioFileName: String
    var hasTranscript: Bool
    /// Folder this recording lives in; nil = top level (All Recordings only).
    var folderID: UUID?
    /// User-assigned real names per diarized speaker id.
    var speakerNames: [String: String]
    /// Expected number of speakers for transcription.
    /// nil = not set (fall back to the global default), 0 = force auto-detect,
    /// >= 2 = force that count.
    var numSpeakersHint: Int?
    /// Optional for compatibility with existing libraries. Imported and manually
    /// named recordings are never automatically renamed.
    var automaticTitleEligible: Bool?
    var titleSource: String?
    var endedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: Double = 0,
        isFavorite: Bool = false,
        audioFileName: String,
        hasTranscript: Bool = false,
        folderID: UUID? = nil,
        speakerNames: [String: String] = [:],
        numSpeakersHint: Int? = nil,
        automaticTitleEligible: Bool? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.isFavorite = isFavorite
        self.audioFileName = audioFileName
        self.hasTranscript = hasTranscript
        self.folderID = folderID
        self.speakerNames = speakerNames
        self.numSpeakersHint = numSpeakersHint
        self.automaticTitleEligible = automaticTitleEligible
        self.endedAt = endedAt
    }

    /// Always show the calendar date, even for today's recordings.
    var dateLabel: String {
        return createdAt.formatted(date: .abbreviated, time: .omitted)
    }

    var timeLabel: String { createdAt.formatted(date: .omitted, time: .shortened) }

    var durationLabel: String {
        TranscriptFormatter.timestamp(duration)
    }
}
