import AVFoundation
import Foundation

struct AudioChunk: Sendable {
    let url: URL
    /// Start of this chunk within the original recording, in seconds.
    let offset: Double
    let isTemporary: Bool
}

/// fal's Scribe endpoints reject audio longer than 1200 seconds, so longer
/// recordings are split into overlapping chunks that are transcribed
/// separately and stitched back together.
enum AudioChunker {
    /// Chunk length, safely under fal's 1200 s cap.
    static let maxChunkDuration: Double = 1140
    /// Consecutive chunks share this much audio so speaker labels can be
    /// matched across the chunk boundary.
    static let overlap: Double = 45

    static func duration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    /// Returns the original file as a single chunk when it fits in one
    /// request, otherwise splits it into overlapping m4a chunks in a
    /// temporary directory.
    static func chunks(for url: URL) async throws -> [AudioChunk] {
        let total = try await duration(of: url)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? Int64) ?? 0

        if total <= 1180 {
            // Fits in one request. Re-encode only if the file itself is too
            // large to upload (e.g. an uncompressed WAV).
            if fileSize <= 90 * 1024 * 1024 {
                return [AudioChunk(url: url, offset: 0, isTemporary: false)]
            }
            let dir = try makeTempDirectory()
            let out = dir.appendingPathComponent("full.m4a")
            try await export(AVURLAsset(url: url), start: 0, duration: total, to: out)
            return [AudioChunk(url: out, offset: 0, isTemporary: true)]
        }

        let asset = AVURLAsset(url: url)
        let dir = try makeTempDirectory()
        let stride = maxChunkDuration - overlap
        var chunks: [AudioChunk] = []
        var start: Double = 0
        var index = 0
        while start < total {
            try Task.checkCancellation()
            let length = min(maxChunkDuration, total - start)
            let out = dir.appendingPathComponent("chunk-\(index).m4a")
            try await export(asset, start: start, duration: length, to: out)
            chunks.append(AudioChunk(url: out, offset: start, isTemporary: true))
            if start + length >= total { break }
            start += stride
            index += 1
        }
        return chunks
    }

    static func cleanup(_ chunks: [AudioChunk]) {
        for chunk in chunks where chunk.isTemporary {
            try? FileManager.default.removeItem(at: chunk.url.deletingLastPathComponent())
        }
    }

    private static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("V2T-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func export(_ asset: AVAsset, start: Double, duration: Double, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "V2T", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This audio format can't be split for transcription. Convert it to m4a/mp3/wav and try again."
            ])
        }
        session.outputURL = url
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: session.error ?? NSError(domain: "V2T", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Splitting the audio failed."
                    ]))
                }
            }
        }
    }
}
