import SwiftUI

/// Full-pane view shown in the main window while an app-audio (tap)
/// capture is running — regardless of whether it was started from the
/// record bar, the menu bar, or the ⌘⌥R hotkey. Mirrors the microphone
/// recording screen: live scrolling waveform, overview strip, big counter,
/// pause / RESUME, and Stop.
struct AppAudioSessionView: View {
    @EnvironmentObject var appAudio: AppAudioRecorder

    var body: some View {
        if appAudio.isSaving {
            VStack(spacing: 12) {
                ProgressView()
                Text("Saving recording…")
                    .foregroundStyle(.secondary)
                if appAudio.sessionHasMic {
                    Text("Mixing the microphone track in")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                header

                LiveWaveformView(
                    levels: appAudio.levels,
                    elapsed: appAudio.elapsed,
                    isPaused: appAudio.isPaused
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                OverviewLevelsView(levels: appAudio.levels, isPaused: appAudio.isPaused)
                    .frame(height: 48)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                HStack {
                    Text("0:00")
                    Spacer()
                    Text(TranscriptFormatter.timestamp(appAudio.elapsed))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 4)

                Text(TranscriptFormatter.clock(appAudio.elapsed))
                    .font(.system(size: 40, weight: .bold).monospacedDigit())
                    .padding(.top, 10)

                if let error = appAudio.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 6)
                }

                bottomBar
            }
            .padding(.bottom, 16)
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text("Recording \(appAudio.targetName)")
                .font(.title3.weight(.bold))
            HStack(spacing: 8) {
                if appAudio.sessionHasMic {
                    Label("with microphone", systemImage: "mic.fill")
                }
                Text(TranscriptFormatter.timestamp(appAudio.elapsed)).monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 16)
        .padding(.horizontal, 24)
    }

    private var bottomBar: some View {
        HStack {
            if appAudio.isPaused {
                Button {
                    appAudio.resume()
                } label: {
                    Text("RESUME")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    appAudio.pause()
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Pause capture")
            }

            Spacer()

            Button("Stop") {
                appAudio.stop()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }
}
