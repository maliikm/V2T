import SwiftUI

/// Keeps the running capture reachable while the detail pane shows a saved recording.
struct ActiveRecordingBar: View {
    @EnvironmentObject var capture: RecordingCoordinator
    @EnvironmentObject var recorder: RecorderController
    @EnvironmentObject var appAudio: AppAudioRecorder
    let showRecording: () -> Void

    private var isPaused: Bool { recorder.isRecording ? recorder.isPaused : appAudio.isPaused }
    private var elapsed: Double { recorder.isRecording ? recorder.elapsed : appAudio.elapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if capture.isSaving {
                    ProgressView().controlSize(.small)
                    Text("Saving recording…")
                } else {
                    Image(systemName: isPaused ? "pause.circle.fill" : "record.circle.fill")
                        .foregroundStyle(.red)
                    Text(isPaused ? "Recording paused" : "Recording")
                        .fontWeight(.semibold)
                    Text(TranscriptFormatter.timestamp(elapsed)).monospacedDigit()
                }
                Spacer()
                Button("Show Recording", action: showRecording)
            }
            if capture.isRecording {
                HStack {
                    if appAudio.isRecording {
                        MicrophoneCaptureButton()
                    }
                    Spacer()
                    Button(isPaused ? "Resume" : "Pause") {
                        capture.togglePause()
                    }
                    Button("Stop", role: .destructive) {
                        capture.toggleRecording()
                    }
                }
            }
            if let error = capture.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.bar)
    }
}

struct MicrophoneCaptureButton: View {
    @EnvironmentObject var appAudio: AppAudioRecorder

    var body: some View {
        Button {
            appAudio.toggleMicrophone()
        } label: {
            Label(
                appAudio.isChangingMicrophone ? "Enabling mic…" : (appAudio.isMicEnabled ? "Mic on" : "Mic off"),
                systemImage: appAudio.isMicEnabled ? "mic.fill" : "mic.slash.fill"
            )
        }
        .disabled(appAudio.isChangingMicrophone || !appAudio.isRecording)
        .accessibilityLabel(appAudio.isMicEnabled ? "Turn off microphone recording" : "Turn on microphone recording")
        .help("Include your mic in V2T only; your call's mute setting is unchanged. Toggle with ⌘⌥M.")
    }
}
