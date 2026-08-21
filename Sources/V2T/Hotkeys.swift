import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Starts app-audio recording (last-used target, else System Audio),
    /// or stops the current one.
    static let toggleAppAudioRecording = Self(
        "toggleAppAudioRecording",
        default: .init(.r, modifiers: [.command, .option])
    )
    /// Pauses/resumes the current app-audio recording.
    static let togglePauseAppAudio = Self(
        "togglePauseAppAudio",
        default: .init(.p, modifiers: [.command, .option])
    )
}

/// Global hotkeys for the menu bar recorder (⌘⌥R / ⌘⌥P by default,
/// rebindable in Settings). Work system-wide, even with V2T in the
/// background or its window closed.
@MainActor
enum AppAudioHotkeys {
    private static var installed = false

    static func install(
        appAudio: AppAudioRecorder,
        store: LibraryStore,
        settings: AppSettings,
        transcriber: TranscriptionManager
    ) {
        guard !installed else { return }
        installed = true

        KeyboardShortcuts.onKeyUp(for: .toggleAppAudioRecording) {
            appAudio.toggleFromHotkey(store: store, settings: settings, transcriber: transcriber)
        }
        KeyboardShortcuts.onKeyUp(for: .togglePauseAppAudio) {
            if appAudio.isPaused {
                appAudio.resume()
            } else if appAudio.isRecording {
                appAudio.pause()
            }
        }
    }
}
