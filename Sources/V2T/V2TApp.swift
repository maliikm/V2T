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
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            if recorder.isRecording {
                RecordingSessionView()
            } else {
                DetailView(recordingID: selection)
            }
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
