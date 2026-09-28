import SwiftUI

/// Explicit time selection, keep/remove actions, and a separate transport.
/// Keeping and removing are previewable edits; Save Changes ends edit mode.
struct EditModeView: View {
    @ObservedObject var session: AudioEditSession
    let recording: Recording
    /// Called after Done commits and ends the session.
    var onDone: () -> Void

    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var player: AudioPlayerController

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 10) {
                    ZoomedWaveformView(
                        data: session.workingWaveform,
                        currentTime: player.currentTime,
                        duration: session.workingDuration
                    ) { time in
                        guard !session.isReplacing else { return }
                        player.seek(to: time)
                    }
                    .frame(height: max(96, geometry.size.height - (session.showTrimTool ? 500 : 300)))
                    .padding(.top, 8)

                    if session.showTrimTool {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Trim Audio", systemImage: "scissors").font(.headline)
                                Spacer()
                                Button("Hide Trim") { session.showTrimTool = false }
                                    .help("Hide the selection controls without undoing edits")
                            }
                            Text("Drag the handles or enter start and end times in seconds.")
                                .font(.caption).foregroundStyle(.secondary)
                            TrimSelectionView(
                                waveform: session.workingWaveform,
                                selectionStart: $session.selectionStart,
                                selectionEnd: $session.selectionEnd,
                                minimumSelection: session.trimSelection.minimumFraction,
                                progress: progressFraction,
                                onSeek: { fraction in
                                    guard !session.isReplacing else { return }
                                    player.seek(to: fraction * session.workingDuration)
                                }
                            )
                            .frame(height: 56)
                            selectionInputs
                            Text("Selected: \(TranscriptFormatter.clock(session.trimSelection.selectedDuration))")
                                .font(.caption.weight(.medium)).monospacedDigit()
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Button("Keep Selection") {
                                        Task { await session.applyTrim(keepSelection: true) }
                                    }
                                    .font(.callout.weight(.medium)).foregroundStyle(.primary)
                                    .disabled(!session.trimSelection.canKeep)
                                    Text("Remove audio outside the selection.")
                                    Text(
                                        "Result: \(TranscriptFormatter.clock(session.trimSelection.selectedDuration))"
                                    ).monospacedDigit()
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .leading, spacing: 4) {
                                    Button("Remove Selection") {
                                        Task { await session.applyTrim(keepSelection: false) }
                                    }
                                    .font(.callout.weight(.medium)).foregroundStyle(.primary)
                                    .disabled(!session.trimSelection.canRemove)
                                    Text("Cut this section and join the rest.")
                                    Text(
                                        "Result: \(TranscriptFormatter.clock(session.trimSelection.remainingDuration))"
                                    ).monospacedDigit()
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                            if !session.trimSelection.canKeep && !session.trimSelection.canRemove {
                                Text(
                                    "Select part of the recording to enable an edit. At least 0.2 seconds must remain."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 24)
                        .disabled(session.isProcessing || session.isReplacing)
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

                    Text(
                        TranscriptFormatter.clock(
                            session.isReplacing ? session.replaceElapsed : player.currentTime)
                    )
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
        }
    }

    // MARK: - Pieces

    private var progressFraction: Double {
        guard session.workingDuration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / session.workingDuration))
    }

    private var selectionInputs: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start (seconds)").font(.caption)
                TextField(
                    "Start (seconds)",
                    value: Binding(
                        get: { session.trimSelection.range.lowerBound },
                        set: { session.setSelectionStart(seconds: $0) }),
                    format: .number.precision(.fractionLength(2))
                )
                .accessibilityLabel("Selection start in seconds")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("End (seconds)").font(.caption)
                TextField(
                    "End (seconds)",
                    value: Binding(
                        get: { session.trimSelection.range.upperBound },
                        set: { session.setSelectionEnd(seconds: $0) }),
                    format: .number.precision(.fractionLength(2))
                )
                .accessibilityLabel("Selection end in seconds")
            }
        }.textFieldStyle(.roundedBorder).monospacedDigit()
    }

    private var bottomRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 28) {
                Button {
                    player.skip(-15)
                } label: {
                    Image(systemName: "gobackward.15").font(.title2)
                }.help("Back 15 seconds").accessibilityLabel("Back 15 seconds")
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .frame(width: 40, height: 40)
                }.help(player.isPlaying ? "Pause playback" : "Play audio")
                    .accessibilityLabel(player.isPlaying ? "Pause playback" : "Play audio")
                Button {
                    player.skip(15)
                } label: {
                    Image(systemName: "goforward.15").font(.title2)
                }.help("Forward 15 seconds").accessibilityLabel("Forward 15 seconds")
            }
            .buttonStyle(.plain)
            .disabled(session.isReplacing || session.isProcessing)

            HStack {
                if session.showTrimTool {
                    Button {
                        session.undo()
                    } label: {
                        Label("Undo Edit", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!session.canUndo || session.isProcessing)
                } else {
                    replaceControl
                }
                Spacer()
                if session.isProcessing { ProgressView().controlSize(.small) }
                Button(session.hasEdits ? "Save Changes" : "Done") {
                    session.end(commit: true, store: store)
                    if !session.isActive { onDone() }
                }
                .controlSize(.large)
                .disabled(session.isReplacing || session.isProcessing)
                .help(session.hasEdits ? "Save the edited audio and leave edit mode" : "Leave edit mode")
            }
            Text("Undo reverses your last edit. Edits save when you finish or switch recordings.")
                .font(.caption).foregroundStyle(.secondary)
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
            .help(
                resuming
                    ? "Continue recording from the end"
                    : "Record over the audio from the playhead")
        }
    }
}

/// Waveform with an accent-colored selection band and labeled drag handles.
/// Clicking the strip outside the handles seeks playback, so a cut can be
/// auditioned before committing; the playhead is drawn for orientation.
struct TrimSelectionView: View {
    let waveform: WaveformData?
    @Binding var selectionStart: Double
    @Binding var selectionEnd: Double
    var minimumSelection: Double = 0.001
    var progress: Double = 0
    var onSeek: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = CGFloat(min(selectionStart, selectionEnd)) * width
            let endX = CGFloat(max(selectionStart, selectionEnd)) * width

            ZStack(alignment: .leading) {
                WaveformView(data: waveform, progress: progress, onSeek: onSeek)

                Rectangle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: max(0, endX - startX))
                    .offset(x: startX)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .frame(width: max(8, endX - startX))
                    .offset(x: startX)
                    .allowsHitTesting(false)

                handle("Selection start", at: startX, height: geometry.size.height) { locationX in
                    let fraction = clampedFraction(locationX, width: width)
                    selectionStart = max(0, min(fraction, selectionEnd - minimumSelection))
                }
                handle("Selection end", at: endX, height: geometry.size.height) { locationX in
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

    private func handle(
        _ name: String, at x: CGFloat, height: CGFloat, onDrag: @escaping (CGFloat) -> Void
    ) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor)
            .frame(width: 12, height: height)
            .overlay(
                Image(systemName: "line.3.horizontal").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            )
            .frame(width: 24, height: height)
            .contentShape(Rectangle())
            .offset(x: x - 12)
            .accessibilityLabel(name)
            .accessibilityHint("Use the start and end fields below for precise times.")
            .help("Drag to adjust \(name.lowercased())")
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("trimSelection"))
                    .onChanged { value in
                        onDrag(value.location.x)
                    }
            )
    }
}
