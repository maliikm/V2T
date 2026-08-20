import SwiftUI

/// Full-pane recording screen shown while a recording session is active,
/// modeled on Voice Memos: live scrolling waveform with a time ruler and
/// "now" line, a building overview strip, the big elapsed counter, a
/// pause / RESUME control, and Done to finish.
struct RecordingSessionView: View {
    @EnvironmentObject var recorder: RecorderController

    /// Samples per second appended by RecorderController's meter timer.
    static let sampleRate: Double = 20

    var body: some View {
        VStack(spacing: 0) {
            header

            LiveWaveformView(
                levels: recorder.levels,
                elapsed: recorder.elapsed,
                isPaused: recorder.isPaused
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            OverviewLevelsView(levels: recorder.levels, isPaused: recorder.isPaused)
                .frame(height: 48)
                .padding(.horizontal, 24)
                .padding(.top, 12)

            HStack {
                Text("0:00")
                Spacer()
                Text(TranscriptFormatter.timestamp(recorder.elapsed))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.top, 4)

            Text(TranscriptFormatter.clock(recorder.elapsed))
                .font(.system(size: 40, weight: .bold).monospacedDigit())
                .padding(.top, 10)

            bottomBar
        }
        .padding(.bottom, 16)
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text(recorder.sessionTitle)
                .font(.title3.weight(.bold))
            HStack(spacing: 8) {
                if let started = recorder.sessionStartedAt {
                    Text(started.formatted(date: .omitted, time: .shortened))
                }
                Text(TranscriptFormatter.timestamp(recorder.elapsed)).monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 16)
        .padding(.horizontal, 24)
    }

    private var bottomBar: some View {
        ZStack {
            // Center: transport placeholder — reviewing mid-recording isn't
            // supported; listen after Done.
            HStack(spacing: 28) {
                Image(systemName: "gobackward.15").font(.title2)
                Image(systemName: "play.fill").font(.system(size: 26))
                Image(systemName: "goforward.15").font(.title2)
            }
            .foregroundStyle(.quaternary)
            .help("Playback is available after you tap Done")

            HStack {
                pauseResumeControl
                Spacer()
                Button("Done") {
                    recorder.stop()
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    @ViewBuilder
    private var pauseResumeControl: some View {
        if recorder.isPaused {
            Button {
                recorder.resume()
            } label: {
                Text("RESUME")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Resume recording")
        } else {
            Button {
                recorder.pause()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Pause recording")
        }
    }
}

/// The zoomed live waveform: recent meter levels scroll leftward past a
/// fixed "now" line, over a seconds ruler — red while recording, dimmed
/// primary while paused.
private struct LiveWaveformView: View {
    let levels: [Float]
    let elapsed: Double
    let isPaused: Bool

    private let pixelsPerSecond: CGFloat = 56

    var body: some View {
        Canvas { context, size in
            let nowX = size.width * 0.55
            let midY = size.height * 0.45
            let rulerY = size.height - 24
            let barColor = isPaused ? Color.primary.opacity(0.75) : Color.red
            // Bar spacing derived from the time scale so bars and the
            // seconds ruler scroll at exactly the same rate.
            let sampleRate = RecordingSessionView.sampleRate
            let samplesPerBar = max(1, Int((2.5 * sampleRate / pixelsPerSecond).rounded(.up)))
            let barSpacing = CGFloat(samplesPerBar) / sampleRate * pixelsPerSecond

            // Region already recorded (left of the now line) gets a subtle
            // fill, like Voice Memos.
            context.fill(
                Path(CGRect(x: 0, y: 0, width: nowX, height: rulerY - 6)),
                with: .color(Color.primary.opacity(0.035))
            )

            // Bars: newest sample sits at the now line, older ones march left.
            var barIndex = 0
            while true {
                let x = nowX - CGFloat(barIndex) * barSpacing
                if x < -barSpacing { break }
                let sampleEnd = levels.count - barIndex * samplesPerBar
                let sampleStart = sampleEnd - samplesPerBar
                if sampleEnd <= 0 { break }
                var peak: Float = 0
                for i in max(0, sampleStart)..<sampleEnd {
                    peak = max(peak, levels[i])
                }
                let height = max(2, CGFloat(peak) * (rulerY - 20) * 0.85)
                let rect = CGRect(x: x - 1, y: midY - height / 2, width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(barColor))
                barIndex += 1
            }

            // Seconds ruler with labels, scrolling with the recording.
            let visibleBefore = Double(nowX / pixelsPerSecond)
            let visibleAfter = Double((size.width - nowX) / pixelsPerSecond)
            let firstTick = max(0, Int(floor(elapsed - visibleBefore)))
            let lastTick = Int(ceil(elapsed + visibleAfter))
            if lastTick >= firstTick {
                for tick in firstTick...lastTick {
                    let x = nowX - CGFloat(elapsed - Double(tick)) * pixelsPerSecond
                    guard x >= -30, x <= size.width + 30 else { continue }
                    context.fill(
                        Path(CGRect(x: x, y: rulerY, width: 1, height: 5)),
                        with: .color(Color.secondary.opacity(0.5))
                    )
                    if tick % 2 == 0 {
                        let label = Text(TranscriptFormatter.timestamp(Double(tick)))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                        context.draw(label, at: CGPoint(x: x, y: rulerY + 13))
                    }
                }
            }

            // The "now" line with dots, like Voice Memos' playhead.
            let lineColor = isPaused ? Color.accentColor : Color.red
            context.fill(
                Path(CGRect(x: nowX - 1, y: 4, width: 2, height: rulerY - 8)),
                with: .color(lineColor)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: nowX - 4, y: 0, width: 8, height: 8)),
                with: .color(lineColor)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: nowX - 4, y: rulerY - 8, width: 8, height: 8)),
                with: .color(lineColor)
            )
        }
        .padding(.top, 12)
    }
}

/// The bottom overview strip: the whole session so far, downsampled to fit.
private struct OverviewLevelsView: View {
    let levels: [Float]
    let isPaused: Bool

    var body: some View {
        Canvas { context, size in
            let barColor = isPaused ? Color.primary.opacity(0.75) : Color.red
            context.fill(
                Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6),
                with: .color(Color.primary.opacity(0.045))
            )
            guard !levels.isEmpty else { return }
            let step: CGFloat = 3
            let barCount = max(1, Int(size.width / step))
            let midY = size.height / 2
            for barIndex in 0..<barCount {
                let start = barIndex * levels.count / barCount
                guard start < levels.count else { break }
                let end = min(max(start + 1, (barIndex + 1) * levels.count / barCount), levels.count)
                var peak: Float = 0
                for i in start..<end { peak = max(peak, levels[i]) }
                let height = max(1.5, CGFloat(peak) * size.height * 0.85)
                let x = CGFloat(barIndex) * step
                context.fill(
                    Path(CGRect(x: x, y: midY - height / 2, width: 1.5, height: height)),
                    with: .color(barColor)
                )
            }
            // The whole strip is the session so far, so the cursor sits at
            // the right edge where new audio is being appended.
            context.fill(
                Path(CGRect(x: size.width - 3, y: 2, width: 3, height: size.height - 4)),
                with: .color(isPaused ? Color.accentColor : Color.red)
            )
        }
    }
}
