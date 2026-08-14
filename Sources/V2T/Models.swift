import Foundation

// MARK: - fal / ElevenLabs Scribe response

struct FalWord: Decodable {
    let text: String
    let start: Double?
    let end: Double?
    let type: String?       // "word" | "spacing" | "audio_event"
    let speakerId: String?  // "speaker_0", "speaker_1", ...

    enum CodingKeys: String, CodingKey {
        case text, start, end, type
        case speakerId = "speaker_id"
    }
}

struct FalTranscription: Decodable {
    let text: String
    let languageCode: String?
    let words: [FalWord]?

    enum CodingKeys: String, CodingKey {
        case text
        case languageCode = "language_code"
        case words
    }
}

// MARK: - Speaker-grouped transcript

/// One contiguous run of speech by a single speaker.
struct TranscriptSegment: Identifiable {
    let id = UUID()
    let speakerId: String
    let start: Double
    var end: Double
    var text: String
}

struct Transcript {
    let sourceFileName: String
    let languageCode: String?
    let segments: [TranscriptSegment]
    /// Speaker ids in order of first appearance.
    let speakerIds: [String]

    /// Groups word-level output into per-speaker segments.
    static func build(from result: FalTranscription, sourceFileName: String) -> Transcript {
        guard let words = result.words, !words.isEmpty else {
            let segment = TranscriptSegment(
                speakerId: "speaker_0",
                start: 0,
                end: 0,
                text: result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return Transcript(
                sourceFileName: sourceFileName,
                languageCode: result.languageCode,
                segments: [segment],
                speakerIds: ["speaker_0"]
            )
        }

        var segments: [TranscriptSegment] = []
        var speakerOrder: [String] = []
        var current: TranscriptSegment?

        for word in words {
            let speaker = word.speakerId ?? current?.speakerId ?? "speaker_0"
            let piece: String
            switch word.type {
            case "audio_event":
                piece = " [\(word.text.trimmingCharacters(in: CharacterSet(charactersIn: "()[] ")))] "
            case "spacing":
                piece = " "
            default:
                piece = word.text
            }

            if var segment = current, segment.speakerId == speaker || word.type == "spacing" {
                segment.text += piece
                if let end = word.end { segment.end = end }
                current = segment
            } else {
                if let finished = current {
                    segments.append(finished)
                }
                if !speakerOrder.contains(speaker) {
                    speakerOrder.append(speaker)
                }
                current = TranscriptSegment(
                    speakerId: speaker,
                    start: word.start ?? current?.end ?? 0,
                    end: word.end ?? word.start ?? 0,
                    text: piece.trimmingCharacters(in: .whitespaces)
                )
            }
        }
        if let finished = current {
            segments.append(finished)
        }

        segments = segments.map { segment in
            var cleaned = segment
            cleaned.text = segment.text
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned
        }.filter { !$0.text.isEmpty }

        if speakerOrder.isEmpty { speakerOrder = ["speaker_0"] }

        return Transcript(
            sourceFileName: sourceFileName,
            languageCode: result.languageCode,
            segments: segments,
            speakerIds: speakerOrder
        )
    }
}

// MARK: - Formatting

enum TranscriptFormatter {
    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Default label ("Speaker 1") unless the user renamed the speaker.
    static func displayName(for speakerId: String, names: [String: String], order: [String]) -> String {
        if let custom = names[speakerId], !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        if let index = order.firstIndex(of: speakerId) {
            return "Speaker \(index + 1)"
        }
        return speakerId
    }

    static func plainText(_ transcript: Transcript, names: [String: String]) -> String {
        transcript.segments.map { segment in
            let name = displayName(for: segment.speakerId, names: names, order: transcript.speakerIds)
            return "\(name) [\(timestamp(segment.start))]: \(segment.text)"
        }.joined(separator: "\n\n")
    }

    /// Markdown formatted for pasting into Claude for follow-up processing.
    static func markdownForClaude(_ transcript: Transcript, names: [String: String]) -> String {
        var lines: [String] = []
        lines.append("# Meeting transcript: \(transcript.sourceFileName)")
        lines.append("")
        lines.append("_Transcribed with speaker diarization. Speaker labels were assigned automatically\(namesNote(transcript, names: names))._")
        lines.append("")
        for segment in transcript.segments {
            let name = displayName(for: segment.speakerId, names: names, order: transcript.speakerIds)
            lines.append("**\(name)** _[\(timestamp(segment.start))]_: \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func namesNote(_ transcript: Transcript, names: [String: String]) -> String {
        let renamed = transcript.speakerIds.filter { names[$0]?.isEmpty == false }
        return renamed.isEmpty ? " and have not been matched to real names" : ""
    }
}
