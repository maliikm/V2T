import SwiftUI

/// The zoomed-in playback waveform, like Voice Memos' edit view: the
/// playhead stays fixed while the waveform and a seconds ruler scroll
/// beneath it. Drag left/right to scrub.
struct ZoomedWaveformView: View {
    let data: WaveformData?
    let currentTime: Double
    let duration: Double
    var selection: ClosedRange<Double>? = nil
    var onSeek: (Double) -> Void

    private let pixelsPerSecond: CGFloat = 80
    @State private var dragStartTime: Double?

    var body: some View {
        Group {
            if let data, !data.samples.isEmpty, duration > 0 {
                canvas(data)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func canvas(_ data: WaveformData) -> some View {
        Canvas { context, size in
            let centerX = size.width / 2
            let rulerY = size.height - 26
            let midY = rulerY * 0.5
            let samples = data.samples

            // Already-played region gets a subtle fill, like Voice Memos.
            context.fill(
                Path(CGRect(x: 0, y: 0, width: centerX, height: rulerY - 4)),
                with: .color(Color.primary.opacity(0.035))
            )

            if let selection {
                let startX = centerX + CGFloat(selection.lowerBound - currentTime) * pixelsPerSecond
                let endX = centerX + CGFloat(selection.upperBound - currentTime) * pixelsPerSecond
                let left = max(0, startX)
                let right = min(size.width, endX)
                if right > left {
                    context.fill(
                        Path(CGRect(x: left, y: 0, width: right - left, height: rulerY - 4)),
                        with: .color(Color.yellow.opacity(0.22))
                    )
                }
                for edge in [startX, endX] where edge >= 0 && edge <= size.width {
                    context.fill(
                        Path(CGRect(x: edge, y: 0, width: 1, height: rulerY - 4)),
                        with: .color(.yellow)
                    )
                }
            }

            // Bars every 3pt; each bar shows the peak of its time slice.
            let step: CGFloat = 3
            let sliceSeconds = Double(step / pixelsPerSecond)
            var x: CGFloat = 1
            while x < size.width {
                let time = currentTime + Double((x - centerX) / pixelsPerSecond)
                if time >= 0, time < duration {
                    let startIndex = min(samples.count - 1, max(0, Int(time / duration * Double(samples.count))))
                    let span = max(1, Int(sliceSeconds / duration * Double(samples.count)))
                    var peak: Float = 0
                    for i in startIndex..<min(startIndex + span, samples.count) {
                        peak = max(peak, samples[i])
                    }
                    let barHeight = max(2, CGFloat(peak) * (rulerY - 24) * 0.9)
                    let rect = CGRect(x: x - 1, y: midY - barHeight / 2, width: 2, height: barHeight)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1),
                        with: .color(Color.primary.opacity(0.7))
                    )
                }
                x += step
            }

            // Seconds ruler scrolling with the audio.
            let visibleHalf = Double(centerX / pixelsPerSecond)
            let firstTick = max(0, Int(floor(currentTime - visibleHalf)))
            let lastTick = min(Int(duration.rounded(.up)), Int(ceil(currentTime + visibleHalf)))
            if lastTick >= firstTick {
                for tick in firstTick...lastTick {
                    let tickX = centerX + CGFloat(Double(tick) - currentTime) * pixelsPerSecond
                    guard tickX >= -40, tickX <= size.width + 40 else { continue }
                    context.fill(
                        Path(CGRect(x: tickX, y: rulerY, width: 1, height: 5)),
                        with: .color(Color.secondary.opacity(0.5))
                    )
                    let label = Text(TranscriptFormatter.timestamp(Double(tick)))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                    context.draw(label, at: CGPoint(x: tickX, y: rulerY + 14))
                }
            }

            // Fixed playhead with dot caps.
            context.fill(
                Path(CGRect(x: centerX - 1, y: 6, width: 2, height: rulerY - 10)),
                with: .color(selection == nil ? Color.accentColor : .yellow)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: centerX - 4, y: 0, width: 8, height: 8)),
                with: .color(selection == nil ? Color.accentColor : .yellow)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: centerX - 4, y: rulerY - 6, width: 8, height: 8)),
                with: .color(selection == nil ? Color.accentColor : .yellow)
            )
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartTime == nil { dragStartTime = currentTime }
                    let base = dragStartTime ?? currentTime
                    // Dragging the waveform right moves back in time.
                    let delta = Double(value.translation.width / pixelsPerSecond)
                    onSeek(min(max(0, base - delta), duration))
                }
                .onEnded { _ in dragStartTime = nil }
        )
        .help("Drag to scrub")
    }
}
