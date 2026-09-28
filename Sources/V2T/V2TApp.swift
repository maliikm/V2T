import SwiftUI

@main
struct V2TApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store: LibraryStore
    @StateObject private var settings: AppSettings
    @StateObject private var player = AudioPlayerController()
    @StateObject private var recorder: RecorderController
    @StateObject private var transcriber: TranscriptionManager
    @StateObject private var appAudio: AppAudioRecorder
    @StateObject private var capture: RecordingCoordinator

    init() {
        let store = LibraryStore()
        let settings = AppSettings()
        let recorder = RecorderController()
        let appAudio = AppAudioRecorder()
        let transcriber = TranscriptionManager()
        _store = StateObject(wrappedValue: store)
        _settings = StateObject(wrappedValue: settings)
        _recorder = StateObject(wrappedValue: recorder)
        _appAudio = StateObject(wrappedValue: appAudio)
        _transcriber = StateObject(wrappedValue: transcriber)
        _capture = StateObject(wrappedValue: RecordingCoordinator(
            store: store, settings: settings, recorder: recorder,
            appAudio: appAudio, transcriber: transcriber))
    }

    var body: some Scene {
        WindowGroup("V2T", id: "main") {
            MainWindow()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(player)
                .environmentObject(recorder)
                .environmentObject(transcriber)
                .environmentObject(appAudio)
                .environmentObject(capture)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { appDelegate.capture = capture }
        }

        MenuBarExtra("V2T", systemImage: capture.isRecording ? "record.circle.fill" : "waveform.circle") {
            MenuBarView()
                .environmentObject(capture)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var capture: RecordingCoordinator
    @EnvironmentObject var recorder: RecorderController
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var player: AudioPlayerController
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var transcriber: TranscriptionManager
    @EnvironmentObject var appAudio: AppAudioRecorder
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
            } else if appAudio.isRecording || appAudio.isSaving {
                AppAudioSessionView()
            } else if recorder.isSaving {
                ProgressView("Saving recording…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DetailView(recordingID: selection)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { LibraryStatusView() }
        .onAppear {
            SpaceKeyPlaybackMonitor.install(player: player, recorder: recorder)
            AppAudioHotkeys.install(coordinator: capture)
        }
        .onChange(of: folderSelection) { _, newValue in
            if case .folder(let id) = newValue { capture.selectedFolderID = id }
            else { capture.selectedFolderID = nil }
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
        .onChange(of: store.lastSavedRecordingID, initial: true) { _, id in
            guard let recording = store.recording(with: id) else { return }
            folderSelection = recording.folderID.map(FolderSelection.folder) ?? .all
            selection = recording.id
        }
    }
}

/// Ensures the app behaves like a regular foreground app even when launched
/// from the terminal via `swift run` (no bundle Info.plist).
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var capture: RecordingCoordinator?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard capture?.isBusy == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A recording is still in progress"
        alert.informativeText = "Stop recording and wait for it to finish saving before quitting V2T."
        alert.addButton(withTitle: "Keep V2T Open")
        alert.runModal()
        return .terminateCancel
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The menu bar item keeps working with the window closed.
        false
    }
}
