import SwiftUI

/// The overview waveform strip: amplitude bars, played-portion tint,
/// playhead, and click/drag to seek.
struct WaveformView: View {
    let data: WaveformData?
    /// 0...1 fraction of playback progress.
    let progress: Double
    var onSeek: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if let data, !data.samples.isEmpty {
                    bars(data: data, size: geometry.size)
                    playhead(size: geometry.size)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary.opacity(0.4))
                    if data == nil {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let onSeek, geometry.size.width > 0 else { return }
                        let fraction = min(max(0, value.location.x / geometry.size.width), 1)
                        onSeek(fraction)
                    }
            )
        }
    }

    private func bars(data: WaveformData, size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let samples = data.samples
            let barWidth: CGFloat = 2
            let gap: CGFloat = 1
            let step = barWidth + gap
            let barCount = max(1, Int(canvasSize.width / step))
            let samplesPerBar = max(1, samples.count / barCount)
            let playedX = canvasSize.width * progress
            let midY = canvasSize.height / 2

            for barIndex in 0..<barCount {
                let start = barIndex * samplesPerBar
                guard start < samples.count else { break }
                let end = min(start + samplesPerBar, samples.count)
                var peak: Float = 0
                for i in start..<end { peak = max(peak, samples[i]) }
                let amplitude = max(0.03, CGFloat(peak))
                let barHeight = max(1.5, amplitude * canvasSize.height * 0.9)
                let x = CGFloat(barIndex) * step
                let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
                let isPlayed = x <= playedX
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(isPlayed ? Color.accentColor : Color.secondary.opacity(0.55))
                )
            }
        }
    }

    private func playhead(size: CGSize) -> some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2)
            .offset(x: max(0, size.width * progress - 1))
    }
}
