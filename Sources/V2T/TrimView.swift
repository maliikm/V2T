import SwiftUI
import AVFoundation

/// Voice Memos-style Trim sheet: drag the yellow handles to select a range,
/// then Trim (keep the selection) or Delete (remove it). Edits apply to a
/// working copy; Apply commits it to the library, Cancel discards.
struct TrimView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let recording: Recording
    let waveform: WaveformData?
    /// Called after Apply commits new audio.
    var onApplied: () -> Void

    /// Selection as fractions of the working file's duration.
    @State private var selectionStart: Double = 0
    @State private var selectionEnd: Double = 1
    /// Working copy of the audio while editing; nil until an edit happens.
    @State private var workingURL: URL?
    @State private var workingDuration: Double = 0
    @State private var workingWaveform: WaveformData?
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var previewPlayer: AVAudioPlayer?
    @State private var isPreviewPlaying = false
    @State private var hasEdits = false
    /// Retained strongly here because AVAudioPlayer.delegate is weak.
    @State private var previewDelegate = PreviewDelegate()

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Trim").font(.title3.weight(.semibold))
                Spacer()
            }

            VStack(spacing: 2) {
                Text(recording.title).font(.headline)
                Text("\(recording.dateLabel)  \(TranscriptFormatter.timestamp(workingDuration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TrimSelectionView(
                waveform: workingWaveform ?? waveform,
                selectionStart: $selectionStart,
                selectionEnd: $selectionEnd
            )
            .frame(height: 90)

            HStack {
                Text(TranscriptFormatter.timestamp(selectionStart * workingDuration))
                Spacer()
                Text(TranscriptFormatter.timestamp(selectionEnd * workingDuration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack(spacing: 16) {
                Button("Trim") { performEdit(keepSelection: true) }
                    .help("Keep only the selected range")
                Button("Delete") { performEdit(keepSelection: false) }
                    .help("Remove the selected range")

                Spacer()

                Button {
                    togglePreview()
                } label: {
                    Image(systemName: isPreviewPlaying ? "pause.fill" : "play.fill")
                }
                .help("Preview the current working audio")

                Spacer()

                Button("Cancel") { cancel() }
                Button("Apply") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasEdits || isProcessing)
            }
            .disabled(isProcessing)

            if isProcessing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(24)
        .onAppear {
            workingDuration = recording.duration
            workingWaveform = waveform
        }
        .onDisappear {
            previewPlayer?.stop()
            discardWorkingFile()
        }
    }

    // MARK: - Editing

    private var selectionRange: ClosedRange<Double> {
        let start = min(selectionStart, selectionEnd) * workingDuration
        let end = max(selectionStart, selectionEnd) * workingDuration
        return start...max(end, start + 0.01)
    }

    private var currentAudioURL: URL {
        workingURL ?? store.audioURL(for: recording)
    }

    private func performEdit(keepSelection: Bool) {
        guard !isProcessing, workingDuration > 0 else { return }
        let range = selectionRange
        guard range.upperBound - range.lowerBound >= 0.2 else {
            errorMessage = "Selection is too short."
            return
        }
        isProcessing = true
        errorMessage = nil
        previewPlayer?.stop()
        isPreviewPlaying = false

        let sourceURL = currentAudioURL
        let total = workingDuration
        Task {
            do {
                let edited: URL
                if keepSelection {
                    edited = try await AudioEditor.trim(url: sourceURL, keeping: range)
                } else {
                    edited = try await AudioEditor.deleteRange(url: sourceURL, removing: range, totalDuration: total)
                }
                let newDuration = await AudioEditor.duration(of: edited)
                guard newDuration > 0.1 else {
                    errorMessage = "That edit would leave no audio."
                    isProcessing = false
                    return
                }
                // Replace the previous working copy.
                if let old = workingURL {
                    try? FileManager.default.removeItem(at: old)
                }
                workingURL = edited
                workingDuration = newDuration
                workingWaveform = try? await WaveformLoader.load(audioURL: edited, cacheURL: nil)
                selectionStart = 0
                selectionEnd = 1
                hasEdits = true
                previewPlayer = nil
                isProcessing = false
            } catch {
                errorMessage = error.localizedDescription
                isProcessing = false
            }
        }
    }

    private func togglePreview() {
        // Trust the player, not the flag: at the natural end the player stops
        // itself, so a stale flag must fall through to the play branch.
        if isPreviewPlaying, previewPlayer?.isPlaying == true {
            previewPlayer?.pause()
            isPreviewPlaying = false
            return
        }
        if previewPlayer == nil {
            previewPlayer = try? AVAudioPlayer(contentsOf: currentAudioURL)
            previewPlayer?.delegate = previewDelegate
            previewPlayer?.prepareToPlay()
        }
        previewDelegate.onFinish = { isPreviewPlaying = false }
        previewPlayer?.play()
        isPreviewPlaying = true
    }

    private func apply() {
        guard let workingURL, hasEdits else { return }
        previewPlayer?.stop()
        store.replaceAudio(for: recording.id, with: workingURL, duration: workingDuration)
        self.workingURL = nil
        onApplied()
        dismiss()
    }

    private func cancel() {
        previewPlayer?.stop()
        discardWorkingFile()
        dismiss()
    }

    private func discardWorkingFile() {
        if let workingURL {
            try? FileManager.default.removeItem(at: workingURL)
        }
        workingURL = nil
    }
}

/// Bridges AVAudioPlayer's end-of-playback callback to a closure, so the
/// preview button's state can reset when the audio finishes on its own.
final class PreviewDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onFinish?()
        }
    }
}

/// Waveform with the yellow selection band and drag handles.
private struct TrimSelectionView: View {
    let waveform: WaveformData?
    @Binding var selectionStart: Double
    @Binding var selectionEnd: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = CGFloat(min(selectionStart, selectionEnd)) * width
            let endX = CGFloat(max(selectionStart, selectionEnd)) * width

            ZStack(alignment: .leading) {
                WaveformView(data: waveform, progress: 0, onSeek: nil)
                    .allowsHitTesting(false)

                // Selection band
                Rectangle()
                    .fill(Color.yellow.opacity(0.18))
                    .frame(width: max(0, endX - startX))
                    .offset(x: startX)

                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.yellow, lineWidth: 2.5)
                    .frame(width: max(8, endX - startX))
                    .offset(x: startX)

                handle(at: startX, height: geometry.size.height) { locationX in
                    selectionStart = clampedFraction(locationX, width: width)
                }
                handle(at: endX, height: geometry.size.height) { locationX in
                    selectionEnd = clampedFraction(locationX, width: width)
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
