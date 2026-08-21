import SwiftUI

/// Contents of the menu bar item: capture all system audio or a specific
/// app's audio via Core Audio process taps, optionally recording the
/// microphone alongside (mixed together on stop). Recordings land in the
/// V2T library and auto-transcribe like everything else.
struct MenuBarView: View {
    @EnvironmentObject var appAudio: AppAudioRecorder
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var transcriber: TranscriptionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if appAudio.isRecording {
                Text("Recording \(appAudio.targetName)\(appAudio.isPaused ? " (paused)" : "") — \(TranscriptFormatter.timestamp(appAudio.elapsed))")
                if appAudio.isPaused {
                    Button("Resume") { appAudio.resume() }
                } else {
                    Button("Pause") { appAudio.pause() }
                }
                Button("Stop Recording") {
                    appAudio.stop()
                }
            } else if appAudio.isSaving {
                Text("Saving recording…")
            } else {
                Button("Record System Audio") {
                    start(app: nil)
                }
                Menu("Record App Audio") {
                    if appAudio.availableApps.isEmpty {
                        Text("No apps playing audio found")
                    }
                    ForEach(appAudio.availableApps) { app in
                        Button {
                            start(app: app)
                        } label: {
                            if app.hasActiveOutput {
                                Label(app.name, systemImage: "speaker.wave.2.fill")
                            } else {
                                Text(app.name)
                            }
                        }
                    }
                    Divider()
                    Button("Refresh App List") {
                        Task { await appAudio.refreshApps() }
                    }
                }
                Toggle("Also Record My Microphone", isOn: $appAudio.recordMicToo)
                    .help("Records your mic as a second track and mixes it in — so meetings capture both sides")
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

    private func start(app: AudioProcess?) {
        appAudio.start(app: app, store: store, settings: settings, transcriber: transcriber)
    }
}
