import SwiftUI

struct AppAudioSessionView: View {
    @EnvironmentObject var appAudio: AppAudioRecorder

    var body: some View {
        if appAudio.isSaving {
            VStack(spacing: 12) {
                ProgressView()
                Text("Saving recording…").font(.headline)
                Text("You can keep browsing your library.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: appAudio.isPaused ? "pause.circle.fill" : "record.circle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appAudio.targetName).font(.headline)
                        Text(appAudio.isPaused ? "Paused" : "Recording call audio")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(TranscriptFormatter.recordingClock(appAudio.elapsed)).font(.title2.monospacedDigit())
                }
                .padding(20)
                Divider()
                LiveTranscriptView(transcriber: appAudio.liveTranscript)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        MicrophoneCaptureButton()
                        Button(appAudio.isPaused ? "Resume" : "Pause") {
                            appAudio.isPaused ? appAudio.resume() : appAudio.pause()
                        }
                        Spacer()
                        Button("Stop Recording") { appAudio.stop() }
                            .buttonStyle(.borderedProminent).tint(.red)
                    }
                    .controlSize(.large)
                    Text("Mic controls this recording only. Use headphones or turn it on only when speaking to avoid speaker bleed.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = appAudio.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
        }
    }
}
