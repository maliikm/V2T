import SwiftUI

/// The collapsible leftmost column: smart folders (All Recordings,
/// Favorites) plus the user's own folders, with create/rename/delete.
struct FolderSidebarView: View {
    @EnvironmentObject var store: LibraryStore
    @Binding var selection: FolderSelection?

    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: RecordingFolder?
    @State private var renameText = ""
    @State private var deleteTarget: RecordingFolder?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("All Recordings", systemImage: "waveform")
                    .badge(store.recordingCount(in: .all))
                    .tag(FolderSelection.all)
                Label("Favorites", systemImage: "heart")
                    .badge(store.recordingCount(in: .favorites))
                    .tag(FolderSelection.favorites)
            }
            if !store.folders.isEmpty {
                Section("My Folders") {
                    ForEach(store.folders) { folder in
                        Label(folder.name, systemImage: "folder")
                            .badge(store.recordingCount(in: .folder(folder.id)))
                            .tag(FolderSelection.folder(folder.id))
                            .contextMenu {
                                Button("Rename…") {
                                    renameTarget = folder
                                    renameText = folder.name
                                }
                                Button("Delete Folder", role: .destructive) {
                                    deleteTarget = folder
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Folders")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    newFolderName = ""
                    showingNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.bar)
        }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                if let folder = store.createFolder(named: newFolderName) {
                    selection = .folder(folder.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Folder", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    store.renameFolder(target.id, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete “\(deleteTarget?.name ?? "")”?",
            isPresented: deleteBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let target = deleteTarget {
                    if selection == .folder(target.id) { selection = .all }
                    store.deleteFolder(target.id)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Its recordings move back to All Recordings; nothing is deleted.")
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }
}
