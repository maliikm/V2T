import Foundation

/// A time-based minimum (not a percentage of a long meeting) shared by the
/// waveform handles, exact-time inputs, action summaries and export validation.
struct TrimSelection {
    static let minimumDuration = 0.2
    let duration: Double
    let range: ClosedRange<Double>

    init(duration: Double, start: Double, end: Double) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        let start = start.isFinite ? min(1, max(0, start)) : 0
        let end = end.isFinite ? min(1, max(0, end)) : 1
        range = (min(start, end) * self.duration)...(max(start, end) * self.duration)
    }

    var selectedDuration: Double { range.upperBound - range.lowerBound }
    var remainingDuration: Double { max(0, duration - selectedDuration) }
    // Fraction-to-time conversion can land just below an exact 0.2-second boundary.
    private var hasMinimumSelection: Bool { selectedDuration + 1e-9 >= Self.minimumDuration }
    var canKeep: Bool { hasMinimumSelection && remainingDuration > 0.001 }
    var canRemove: Bool { hasMinimumSelection && remainingDuration + 1e-9 >= Self.minimumDuration }
    var minimumFraction: Double { duration > 0 ? min(1, Self.minimumDuration / duration) : 1 }

    func movingStart(to seconds: Double) -> Double {
        guard duration > 0, seconds.isFinite else { return 0 }
        return max(0, min(seconds, range.upperBound - Self.minimumDuration)) / duration
    }

    func movingEnd(to seconds: Double) -> Double {
        guard duration > 0, seconds.isFinite else { return 1 }
        return min(duration, max(seconds, range.lowerBound + Self.minimumDuration)) / duration
    }
}
