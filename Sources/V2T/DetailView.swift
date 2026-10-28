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
    @State private var showTranscript = true
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
            ContentUnavailableView("Your recordings, in words", systemImage: "text.bubble",
                                   description: Text("Choose a recording to read its transcript, or start a new recording from the library."))
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
        .onAppear {
            titleDraft = recording.title
            if player.isPlaybackBlocked { showTranscript = true }
        }
        .onChange(of: recording.title) { oldValue, newValue in
            if titleDraft == oldValue { titleDraft = newValue }
        }
        .onChange(of: player.isPlaybackBlocked) { _, blocked in
            if blocked && editSession.isActive {
                editSession.end(commit: !editSession.showTrimTool, store: store)
            }
        }
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
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.bold))
                    .onSubmit { store.rename(recording.id, to: titleDraft) }
                Text("\(recording.dateLabel) · \(recording.timeLabel) · \(recording.durationLabel)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if recording.hasTranscript {
                Button { copyPlainText(recording) } label: {
                    Label(copiedFeedback ? "Copied" : "Copy Transcript", systemImage: copiedFeedback ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.large)
                .help("Copy speaker names, timestamps, and text")
            }
        }
        .padding(.top, 20).padding(.bottom, 12).padding(.horizontal, 24)
    }

    private func bottomControls(_ recording: Recording) -> some View {
        VStack(spacing: 10) {
            if showTranscript {
                Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                       in: 0...max(0.01, player.duration))
                    .accessibilityLabel("Playback position")
                    .padding(.horizontal, 24)
            } else {
                WaveformView(data: waveform, progress: progressFraction) { fraction in
                    player.seek(to: fraction * player.duration)
                }
                .frame(height: 44).padding(.horizontal, 24)
            }
            HStack {
                Text("0:00")
                Spacer()
                Text(TranscriptFormatter.timestamp(player.duration > 0 ? player.duration : recording.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)

            HStack(spacing: 28) {
                Text(TranscriptFormatter.timestamp(player.currentTime)).font(.body.monospacedDigit())
                Button { player.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title3)
                }
                .accessibilityLabel("Skip back 15 seconds")
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .frame(width: 32, height: 32)
                }
                .disabled(player.isPlaybackBlocked)
                .accessibilityLabel(player.isPlaying ? "Pause playback" : "Play recording")
                .help(player.isPlaybackBlocked ? "Playback is available after recording stops" : "Play or pause")
                Button { player.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title3)
                }
                .accessibilityLabel("Skip forward 15 seconds")
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
            if player.isPlaybackBlocked {
                Text("You can read and copy transcripts while recording. Playback is available after you stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
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
            Button { showTranscript.toggle() } label: {
                Label(showTranscript ? "Waveform" : "Transcript", systemImage: showTranscript ? "waveform" : "quote.bubble")
            }
            .help(showTranscript ? "Show waveform for seeking" : "Read transcript")
            Button {
                editSession.begin(recording: recording, store: store, player: player, initialWaveform: waveform)
            } label: {
                Label("Edit Audio", systemImage: "waveform.badge.magnifyingglass")
            }
            .disabled(player.isPlaybackBlocked)
            .help("Trim, delete, replace, or append audio")
            Menu {
                if recording.hasTranscript {
                    Button("Copy Markdown") { copyMarkdown(recording) }
                    Divider()
                }
                ShareLink(item: store.audioURL(for: recording)) { Label("Share Audio", systemImage: "square.and.arrow.up") }
                Button(recording.isFavorite ? "Remove Favorite" : "Favorite") { store.toggleFavorite(recording.id) }
                Button("Playback Options…") { showOptions = true }
                Divider()
                Button("Delete Recording…", role: .destructive) { showDeleteConfirm = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Export, share, favorite, playback options, or delete")
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
