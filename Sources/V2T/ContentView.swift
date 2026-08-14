import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: TranscriptionModel
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var dropTargeted = false

    private static let speakerColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .red, .indigo,
    ]

    var body: some View {
        Group {
            if !model.hasAPIKey {
                APIKeyOnboardingView()
            } else if model.transcript != nil {
                transcriptView
            } else {
                pickerView
            }
        }
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: TranscriptionModel.supportedTypes
        ) { result in
            if case .success(let url) = result {
                model.select(file: url)
            }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: MarkdownDocument(text: model.exportMarkdown),
            contentType: .plainText,
            defaultFilename: exportFileName
        ) { _ in }
    }

    private var exportFileName: String {
        let base = model.transcript?.sourceFileName ?? "transcript"
        return (base as NSString).deletingPathExtension + " transcript.md"
    }

    // MARK: - File picking

    private var pickerView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text("Drop a recording here")
                .font(.title2.weight(.semibold))
            Text("Drag a memo straight out of Apple Voice Memos,\nor choose an audio file (m4a, mp3, wav…).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Choose File…") { showingImporter = true }
                Button("Open Voice Memos") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/VoiceMemos.app"))
                }
            }

            if let file = model.selectedFile {
                selectedFileCard(file)
            }

            if case .failed(let message) = model.phase {
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: 480)
                    .multilineTextAlignment(.center)
            }

            if model.phase.isBusy {
                progressCard
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    dropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .padding(16)
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    Task { @MainActor in model.select(file: url) }
                }
            }
            return true
        }
    }

    private func selectedFileCard(_ file: URL) -> some View {
        VStack(spacing: 12) {
            Label(file.lastPathComponent, systemImage: "doc.badge.ellipsis")
                .font(.headline)
            if !model.phase.isBusy {
                Button {
                    model.startTranscription()
                } label: {
                    Label("Transcribe", systemImage: "text.bubble")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var progressCard: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(progressLabel)
                .foregroundStyle(.secondary)
            Button("Cancel") { model.cancel() }
        }
    }

    private var progressLabel: String {
        switch model.phase {
        case .uploading: return "Uploading recording…"
        case .queued(let position):
            if let position { return "Waiting in queue (position \(position))…" }
            return "Waiting in queue…"
        case .transcribing: return "Transcribing with ElevenLabs Scribe v2…"
        default: return ""
        }
    }

    // MARK: - Transcript display

    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let transcript = model.transcript {
                speakerLegend(transcript)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(transcript.segments) { segment in
                            segmentRow(segment, transcript: transcript)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func speakerLegend(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speakers — click a name to identify who's who")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(Array(transcript.speakerIds.enumerated()), id: \.element) { index, speakerId in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(forSpeakerIndex: index))
                            .frame(width: 8, height: 8)
                        TextField(
                            "Speaker \(index + 1)",
                            text: Binding(
                                get: { model.speakerNames[speakerId] ?? "" },
                                set: { model.speakerNames[speakerId] = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .frame(width: 110)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func segmentRow(_ segment: TranscriptSegment, transcript: Transcript) -> some View {
        let index = transcript.speakerIds.firstIndex(of: segment.speakerId) ?? 0
        let name = TranscriptFormatter.displayName(
            for: segment.speakerId,
            names: model.speakerNames,
            order: transcript.speakerIds
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color(forSpeakerIndex: index))
                Text(TranscriptFormatter.timestamp(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(segment.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func color(forSpeakerIndex index: Int) -> Color {
        Self.speakerColors[index % Self.speakerColors.count]
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if model.transcript != nil {
                Button {
                    model.copyForClaude()
                } label: {
                    Label(
                        model.copiedFeedback ? "Copied!" : "Copy for Claude",
                        systemImage: model.copiedFeedback ? "checkmark" : "sparkles"
                    )
                }
                .help("Copy the transcript as Markdown, ready to paste into Claude")

                Button {
                    model.copyPlainText()
                } label: {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
                .help("Copy the transcript as plain text")

                Button {
                    showingExporter = true
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .help("Save the transcript as a Markdown file")

                Button {
                    model.reset()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("Start a new transcription")
            }
        }
    }
}

// MARK: - Supporting types

struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct APIKeyOnboardingView: View {
    @EnvironmentObject var model: TranscriptionModel
    @State private var keyInput = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Connect your fal.ai account")
                .font(.title2.weight(.semibold))
            Text("V2T uses ElevenLabs Scribe v2 via fal.ai for the most accurate\ntranscription with speaker labels. Paste your fal API key to get started.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            SecureField("key_id:key_secret", text: $keyInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .onSubmit(save)

            Button("Save API Key", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)

            Link("Get a key at fal.ai/dashboard/keys",
                 destination: URL(string: "https://fal.ai/dashboard/keys")!)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func save() {
        model.saveAPIKey(keyInput)
    }
}
