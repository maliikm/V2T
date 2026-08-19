import AVFoundation
import Foundation

struct WaveformData: Codable, Equatable {
    /// RMS amplitude per bucket, normalized to 0...1.
    let samples: [Float]
    let duration: Double
}

/// Decodes an audio file into a fixed number of RMS buckets for drawing,
/// caching the result next to the recording.
enum WaveformLoader {
    static let bucketCount = 1200

    static func load(audioURL: URL, cacheURL: URL?) async throws -> WaveformData {
        if let cacheURL,
           let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(WaveformData.self, from: data),
           !cached.samples.isEmpty {
            return cached
        }
        let computed = try await Task.detached(priority: .userInitiated) {
            try compute(audioURL: audioURL)
        }.value
        if let cacheURL, let data = try? JSONEncoder().encode(computed) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return computed
    }

    private static func compute(audioURL: URL) throws -> WaveformData {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, format.sampleRate > 0 else {
            return WaveformData(samples: [], duration: 0)
        }
        let duration = Double(totalFrames) / format.sampleRate
        let framesPerBucket = max(1, Int(totalFrames) / bucketCount)
        let channelCount = Int(format.channelCount)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else {
            return WaveformData(samples: [], duration: duration)
        }

        var samples: [Float] = []
        samples.reserveCapacity(bucketCount + 1)
        var sumOfSquares: Float = 0
        var accumulated = 0

        while file.framePosition < totalFrames {
            try file.read(into: buffer)
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            for frame in 0..<frameCount {
                var peak: Float = 0
                for channel in 0..<channelCount {
                    peak = max(peak, abs(channels[channel][frame]))
                }
                sumOfSquares += peak * peak
                accumulated += 1
                if accumulated >= framesPerBucket {
                    samples.append(sqrt(sumOfSquares / Float(accumulated)))
                    sumOfSquares = 0
                    accumulated = 0
                }
            }
        }
        if accumulated > 0 {
            samples.append(sqrt(sumOfSquares / Float(accumulated)))
        }

        let peak = samples.max() ?? 0
        if peak > 0 {
            samples = samples.map { min(1, $0 / peak) }
        }
        return WaveformData(samples: samples, duration: duration)
    }

    /// Time ranges quiet enough to skip during playback (for "Skip Silence").
    static func silentRanges(
        in data: WaveformData,
        threshold: Float = 0.045,
        minDuration: Double = 0.6
    ) -> [ClosedRange<Double>] {
        guard !data.samples.isEmpty, data.duration > 0 else { return [] }
        let bucketDuration = data.duration / Double(data.samples.count)
        var ranges: [ClosedRange<Double>] = []
        var runStart: Int?

        func closeRun(endingAt index: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let startTime = Double(start) * bucketDuration
            let endTime = Double(index) * bucketDuration
            if endTime - startTime >= minDuration {
                ranges.append(startTime...endTime)
            }
        }

        for (index, sample) in data.samples.enumerated() {
            if sample < threshold {
                if runStart == nil { runStart = index }
            } else {
                closeRun(endingAt: index)
            }
        }
        closeRun(endingAt: data.samples.count)
        return ranges
    }
}
