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
struct TranscriptSegment: Identifiable, Codable, Equatable {
    var id = UUID()
    let speakerId: String
    let start: Double
    var end: Double
    var text: String

    enum CodingKeys: String, CodingKey {
        case speakerId, start, end, text
    }
}

/// A word with absolute (whole-recording) timestamps and a globally
/// reconciled speaker id.
private struct TimedWord {
    let text: String
    let start: Double
    let end: Double
    let isEvent: Bool
    var speaker: String
}

/// A single word with absolute timing, persisted so transcripts can be
/// re-segmented (or word-highlighted) later without re-transcribing.
struct TranscriptWord: Codable, Equatable {
    let text: String
    let start: Double
    let end: Double
    let speakerId: String
    let isEvent: Bool
}

struct Transcript: Codable, Equatable {
    let sourceFileName: String
    let languageCode: String?
    let segments: [TranscriptSegment]
    /// Speaker ids in order of first appearance.
    let speakerIds: [String]
    /// Word-level timing; nil on transcripts saved before this field existed.
    let words: [TranscriptWord]?

    /// Segment containing (or most recently before) the given playback time.
    func segmentIndex(at time: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        var candidate: Int?
        for (index, segment) in segments.enumerated() {
            if segment.start <= time { candidate = index } else { break }
        }
        return candidate ?? 0
    }

    static func build(from result: FalTranscription, sourceFileName: String) -> Transcript {
        build(fromChunks: [(result, 0)], sourceFileName: sourceFileName)
    }

