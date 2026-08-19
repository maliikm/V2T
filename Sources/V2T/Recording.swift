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
    /// User-assigned real names per diarized speaker id.
    var speakerNames: [String: String]
    /// Expected number of speakers for transcription; 0 = auto-detect.
    var numSpeakersHint: Int

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: Double = 0,
        isFavorite: Bool = false,
        audioFileName: String,
        hasTranscript: Bool = false,
        speakerNames: [String: String] = [:],
        numSpeakersHint: Int = 0
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.isFavorite = isFavorite
        self.audioFileName = audioFileName
        self.hasTranscript = hasTranscript
        self.speakerNames = speakerNames
        self.numSpeakersHint = numSpeakersHint
    }

    /// "Today", "Yesterday", weekday within the last week, else a short date.
    var dateLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(createdAt) { return "Today" }
        if calendar.isDateInYesterday(createdAt) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: Date()), createdAt > weekAgo {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: createdAt)
        }
        return createdAt.formatted(date: .abbreviated, time: .omitted)
    }

    var durationLabel: String {
        TranscriptFormatter.timestamp(duration)
    }
}
