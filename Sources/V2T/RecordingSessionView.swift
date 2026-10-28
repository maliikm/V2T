import SwiftUI

/// Recording is centered on readable text and a few persistent controls.
struct RecordingSessionView: View {
    @EnvironmentObject var recorder: RecorderController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(recorder.sessionTitle).font(.headline)
                    Text(recorder.isPaused ? "Paused" : "Recording microphone")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(TranscriptFormatter.recordingClock(recorder.elapsed)).font(.title2.monospacedDigit())
            }
            .padding(20)
            Divider()
            LiveTranscriptView(transcriber: recorder.liveTranscript)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button(recorder.isPaused ? "Resume" : "Pause") {
                    recorder.isPaused ? recorder.resume() : recorder.pause()
                }
                Spacer()
                Button("Stop Recording") { recorder.stop() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .controlSize(.large)
            .padding(16)
        }
    }
}
