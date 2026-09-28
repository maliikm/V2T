import SwiftUI

/// The right-hand pane: header, waveform/transcript area, big time counter,
/// transport, and the Voice Memos-style toolbar.
struct DetailView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var player: AudioPlayerController
    @EnvironmentObject var transcriber: TranscriptionManager
    @EnvironmentObject var settings: AppSettings

    let recordingID: UUID?

    @State private var waveform: WaveformData?
    /// Waveform is the default view; the toolbar button flips to transcript.
    @State private var showTranscript = false
    @State private var showOptions = false
    @StateObject private var editSession = AudioEditSession()
    @State private var showDeleteConfirm = false
    @State private var copiedFeedback = false
    @State private var titleDraft = ""

    var body: some View {
        if let recording = store.recording(with: recordingID) {
            content(recording)
                .id(recording.id)
        } else {
            Text("No Recording Selected")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ recording: Recording) -> some View {
        VStack(spacing: 0) {
            header(recording)

            if editSession.isActive {
                EditModeView(session: editSession, recording: recording) {
                    waveform = nil
                    Task { await loadAudio(recording, force: true) }
                }
            } else {
                if showTranscript {
                    TranscriptPane(recording: recording)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ZoomedWaveformView(
                        data: waveform,
                        currentTime: player.currentTime,
                        duration: player.duration > 0 ? player.duration : recording.duration
                    ) { time in
                        player.seek(to: time)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 16)
                }

                bottomControls(recording)
            }
        }
        .onDisappear {
            // Trim mode is an explicit Cancel/Apply transaction. Navigation
            // must not save a trim that the user has not applied.
            if editSession.isActive {
                editSession.end(commit: !editSession.showTrimTool, store: store)
            }
        }
        .task(id: recording.audioFileName + recording.id.uuidString) {
            await loadAudio(recording)
        }
        .onAppear { titleDraft = recording.title }
        .toolbar { toolbarContent(recording) }
        .popover(isPresented: $showOptions) { optionsPopover }
        .confirmationDialog("Delete “\(recording.title)”?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                transcriber.cancel(recording.id)
                player.unloadIfLoaded(recording.id)
                store.delete(recording.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Pieces

    private func header(_ recording: Recording) -> some View {
        VStack(spacing: 2) {
            TextField("Title", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .onSubmit { store.rename(recording.id, to: titleDraft) }
            HStack(spacing: 8) {
                Text(recording.dateLabel)
                Text(recording.durationLabel).monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 16)
        .padding(.horizontal, 24)
    }

    private func bottomControls(_ recording: Recording) -> some View {
        VStack(spacing: 10) {
            WaveformView(data: waveform, progress: progressFraction) { fraction in
                player.seek(to: fraction * player.duration)
            }
            .frame(height: 56)
            .padding(.horizontal, 24)
            HStack {
                Text("0:00")
                Spacer()
                Text(TranscriptFormatter.timestamp(player.duration > 0 ? player.duration : recording.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)

            Text(TranscriptFormatter.clock(player.currentTime))
                .font(.system(size: 40, weight: .bold).monospacedDigit())

            HStack(spacing: 28) {
                Button { player.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title2)
                }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .frame(width: 44, height: 44)
                }
                Button { player.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title2)
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
        }
        .padding(.top, 8)
    }

    private var optionsPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Options").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Playback Speed")
                    Spacer()
                    Text(String(format: "%.2g×", player.rate)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $player.rate, in: 0.5...2.0, step: 0.25)
            }
            Toggle("Skip Silence", isOn: $player.skipSilence)
            Button("Reset") {
                player.rate = 1.0
                player.skipSilence = false
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    @ToolbarContentBuilder
    private func toolbarContent(_ recording: Recording) -> some ToolbarContent {
        if editSession.isActive {
            ToolbarItemGroup {
                Button {
                    editSession.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .labelStyle(.titleAndIcon)
                .disabled(!editSession.canUndo || editSession.isProcessing || editSession.isReplacing)
                .help("Undo the last edit")

                if !editSession.showTrimTool {
                    Button {
                        editSession.showTrimTool = true
                    } label: {
                        Label("Trim Audio", systemImage: "scissors")
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(editSession.isReplacing || editSession.isProcessing)
                    .help("Select the audio to trim or delete")
                }
            }
        } else {
            normalToolbar(recording)
        }
    }

    @ToolbarContentBuilder
    private func normalToolbar(_ recording: Recording) -> some ToolbarContent {
        ToolbarItemGroup {
            ShareLink(item: store.audioURL(for: recording)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button {
                store.toggleFavorite(recording.id)
            } label: {
                Label("Favorite", systemImage: recording.isFavorite ? "heart.fill" : "heart")
            }
            Button {
                editSession.begin(recording: recording, store: store, player: player, initialWaveform: waveform)
            } label: {
                Label("Edit Audio", systemImage: "pencil")
            }
            .labelStyle(.titleAndIcon)
            .help("Edit the audio: trim, replace, or resume recording")
            Button {
                showDeleteConfirm = true
            } label: {
                Label("Delete Recording", systemImage: "trash")
            }
            Button {
                showOptions.toggle()
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            .help("Playback speed and Skip Silence")
            Button {
                showTranscript.toggle()
            } label: {
                Label(
                    showTranscript ? "Waveform" : "Transcript",
                    systemImage: showTranscript ? "waveform" : "quote.bubble"
                )
            }
            .help(showTranscript ? "Show the zoomed waveform" : "Show the transcript")

            if recording.hasTranscript {
                Menu {
                    Button("Copy Markdown") { copyMarkdown(recording) }
                    Button("Copy Plain Text") { copyPlainText(recording) }
                } label: {
                    Label(copiedFeedback ? "Copied!" : "Copy Transcript", systemImage: copiedFeedback ? "checkmark" : "doc.on.doc")
                }
                .help("Copy the transcript as Markdown or plain text")
            }
        }
    }

    // MARK: - Helpers

    private var progressFraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / player.duration))
    }

    private func loadAudio(_ recording: Recording, force: Bool = false) async {
        if force {
            player.unloadIfLoaded(recording.id)
        }
        guard let current = store.recording(with: recording.id) else { return }
        let url = store.audioURL(for: current)
        player.load(recordingID: current.id, url: url)
        let loaded = try? await WaveformLoader.load(
            audioURL: url,
            cacheURL: store.waveformCacheURL(for: current.id)
        )
        // The user may have switched recordings while the waveform computed;
        // don't overwrite the newer selection's data with this stale result.
        guard !Task.isCancelled, player.currentRecordingID == current.id else { return }
        waveform = loaded
        if let loaded {
            player.silentRanges = WaveformLoader.silentRanges(in: loaded)
        }
    }

    private func exportMarkdown(_ recording: Recording) -> String {
        guard let transcript = store.transcript(for: recording.id) else { return "" }
        return TranscriptFormatter.markdown(transcript, names: recording.speakerNames)
    }

    private func copyMarkdown(_ recording: Recording) {
        copy(exportMarkdown(recording))
    }

    private func copyPlainText(_ recording: Recording) {
        guard let transcript = store.transcript(for: recording.id) else { return }
        copy(TranscriptFormatter.plainText(transcript, names: recording.speakerNames))
    }

    private func copy(_ string: String) {
        guard !string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        copiedFeedback = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedFeedback = false
        }
    }
}
