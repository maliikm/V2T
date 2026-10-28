import Foundation

/// Converts host-clock offsets to the saved recording's clock. In particular,
/// enabling the mic after a pause must not leave that pause in its start delay.
struct CaptureTimeline {
    private var pauses: [Range<Double>] = []
    private var pausedAt: Double?

    mutating func pause(at time: Double) {
        if pausedAt == nil { pausedAt = time }
    }

    mutating func resume(at time: Double) {
        guard let start = pausedAt else { return }
        pauses.append(start..<max(start, time))
        pausedAt = nil
    }

    func offset(from start: Double, to end: Double) -> Double {
        guard end >= start else { return -offset(from: end, to: start) }
        var intervals = pauses
        if let pausedAt { intervals.append(pausedAt..<max(pausedAt, end)) }
        let paused = intervals.reduce(0) { total, interval in
            total + max(0, min(end, interval.upperBound) - max(start, interval.lowerBound))
        }
        return end - start - paused
    }
}
