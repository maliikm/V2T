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
                progressState(status)
            } else if let transcript = store.transcript(for: recording.id), recording.hasTranscript {
                transcriptBody(transcript)
            } else {
                emptyState
            }
        }
    }

    // MARK: - States

    private func progressState(_ status: TranscribeStatus) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(status.label).foregroundStyle(.secondary)
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
                Text("Add your fal.ai API key in Settings (⌘,) to transcribe.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Speakers:", selection: speakersBinding) {
                    Text("Auto-detect").tag(0)
                    ForEach(2...16, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .frame(maxWidth: 260)
                .help("Setting the real number of people speaking makes speaker labels much more accurate.")

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
            get: { store.recording(with: recording.id)?.numSpeakersHint ?? 0 },
            set: { store.setNumSpeakersHint($0, for: recording.id) }
        )
    }

    // MARK: - Transcript

    private func transcriptBody(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            speakerLegend(transcript)
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
                .onChange(of: currentSegmentIndex(transcript)) { newIndex in
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
            Text("Speakers — click a name to identify who's who")
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
                        .background(.quaternary.opacity(0.5), in: Capsule())
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
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color(forSpeakerIndex: speakerIndex))
                Text(TranscriptFormatter.timestamp(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(segment.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            player.seek(to: segment.start)
        }
    }

    private func currentSegmentIndex(_ transcript: Transcript) -> Int? {
        guard player.currentRecordingID == recording.id else { return nil }
        return transcript.segmentIndex(at: player.currentTime)
    }

    private func color(forSpeakerIndex index: Int) -> Color {
        Self.speakerColors[index % Self.speakerColors.count]
    }
}