    /// Merges one or more chunk transcriptions (with their time offsets into
    /// the original recording) into a single speaker-grouped transcript.
    ///
    /// Chunks overlap by `AudioChunker.overlap` seconds. The overlap region is
    /// transcribed twice: it is used to match each chunk's local speaker
    /// labels to the previous chunks' labels (speakers talking at the same
    /// timestamps are the same person), then the duplicated words are cut at
    /// the middle of the overlap.
    static func build(fromChunks chunks: [(transcription: FalTranscription, offset: Double)], sourceFileName: String) -> Transcript {
        let language = chunks.compactMap { $0.transcription.languageCode }.first

        let hasWords = chunks.contains { !($0.transcription.words ?? []).isEmpty }
        guard hasWords else {
            let text = chunks
                .map { $0.transcription.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let segment = TranscriptSegment(speakerId: "speaker_0", start: 0, end: 0, text: text)
            return Transcript(sourceFileName: sourceFileName, languageCode: language,
                              segments: [segment], speakerIds: ["speaker_0"], words: nil)
        }

        var globalWords: [TimedWord] = []
        var nextGlobalIndex = 0

        for (index, chunk) in chunks.enumerated() {
            let localWords = absoluteWords(chunk.transcription, offset: chunk.offset)
            guard !localWords.isEmpty else { continue }

            var mapping: [String: String] = [:]
            if index > 0 {
                mapping = matchSpeakers(
                    localWords: localWords,
                    globalWords: globalWords,
                    overlapStart: chunk.offset,
                    overlapEnd: chunk.offset + AudioChunker.overlap
                )
            }
            for word in localWords where mapping[word.speaker] == nil {
                mapping[word.speaker] = "speaker_\(nextGlobalIndex)"
                nextGlobalIndex += 1
            }

            var toAppend = localWords
            if index > 0 {
                // Drop the doubled-up overlap: earlier chunk keeps words
                // before the midpoint, this chunk supplies the rest.
                let cut = chunk.offset + AudioChunker.overlap / 2
                globalWords.removeAll { $0.start >= cut }
                toAppend = localWords.filter { $0.start >= cut }
            }
            for var word in toAppend {
                word.speaker = mapping[word.speaker] ?? word.speaker
                globalWords.append(word)
            }
        }

        globalWords.sort { $0.start < $1.start }
        return Transcript(
            sourceFileName: sourceFileName,
            languageCode: language,
            segments: makeSegments(globalWords),
            speakerIds: appearanceOrder(globalWords),
            words: globalWords.map {
                TranscriptWord(text: $0.text, start: $0.start, end: $0.end,
                               speakerId: $0.speaker, isEvent: $0.isEvent)
            }
        )
    }

    // MARK: - Merge helpers

    /// Word-level output with chunk-relative times shifted to absolute times.
    /// Spacing tokens are dropped (segments re-join words with spaces);
    /// missing timestamps inherit the previous word's end.
    private static func absoluteWords(_ transcription: FalTranscription, offset: Double) -> [TimedWord] {
        var result: [TimedWord] = []
        var lastEnd: Double = 0
        for word in transcription.words ?? [] {
            if word.type == "spacing" { continue }
            let start = word.start ?? lastEnd
            let end = word.end ?? start
            lastEnd = end
            let trimmed = word.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            result.append(TimedWord(
                text: trimmed,
                start: start + offset,
                end: end + offset,
                isEvent: word.type == "audio_event",
                speaker: word.speakerId ?? "speaker_0"
            ))
        }
        return result
    }

    /// Maps this chunk's local speaker ids to existing global ids by finding,
    /// for each local speaker, the global speaker whose speech overlaps theirs
    /// the most (in seconds) inside the shared overlap window.
    private static func matchSpeakers(
        localWords: [TimedWord],
        globalWords: [TimedWord],
        overlapStart: Double,
        overlapEnd: Double
    ) -> [String: String] {
        let localWindow = localWords.filter { $0.end > overlapStart && $0.start < overlapEnd && !$0.isEvent }
        let globalWindow = globalWords.filter { $0.end > overlapStart && $0.start < overlapEnd && !$0.isEvent }
        guard !localWindow.isEmpty, !globalWindow.isEmpty else { return [:] }

        // Score every (local, global) pairing by seconds of co-occurring
        // speech, then assign greedily one-to-one so two different people
        // can't collapse into the same label.
        var pairs: [(local: String, global: String, seconds: Double)] = []
        for local in Set(localWindow.map(\.speaker)) {
            let localSpeech = localWindow.filter { $0.speaker == local }
            for global in Set(globalWindow.map(\.speaker)) {
                let globalSpeech = globalWindow.filter { $0.speaker == global }
                let seconds = overlapSeconds(localSpeech, globalSpeech)
                if seconds >= 2.0 {
                    pairs.append((local, global, seconds))
                }
            }
        }
        pairs.sort { $0.seconds > $1.seconds }

        var mapping: [String: String] = [:]
        var usedGlobals: Set<String> = []
        for pair in pairs where mapping[pair.local] == nil && !usedGlobals.contains(pair.global) {
            mapping[pair.local] = pair.global
            usedGlobals.insert(pair.global)
        }
        // Second pass: a local speaker with strong overlap against an
        // already-claimed global label is likely the same person whom the
        // diarizer split in two — fold them in rather than minting a new one.
        for pair in pairs where mapping[pair.local] == nil && pair.seconds >= 5.0 {
            mapping[pair.local] = pair.global
        }
        return mapping
    }

    /// Total seconds during which words from both sets are simultaneously active.
    private static func overlapSeconds(_ a: [TimedWord], _ b: [TimedWord]) -> Double {
        var total: Double = 0
        for wa in a {
            for wb in b {
                total += max(0, min(wa.end, wb.end) - max(wa.start, wb.start))
            }
        }
        return total
    }

    /// Groups words into segments, breaking not only on speaker changes but
    /// also inside long single-speaker stretches — at speech pauses and
    /// sentence ends — so each block stays a precise click-to-seek target.
    private static func makeSegments(_ words: [TimedWord]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: TranscriptSegment?
        var lastWordEnd: Double = 0

        for word in words {
            let piece = word.isEvent ? "[\(word.text.trimmingCharacters(in: CharacterSet(charactersIn: "()[]")))]" : word.text
            if var segment = current,
               segment.speakerId == word.speaker,
               !shouldSplit(segment, before: word, lastWordEnd: lastWordEnd) {
                segment.text += " " + piece
                segment.end = max(segment.end, word.end)
                current = segment
            } else {
                if let finished = current { segments.append(finished) }
                current = TranscriptSegment(speakerId: word.speaker, start: word.start, end: word.end, text: piece)
            }
            lastWordEnd = word.end
        }
        if let finished = current { segments.append(finished) }
        return segments.filter { !$0.text.isEmpty }
    }

    private static let sentenceEnders: Set<Character> = [".", "?", "!", "…"]

    /// Whether to close the running segment before appending the next word
    /// of the same speaker.
    private static func shouldSplit(_ segment: TranscriptSegment, before word: TimedWord, lastWordEnd: Double) -> Bool {
        let duration = lastWordEnd - segment.start
        let gap = word.start - lastWordEnd
        // A real pause in speech makes a natural block boundary.
        if gap >= 1.5 && duration >= 6 { return true }
        // Comfortable maximum: break at the next sentence end.
        if duration >= 25, let last = segment.text.last, sentenceEnders.contains(last) { return true }
        // Hard maximum: break even mid-sentence.
        if duration >= 45 { return true }
        return false
    }

    private static func appearanceOrder(_ words: [TimedWord]) -> [String] {
        var order: [String] = []
        for word in words where !order.contains(word.speaker) {
            order.append(word.speaker)
        }
        return order.isEmpty ? ["speaker_0"] : order
    }
}

// MARK: - Retiming after audio edits

extension Transcript {
    /// Transcript adjusted for an audio edit that kept only `range`:
    /// words outside are dropped, the rest shift to start at zero.
    func retimed(keepingOnly range: ClosedRange<Double>) -> Transcript {
        retimed(wordMap: { word in
            let mid = (word.start + word.end) / 2
            guard mid >= range.lowerBound, mid <= range.upperBound else { return nil }
            let start = max(0, word.start - range.lowerBound)
            let end = max(start, min(word.end, range.upperBound) - range.lowerBound)
            return TranscriptWord(text: word.text, start: start, end: end, speakerId: word.speakerId, isEvent: word.isEvent)
        }, segmentFallback: { segment in
            let mid = (segment.start + segment.end) / 2
            guard mid >= range.lowerBound, mid <= range.upperBound else { return nil }
            let start = max(0, segment.start - range.lowerBound)
            let end = max(start, min(segment.end, range.upperBound) - range.lowerBound)
            return TranscriptSegment(speakerId: segment.speakerId, start: start, end: end, text: segment.text)
        })
    }

