import AVFoundation
import Foundation

/// Destructive audio edits for the Trim sheet: keep a selection (Trim) or
/// cut it out (Delete). Both produce a new temporary m4a; the caller commits
/// it via LibraryStore.replaceAudio on Apply.
enum AudioEditor {
    enum EditorError: LocalizedError {
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .exportFailed(let detail): return "Edit failed: \(detail)"
            }
        }
    }

    /// Keeps only `range` of the audio.
    static func trim(url: URL, keeping range: ClosedRange<Double>) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
        )
        return try await export(asset: asset, timeRange: timeRange)
    }

    /// Removes `range` from the middle of the audio, joining what's left.
    static func deleteRange(url: URL, removing range: ClosedRange<Double>, totalDuration: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let destinationTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw EditorError.exportFailed("no audio track")
        }

        let scale: CMTimeScale = 600
        var cursor = CMTime.zero
        let head = CMTimeRange(
            start: .zero,
            end: CMTime(seconds: range.lowerBound, preferredTimescale: scale)
        )
        if head.duration.seconds > 0.05 {
            try destinationTrack.insertTimeRange(head, of: sourceTrack, at: cursor)
            cursor = cursor + head.duration
        }
        let tail = CMTimeRange(
            start: CMTime(seconds: range.upperBound, preferredTimescale: scale),
            end: CMTime(seconds: totalDuration, preferredTimescale: scale)
        )
        if tail.duration.seconds > 0.05 {
            try destinationTrack.insertTimeRange(tail, of: sourceTrack, at: cursor)
        }
        return try await export(asset: composition, timeRange: nil)
    }

    struct SplicePart {
        let url: URL
        /// nil = the whole file.
        let range: ClosedRange<Double>?
    }

    /// Concatenates pieces of audio files into one new m4a.
    static func splice(_ parts: [SplicePart]) async throws -> URL {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw EditorError.exportFailed("couldn't build composition")
        }
        var cursor = CMTime.zero
        for part in parts {
            let asset = AVURLAsset(url: part.url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw EditorError.exportFailed("no audio track")
            }
            let timeRange: CMTimeRange
            if let range = part.range {
                timeRange = CMTimeRange(
                    start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                    end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
                )
            } else {
                timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            }
            guard timeRange.duration.seconds > 0.05 else { continue }
            try track.insertTimeRange(timeRange, of: source, at: cursor)
            cursor = cursor + timeRange.duration
        }
        return try await export(asset: composition, timeRange: nil)
    }

    /// Appends `addition` to the end of `original` (edit mode's Resume).
    static func append(original: URL, addition: URL) async throws -> URL {
        try await splice([
            SplicePart(url: original, range: nil),
            SplicePart(url: addition, range: nil),
        ])
    }

    /// Records over `original` starting at `time` (edit mode's Replace):
    /// keeps the head before `time`, inserts the addition, and keeps
    /// whatever tail the addition didn't overwrite.
    static func replaceSection(
        original: URL,
        at time: Double,
        additionURL: URL,
        additionDuration: Double,
        totalDuration: Double
    ) async throws -> URL {
        var parts: [SplicePart] = []
        if time > 0.05 {
            parts.append(SplicePart(url: original, range: 0...time))
        }
        parts.append(SplicePart(url: additionURL, range: nil))
        let tailStart = time + additionDuration
        if totalDuration - tailStart > 0.05 {
            parts.append(SplicePart(url: original, range: tailStart...totalDuration))
        }
        return try await splice(parts)
    }

    private static func export(asset: AVAsset, timeRange: CMTimeRange?) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw EditorError.exportFailed("this audio format can't be edited")
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("V2T-edit-\(UUID().uuidString).m4a")
        session.outputURL = outputURL
        session.outputFileType = .m4a
        if let timeRange {
            session.timeRange = timeRange
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: EditorError.exportFailed(
                        session.error?.localizedDescription ?? "unknown error"
                    ))
                }
            }
        }
        return outputURL
    }

    static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        return CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
    }
}
