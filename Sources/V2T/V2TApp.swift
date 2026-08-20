import SwiftUI

@main
struct V2TApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = LibraryStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var player = AudioPlayerController()
    @StateObject private var recorder = RecorderController()
    @StateObject private var transcriber = TranscriptionManager()

    var body: some Scene {
        WindowGroup("V2T") {
            MainWindow()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(player)
                .environmentObject(recorder)
                .environmentObject(transcriber)
                .frame(minWidth: 860, minHeight: 560)
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var recorder: RecorderController
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var player: AudioPlayerController
    /// Folder column starts hidden, like Voice Memos; the toolbar's sidebar
    /// button reveals it.
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var folderSelection: FolderSelection? = .all
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FolderSidebarView(selection: $folderSelection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 280)
        } content: {
            RecordingsListView(selection: $selection, folder: folderSelection ?? .all)
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 400)
        } detail: {
            if recorder.isRecording {
                RecordingSessionView()
            } else {
                DetailView(recordingID: selection)
            }
        }
        .onAppear {
            SpaceKeyPlaybackMonitor.install(player: player, recorder: recorder)
        }
        .onChange(of: folderSelection) { newValue in
            // Deselect a recording that isn't in the newly chosen folder.
            guard let selectedID = selection,
                  let recording = store.recording(with: selectedID) else { return }
            let stillVisible: Bool
            switch newValue ?? .all {
            case .all: stillVisible = true
            case .favorites: stillVisible = recording.isFavorite
            case .folder(let id): stillVisible = recording.folderID == id
            }
            if !stillVisible { selection = nil }
        }
    }
}

/// Ensures the app behaves like a regular foreground app even when launched
/// from the terminal via `swift run` (no bundle Info.plist).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