    /// Transcript adjusted for an audio edit that removed `range`:
    /// words inside are dropped, later words shift earlier by its length.
    func retimed(removing range: ClosedRange<Double>) -> Transcript {
        let cut = range.upperBound - range.lowerBound
        return retimed(wordMap: { word in
            let mid = (word.start + word.end) / 2
            if mid >= range.lowerBound, mid <= range.upperBound { return nil }
            if word.start >= range.upperBound {
                return TranscriptWord(text: word.text, start: word.start - cut, end: word.end - cut, speakerId: word.speakerId, isEvent: word.isEvent)
            }
            return TranscriptWord(text: word.text, start: word.start, end: min(word.end, range.lowerBound), speakerId: word.speakerId, isEvent: word.isEvent)
        }, segmentFallback: { segment in
            let mid = (segment.start + segment.end) / 2
            if mid >= range.lowerBound, mid <= range.upperBound { return nil }
            if segment.start >= range.upperBound {
                return TranscriptSegment(speakerId: segment.speakerId, start: segment.start - cut, end: segment.end - cut, text: segment.text)
            }
            return TranscriptSegment(speakerId: segment.speakerId, start: segment.start, end: min(segment.end, range.lowerBound), text: segment.text)
        })
    }

    /// Word-accurate when word timing is stored (transcripts made since
    /// words were persisted); otherwise falls back to shifting whole
    /// segments, which keeps timing right but can't split segment text.
    private func retimed(
        wordMap: (TranscriptWord) -> TranscriptWord?,
        segmentFallback: (TranscriptSegment) -> TranscriptSegment?
    ) -> Transcript {
        if let words, !words.isEmpty {
            let newWords = words.compactMap(wordMap)
            let timed = newWords.map {
                TimedWord(text: $0.text, start: $0.start, end: $0.end, isEvent: $0.isEvent, speaker: $0.speakerId)
            }
            return Transcript(
                sourceFileName: sourceFileName,
                languageCode: languageCode,
                segments: Transcript.makeSegments(timed),
                speakerIds: Transcript.appearanceOrder(timed),
                words: newWords
            )
        }
        let newSegments = segments.compactMap(segmentFallback)
        var order: [String] = []
        for segment in newSegments where !order.contains(segment.speakerId) {
            order.append(segment.speakerId)
        }
        return Transcript(
            sourceFileName: sourceFileName,
            languageCode: languageCode,
            segments: newSegments,
            speakerIds: order.isEmpty ? speakerIds : order,
            words: nil
        )
    }
}

// MARK: - Formatting

enum TranscriptFormatter {
    /// "MM:SS.cc" like Voice Memos' big playback counter.
    static func clock(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let hundredths = Int((clamped - Double(total)) * 100)
        if h > 0 { return String(format: "%d:%02d:%02d.%02d", h, m, s, hundredths) }
        return String(format: "%02d:%02d.%02d", m, s, hundredths)
    }

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
