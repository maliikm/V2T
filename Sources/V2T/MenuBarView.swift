import SwiftUI

/// Contents of the menu bar item: capture all system audio or a specific
/// app's audio, desktop-audio style. Recordings land in the V2T library
/// and auto-transcribe like everything else.
struct MenuBarView: View {
    @EnvironmentObject var appAudio: AppAudioRecorder
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var transcriber: TranscriptionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if appAudio.isRecording {
                Text("Recording \(appAudio.targetName) — \(TranscriptFormatter.timestamp(appAudio.elapsed))")
                Button("Stop Recording") {
                    appAudio.stop()
                }
            } else {
                Button("Record System Audio") {
                    start(app: nil)
                }
                Menu("Record App Audio") {
                    if appAudio.availableApps.isEmpty {
                        Text("No apps with windows found")
                    }
                    ForEach(appAudio.availableApps) { app in
                        Button(app.name) {
                            start(app: app)
                        }
                    }
                    Divider()
                    Button("Refresh App List") {
                        Task { await appAudio.refreshApps() }
                    }
                }
            }

            if let error = appAudio.lastError {
                Divider()
                Text(error)
            }

            Divider()
            Button("Open V2T") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit V2T") {
                NSApp.terminate(nil)
            }
        }
        .onAppear {
            Task { await appAudio.refreshApps() }
        }
    }

    private func start(app: AppAudioRecorder.CapturableApp?) {
        appAudio.start(app: app, store: store, settings: settings, transcriber: transcriber)
    }
}
