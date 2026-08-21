import SwiftUI

/// In-place edit mode for a recording, like Voice Memos' edit view:
/// zoomed waveform on top, then either the overview strip (with the
/// REPLACE / RESUME control and Done) or the trim tool's selection strip
/// (with Trim / Delete / Close). Undo lives in the toolbar.
struct EditModeView: View {
    @ObservedObject var session: AudioEditSession
    let recording: Recording
    /// Called after Done commits and ends the session.
    var onDone: () -> Void

    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var player: AudioPlayerController

    var body: some View {
        VStack(spacing: 10) {
            ZoomedWaveformView(
                data: session.workingWaveform,
                currentTime: player.currentTime,
                duration: session.workingDuration
            ) { time in
                guard !session.isReplacing else { return }
                player.seek(to: time)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 8)

            if session.showTrimTool {
                TrimSelectionView(
                    waveform: session.workingWaveform,
                    selectionStart: $session.selectionStart,
                    selectionEnd: $session.selectionEnd,
                    progress: progressFraction,
                    onSeek: { fraction in
                        guard !session.isReplacing else { return }
                        player.seek(to: fraction * session.workingDuration)
                    }
                )
                .frame(height: 56)
                .padding(.horizontal, 24)
                HStack {
                    Text(TranscriptFormatter.timestamp(min(session.selectionStart, session.selectionEnd) * session.workingDuration))
                    Spacer()
                    Text(TranscriptFormatter.timestamp(max(session.selectionStart, session.selectionEnd) * session.workingDuration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            } else {
                WaveformView(data: session.workingWaveform, progress: progressFraction) { fraction in
                    guard !session.isReplacing else { return }
                    player.seek(to: fraction * session.workingDuration)
                }
                .frame(height: 56)
                .padding(.horizontal, 24)
                HStack {
                    Text("0:00")
                    Spacer()
                    Text(TranscriptFormatter.timestamp(session.workingDuration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            }

            Text(TranscriptFormatter.clock(session.isReplacing ? session.replaceElapsed : player.currentTime))
                .font(.system(size: 40, weight: .bold).monospacedDigit())
                .foregroundStyle(session.isReplacing ? Color.red : Color.primary)

            if let error = session.error {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            bottomRow
        }
        .padding(.bottom, 16)
    }

    // MARK: - Pieces

    private var progressFraction: Double {
        guard session.workingDuration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / session.workingDuration))
    }

    private var bottomRow: some View {
        ZStack {
            HStack(spacing: 28) {
                Button { player.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title2)
                }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .frame(width: 40, height: 40)
                }
                Button { player.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title2)
                }
            }
            .buttonStyle(.plain)
            .disabled(session.isReplacing || session.isProcessing)

            HStack {
                if session.showTrimTool {
                    Button("Trim") {
                        Task { await session.applyTrim(keepSelection: true) }
                    }
                    .disabled(session.isProcessing)
                    .help("Keep only the selected range")
                    Button("Delete") {
                        Task { await session.applyTrim(keepSelection: false) }
                    }
                    .disabled(session.isProcessing)
                    .help("Remove the selected range")
                    Spacer()
                    Button("Close") {
                        session.showTrimTool = false
                        session.selectionStart = 0
                        session.selectionEnd = 1
                    }
                    .disabled(session.isProcessing)
                } else {
                    replaceControl
                    Spacer()
                    if session.isProcessing {
                        ProgressView().controlSize(.small)
                            .padding(.trailing, 10)
                    }
                    Button("Done") {
                        session.end(commit: true, store: store)
                        onDone()
                    }
                    .controlSize(.large)
                    .disabled(session.isReplacing || session.isProcessing)
                    .help(session.hasEdits ? "Save the edited audio" : "Leave edit mode")
                }
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var replaceControl: some View {
        if session.isReplacing {
            Button {
                session.stopReplace()
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                    Text(TranscriptFormatter.timestamp(session.replaceElapsed))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Stop recording")
        } else {
            let resuming = player.currentTime >= session.workingDuration - 0.3
            Button {
                session.beginReplace(at: player.currentTime)
            } label: {
                Text(resuming ? "RESUME" : "REPLACE")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(resuming ? Color.red : Color.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(resuming ? Color.red.opacity(0.15) : Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(session.isProcessing)
            .help(resuming
                  ? "Continue recording from the end"
                  : "Record over the audio from the playhead")
        }
    }
}

/// Waveform with the yellow selection band and drag handles (the trim tool).
/// Clicking the strip outside the handles seeks playback, so a cut can be
/// auditioned before committing; the playhead is drawn for orientation.
struct TrimSelectionView: View {
    let waveform: WaveformData?
    @Binding var selectionStart: Double
    @Binding var selectionEnd: Double
    var progress: Double = 0
    var onSeek: ((Double) -> Void)?

    /// Handles can't cross: minimum selection width as a fraction.
    private let minimumSelection: Double = 0.01

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = CGFloat(min(selectionStart, selectionEnd)) * width
            let endX = CGFloat(max(selectionStart, selectionEnd)) * width

            ZStack(alignment: .leading) {
                WaveformView(data: waveform, progress: progress, onSeek: onSeek)

                Rectangle()
                    .fill(Color.yellow.opacity(0.18))
                    .frame(width: max(0, endX - startX))
                    .offset(x: startX)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.yellow, lineWidth: 2.5)
                    .frame(width: max(8, endX - startX))
                    .offset(x: startX)
                    .allowsHitTesting(false)

                handle(at: startX, height: geometry.size.height) { locationX in
                    let fraction = clampedFraction(locationX, width: width)
                    selectionStart = max(0, min(fraction, selectionEnd - minimumSelection))
                }
                handle(at: endX, height: geometry.size.height) { locationX in
                    let fraction = clampedFraction(locationX, width: width)
                    selectionEnd = min(1, max(fraction, selectionStart + minimumSelection))
                }
            }
            .coordinateSpace(name: "trimSelection")
        }
    }

    private func clampedFraction(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x / width), 1))
    }

    private func handle(at x: CGFloat, height: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        Capsule()
            .fill(Color.yellow)
            .frame(width: 10, height: height)
            .overlay(
                Circle().fill(Color.yellow).frame(width: 14, height: 14),
                alignment: .top
            )
            .offset(x: x - 5)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("trimSelection"))
                    .onChanged { value in
                        onDrag(value.location.x)
                    }
            )
    }
}
