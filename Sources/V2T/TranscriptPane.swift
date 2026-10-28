import SwiftUI

/// The diarized transcript for a recording: speaker chips (renameable),
/// speaker-labeled segments that follow playback and seek on click — plus
/// the transcribe flow when no transcript exists yet.
struct TranscriptPane: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var transcriber: TranscriptionManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var player: AudioPlayerController

    let recording: Recording

    private static let speakerColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .red, .indigo,
    ]

    var body: some View {
        Group {
            if let status = transcriber.status(for: recording.id) {
                if let preview = store.livePreview(for: recording.id) {
                    previewBody(preview, status: status.label)
                } else {
                    progressState(status)
                }
            } else if let transcript = store.transcript(for: recording.id), recording.hasTranscript {
                transcriptBody(transcript)
            } else if let preview = store.livePreview(for: recording.id) {
                previewBody(preview, status: transcriber.error(for: recording.id) ?? "Live preview saved. Generate the final transcript for speaker labels.")
            } else {
                emptyState
            }
        }
    }

    // MARK: - States

    private func previewBody(_ text: String, status: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Copy Preview") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                if transcriber.isBusy(recording.id) {
                    Button("Cancel Final Transcription") { transcriber.cancel(recording.id) }
                } else {
                    Button("Generate Final Transcript") {
                        transcriber.transcribe(recording, store: store, settings: settings)
                    }.disabled(!settings.hasAPIKey)
                }
            }
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progressState(_ status: TranscribeStatus) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(status.label).foregroundStyle(.secondary)
            if let provider = transcriber.providers[recording.id] {
                Text(provider.title).font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel") { transcriber.cancel(recording.id) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.bubble")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No transcript yet")
                .font(.title3.weight(.semibold))

            if !settings.hasAPIKey {
                Text("Add your \(settings.provider.name) API key in Settings (⌘,) to transcribe.")
                    .foregroundStyle(.secondary)
            } else {
                if settings.provider == .fal {
                    Picker("Speakers:", selection: speakersBinding) {
                        Text("Auto-detect").tag(0)
                        ForEach(2...16, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .frame(maxWidth: 260)
                    .help("Setting the real number of people speaking makes speaker labels much more accurate.")
                } else {
                    Text("Deepgram · Nova-3 · Automatic speaker detection").font(.callout).foregroundStyle(.secondary)
                }

                Button {
                    transcriber.transcribe(recording, store: store, settings: settings)
                } label: {
                    Label("Transcribe", systemImage: "waveform.badge.mic")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
            }

            if let error = transcriber.error(for: recording.id) {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var speakersBinding: Binding<Int> {
        Binding(
            // Show the effective value: the recording's own setting if made,
            // otherwise the global default that would actually be sent.
            get: {
                store.recording(with: recording.id)?.numSpeakersHint ?? settings.defaultNumSpeakers
            },
            set: { store.setNumSpeakersHint($0, for: recording.id) }
        )
    }

    // MARK: - Transcript

    private func transcriptBody(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(transcript.provider.flatMap(TranscriptionProvider.init(rawValue:))?.title ?? "Earlier transcript")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Previous Versions") {
                    NSWorkspace.shared.open(store.folderURL(for: recording.id).appendingPathComponent("Transcript History"))
                }
                .font(.caption)
                .disabled(!FileManager.default.fileExists(atPath: store.folderURL(for: recording.id).appendingPathComponent("Transcript History").path))
            }.padding(.horizontal, 20).padding(.top, 8)
            if let error = transcriber.error(for: recording.id) {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(12)
            }
            speakerLegend(transcript)
            if !(store.speakerEditHistory[recording.id] ?? []).isEmpty {
                Button("Undo Speaker Change") { store.undoSpeakerEdit(for: recording.id) }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(transcript.segments.enumerated()), id: \.element.id) { index, segment in
                            segmentRow(segment, index: index, transcript: transcript)
                                .id(segment.id)
                        }
                    }
                    .padding(20)
                }
                .onChange(of: currentSegmentIndex(transcript)) { _, newIndex in
                    guard player.isPlaying,
                          player.currentRecordingID == recording.id,
                          let newIndex,
                          transcript.segments.indices.contains(newIndex) else { return }
                    withAnimation {
                        proxy.scrollTo(transcript.segments[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func speakerLegend(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name speakers here. Use a passage's speaker menu to correct who said it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(transcript.speakerIds.enumerated()), id: \.element) { index, speakerId in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color(forSpeakerIndex: index))
                                .frame(width: 8, height: 8)
                            TextField(
                                "Speaker \(index + 1)",
                                text: nameBinding(for: speakerId)
                            )
                            .textFieldStyle(.plain)
                            .frame(width: 110)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func nameBinding(for speakerId: String) -> Binding<String> {
        Binding(
            get: { store.recording(with: recording.id)?.speakerNames[speakerId] ?? "" },
            set: { newValue in
                var names = store.recording(with: recording.id)?.speakerNames ?? [:]
                names[speakerId] = newValue
                store.setSpeakerNames(names, for: recording.id)
            }
        )
    }

    private func segmentRow(_ segment: TranscriptSegment, index: Int, transcript: Transcript) -> some View {
        let speakerIndex = transcript.speakerIds.firstIndex(of: segment.speakerId) ?? 0
        let names = store.recording(with: recording.id)?.speakerNames ?? [:]
        let name = TranscriptFormatter.displayName(
            for: segment.speakerId, names: names, order: transcript.speakerIds
        )
        let isCurrent = currentSegmentIndex(transcript) == index
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Menu {
                    Text("Assign this passage to")
                    ForEach(transcript.speakerIds, id: \.self) { id in
                        Button(TranscriptFormatter.displayName(for: id, names: names, order: transcript.speakerIds)) {
                            store.reassignSpeaker(for: recording.id, segmentIndex: index, to: id)
                        }
                        .disabled(id == segment.speakerId)
                    }
                    Divider()
                    Menu("Reassign All “\(name)” Passages") {
                        ForEach(transcript.speakerIds.filter { $0 != segment.speakerId }, id: \.self) { id in
                            Button(TranscriptFormatter.displayName(for: id, names: names, order: transcript.speakerIds)) {
                                store.reassignSpeaker(for: recording.id, segmentIndex: index, to: id, allOccurrences: true)
                            }
                        }
                    }
                } label: {
                    Text(name).font(.subheadline.weight(.semibold))
                        .foregroundStyle(color(forSpeakerIndex: speakerIndex))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Assign this passage to another speaker")
                Text(TranscriptFormatter.timestamp(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(segment.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        // Single click moves the playhead here; playback continues (or the
        // next press of Space / Play starts) from this block.
        .onTapGesture {
            player.seek(to: segment.start)
        }
        .contextMenu {
            Button("Play from Here") {
                player.seek(to: segment.start)
                if !player.isPlaying { player.play() }
            }
            .disabled(player.isPlaybackBlocked)
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.text, forType: .string)
            }
        }
        .help("Click to move playback here")
    }

    private func currentSegmentIndex(_ transcript: Transcript) -> Int? {
        guard player.currentRecordingID == recording.id else { return nil }
        return transcript.segmentIndex(at: player.currentTime)
    }

    private func color(forSpeakerIndex index: Int) -> Color {
        Self.speakerColors[index % Self.speakerColors.count]
    }
}
