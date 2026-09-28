import SwiftUI
import UniformTypeIdentifiers

/// The permanent recordings-list column: search, context menus,
/// drag-and-drop import, and the red record button pinned at the bottom.
/// Shows the recordings of whichever folder is selected in the (collapsible)
/// folder sidebar.
struct RecordingsListView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var recorder: RecorderController
    @EnvironmentObject var transcriber: TranscriptionManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var player: AudioPlayerController
    @EnvironmentObject var appAudio: AppAudioRecorder

    @Binding var selection: UUID?
    let folder: FolderSelection
    @State private var searchText = ""
    @State private var showingImporter = false
    @State private var renameTarget: Recording?
    @State private var renameText = ""
    @State private var deleteTarget: Recording?

    var body: some View {
        List(selection: $selection) {
            ForEach(store.filtered(search: searchText, folder: folder)) { recording in
                RecordingRow(recording: recording, isTranscribing: transcriber.isBusy(recording.id))
                    .tag(recording.id)
                    .contextMenu { contextMenu(for: recording) }
            }
        }
        .listStyle(.inset)
        .searchable(text: $searchText, prompt: "Titles, Transcripts")
        .navigationTitle(listTitle)
        .safeAreaInset(edge: .bottom) { RecordingControlsView() }
        .onChange(of: store.lastSavedRecordingID) { _, id in
            if id != nil { searchText = "" }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import Audio…", systemImage: "square.and.arrow.down")
                }
                .help("Import an audio file (or just drag one into the list)")
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                importFiles(urls)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        Task { @MainActor in importFiles([url]) }
                    }
                }
            }
            return true
        }
        .alert("Rename Recording", isPresented: renameAlertBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    store.rename(target.id, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete “\(deleteTarget?.title ?? "")”?",
            isPresented: deleteAlertBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    deleteRecording(target)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("The audio and its transcript will be removed.")
        }
    }

    private var listTitle: String {
        switch folder {
        case .all: return "All Recordings"
        case .favorites: return "Favorites"
        case .folder(let id): return store.folder(with: id)?.name ?? "Folder"
        }
    }

    /// The folder new recordings and imports land in.
    private var targetFolderID: UUID? {
        if case .folder(let id) = folder { return id }
        return nil
    }

    // MARK: - Row actions

    @ViewBuilder
    private func contextMenu(for recording: Recording) -> some View {
        Button(recording.isFavorite ? "Remove Favorite" : "Favorite") {
            store.toggleFavorite(recording.id)
        }
        Button("Rename…") {
            renameTarget = recording
            renameText = recording.title
        }
        if !store.folders.isEmpty {
            Menu("Move to Folder") {
                Button("None (All Recordings)") {
                    store.move(recording.id, toFolder: nil)
                }
                .disabled(recording.folderID == nil)
                Divider()
                ForEach(store.folders) { folder in
                    Button(folder.name) {
                        store.move(recording.id, toFolder: folder.id)
                    }
                    .disabled(recording.folderID == folder.id)
                }
            }
        }
        if !transcriber.isBusy(recording.id) {
            Button(recording.hasTranscript ? "Re-transcribe" : "Transcribe") {
                transcriber.transcribe(recording, store: store, settings: settings)
            }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([store.audioURL(for: recording)])
        }
        Divider()
        Button("Delete", role: .destructive) {
            deleteTarget = recording
        }
    }

    private func deleteRecording(_ recording: Recording) {
        transcriber.cancel(recording.id)
        player.unloadIfLoaded(recording.id)
        if selection == recording.id { selection = nil }
        store.delete(recording.id)
    }

    private func importFiles(_ urls: [URL]) {
        Task {
            for url in urls {
                if var recording = await store.importAudio(from: url) {
                    if let targetFolderID {
                        store.move(recording.id, toFolder: targetFolderID)
                        recording.folderID = targetFolderID
                    }
                    selection = recording.id
                    if settings.autoTranscribe && settings.hasAPIKey {
                        transcriber.transcribe(recording, store: store, settings: settings)
                    }
                }
            }
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }


}

private struct RecordingRow: View {
    let recording: Recording
    let isTranscribing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(recording.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if recording.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(recording.dateLabel)
                if isTranscribing {
                    ProgressView().controlSize(.mini)
                } else if recording.hasTranscript {
                    Image(systemName: "quote.bubble")
                        .font(.caption2)
                }
                Spacer()
                Text(recording.durationLabel)
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
