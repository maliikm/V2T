import SwiftUI

/// Waveform-first editing, with a compact Voice Memos-style trim mode.
struct EditModeView: View {
    @ObservedObject var session: AudioEditSession
    let recording: Recording
    var onDone: () -> Void

    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var player: AudioPlayerController

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    ZoomedWaveformView(
                        data: session.workingWaveform,
                        currentTime: player.currentTime,
                        duration: session.workingDuration,
                        selection: session.showTrimTool ? session.trimSelection.range : nil
                    ) { time in
                        guard !session.isReplacing, !session.isProcessing else { return }
                        player.seek(to: time)
                    }
                    .frame(height: max(120, geometry.size.height - 250))
                    .padding(.top, 8)

                    VStack(spacing: 6) {
                        if session.showTrimTool {
                            TrimSelectionView(
                                waveform: session.workingWaveform,
                                selectionStart: $session.selectionStart,
                                selectionEnd: $session.selectionEnd,
                                minimumSelection: session.trimSelection.minimumFraction,
                                progress: progressFraction,
                                duration: session.workingDuration,
                                onSeek: { fraction in
                                    guard !session.isProcessing else { return }
                                    player.seek(to: fraction * session.workingDuration)
                                }
                            )
                            .disabled(session.isProcessing)
                        } else {
                            WaveformView(data: session.workingWaveform, progress: progressFraction) { fraction in
                                guard !session.isReplacing, !session.isProcessing else { return }
                                player.seek(to: fraction * session.workingDuration)
                            }
                        }
                        HStack {
                            Text("0:00")
                            Spacer()
                            Text(TranscriptFormatter.timestamp(session.workingDuration))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .frame(height: 68)
                    .padding(.horizontal, 24)

                    Text(TranscriptFormatter.clock(session.isReplacing ? session.replaceElapsed : player.currentTime))
                        .font(.system(size: 34, weight: .bold).monospacedDigit())
                        .foregroundStyle(session.isReplacing ? Color.red : Color.primary)

                    if let error = session.error {
                        Text(error).foregroundStyle(.red)
                            .multilineTextAlignment(.center).padding(.horizontal, 24)
                    }

                    bottomRow
                }
                .padding(.bottom, 16)
            }
        }
    }

    private var progressFraction: Double {
        guard session.workingDuration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / session.workingDuration))
    }

    private var transport: some View {
        HStack(spacing: 22) {
            Button {
                player.skip(-15)
            } label: {
                Image(systemName: "gobackward.15").font(.title2)
            }.help("Back 15 seconds").accessibilityLabel("Back 15 seconds")
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24)).frame(width: 32, height: 32)
            }
            .help(player.isPlaying ? "Pause playback" : "Play audio")
            .accessibilityLabel(player.isPlaying ? "Pause playback" : "Play audio")
            Button {
                player.skip(15)
            } label: {
                Image(systemName: "goforward.15").font(.title2)
            }.help("Forward 15 seconds").accessibilityLabel("Forward 15 seconds")
        }
        .buttonStyle(.plain)
        .disabled(session.isReplacing || session.isProcessing)
    }

    private var trimActions: some View {
        HStack(spacing: 8) {
            Button("Trim") { Task { await session.applyTrim(keepSelection: true) } }
                .disabled(!session.trimSelection.canKeep)
                .help("Keep the selection and remove audio outside it")
                .accessibilityLabel("Trim to selection")
            Button("Delete") { Task { await session.applyTrim(keepSelection: false) } }
                .disabled(!session.trimSelection.canRemove)
                .help("Remove the selection and join the remaining audio")
                .accessibilityLabel("Delete selected audio")
        }
        .disabled(session.isProcessing)
    }

    private var finishActions: some View {
        HStack(spacing: 8) {
            if session.isProcessing { ProgressView().controlSize(.small) }
            if session.showTrimTool {
                Button("Cancel") { finish(commit: false) }
                    .help("Discard unsaved audio edits")
                Button("Apply") { finish(commit: true) }
                    .disabled(!session.hasEdits)
                    .help("Save the edited audio")
            } else {
                Button(session.hasEdits ? "Save Changes" : "Done") { finish(commit: true) }
            }
        }
        .disabled(session.isReplacing || session.isProcessing)
    }

    private func finish(commit: Bool) {
        player.pause()
        session.end(commit: commit, store: store)
        if !session.isActive { onDone() }
    }

    private var bottomRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                leadingActions.frame(width: 170, alignment: .leading)
                Spacer(minLength: 12)
                transport.frame(width: 170)
                Spacer(minLength: 12)
                finishActions.frame(width: 170, alignment: .trailing)
            }
            VStack(spacing: 14) {
                transport
                HStack {
                    leadingActions
                    Spacer(minLength: 12)
                    finishActions
                }
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var leadingActions: some View {
        if session.showTrimTool { trimActions } else { replaceControl }
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
            .help(
                resuming
                    ? "Continue recording from the end"
                    : "Record over the audio from the playhead")
        }
    }
}

/// Waveform with Voice Memos-style yellow selection handles.
/// Clicking the strip outside the handles seeks playback, so a cut can be
/// auditioned before committing; the playhead is drawn for orientation.
struct TrimSelectionView: View {
    let waveform: WaveformData?
    @Binding var selectionStart: Double
    @Binding var selectionEnd: Double
    var minimumSelection: Double = 0.001
    var progress: Double = 0
    var duration: Double = 0
    var onSeek: ((Double) -> Void)?

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

                handle(
                    "Selection start", symbol: "chevron.left", fraction: selectionStart, at: startX,
                    height: geometry.size.height, width: width
                ) { locationX in
                    let fraction = clampedFraction(locationX, width: width)
                    selectionStart = max(0, min(fraction, selectionEnd - minimumSelection))
                    onSeek?(selectionStart)
                }
                handle(
                    "Selection end", symbol: "chevron.right", fraction: selectionEnd, at: endX,
                    height: geometry.size.height, width: width
                ) { locationX in
                    let fraction = clampedFraction(locationX, width: width)
                    selectionEnd = min(1, max(fraction, selectionStart + minimumSelection))
                    onSeek?(selectionEnd)
                }
            }
            .coordinateSpace(name: "trimSelection")
        }
    }

    private func clampedFraction(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x / width), 1))
    }

    private func handle(
        _ name: String, symbol: String, fraction: Double, at x: CGFloat, height: CGFloat, width: CGFloat,
        onDrag: @escaping (CGFloat) -> Void
    ) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.yellow)
            .frame(width: 12, height: height)
            .overlay(
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
            )
            .frame(width: 24, height: height)
            .contentShape(Rectangle())
            .offset(x: x - 12)
            .accessibilityLabel(name)
            .accessibilityValue(TranscriptFormatter.clock(fraction * duration))
            .accessibilityHint("Adjust to change the selection boundary.")
            .accessibilityAdjustableAction { direction in
                let delta = max(minimumSelection / 2, 0.000001)
                let next = fraction + (direction == .increment ? delta : -delta)
                // The same clamping path is used for dragging and VoiceOver.
                onDrag(CGFloat(next) * width)
            }
            .help("\(name): \(TranscriptFormatter.clock(fraction * duration)). Drag to adjust.")
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("trimSelection"))
                    .onChanged { value in
                        onDrag(value.location.x)
                    }
            )
    }
}
