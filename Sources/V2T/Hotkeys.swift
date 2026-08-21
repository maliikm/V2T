import Carbon.HIToolbox
import Foundation

/// Global hotkeys for the menu bar recorder, via Carbon's
/// RegisterEventHotKey — system-wide, no Accessibility permission, and no
/// package dependency (the KeyboardShortcuts package can't build with
/// Command Line Tools alone because its source contains #Preview macros).
///
/// - ⌘⌥R: start app-audio recording (last-used target, else System Audio)
///   or stop the current one.
/// - ⌘⌥P: pause/resume the current recording.
@MainActor
enum AppAudioHotkeys {
    private static var installed = false
    private static var hotKeyRefs: [EventHotKeyRef?] = []
    private static var eventHandler: EventHandlerRef?
    /// Hotkey id → action, looked up by the Carbon callback.
    private static var actions: [UInt32: () -> Void] = [:]

    private static let toggleRecordingID: UInt32 = 1
    private static let togglePauseID: UInt32 = 2

    static func install(
        appAudio: AppAudioRecorder,
        store: LibraryStore,
        settings: AppSettings,
        transcriber: TranscriptionManager
    ) {
        guard !installed else { return }
        installed = true

        actions[toggleRecordingID] = {
            appAudio.toggleFromHotkey(store: store, settings: settings, transcriber: transcriber)
        }
        actions[togglePauseID] = {
            if appAudio.isPaused {
                appAudio.resume()
            } else if appAudio.isRecording {
                appAudio.pause()
            }
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Non-capturing closure → C function pointer; hotkey events are
        // delivered on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard err == noErr else { return err }
            let id = hotKeyID.id
            Task { @MainActor in
                AppAudioHotkeys.actions[id]?()
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)

        register(keyCode: UInt32(kVK_ANSI_R), id: toggleRecordingID)
        register(keyCode: UInt32(kVK_ANSI_P), id: togglePauseID)
    }

    private static func register(keyCode: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5632_5448) /* "V2TH" */, id: id)
        let modifiers = UInt32(cmdKey | optionKey)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
    }
}
