import Foundation
import Testing
@testable import V2T

@MainActor
struct RecordingCoordinatorTests {
    @Test func sharedStartAndShortcutToggleCannotOverlapPermissionRequests() async throws {
        let name = "V2TTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let settings = AppSettings(defaults: defaults, loadAPIKey: { nil }, loadDeepgramAPIKey: { nil })
        let recorder = RecorderController()
        let appAudio = AppAudioRecorder()
        var requests = 0
        let coordinator = RecordingCoordinator(store: store, settings: settings, recorder: recorder,
            appAudio: appAudio, transcriber: TranscriptionManager(), defaults: defaults,
            requestMicrophoneAccess: { requests += 1; return false })
        // Setup's Start and the transport/global-hotkey toggle share the guard.
        coordinator.start()
        #expect(coordinator.isBusy)
        coordinator.toggleRecording()
        coordinator.start()
        coordinator.togglePause()
        let app = AudioProcess(id: "unavailable", name: "Other", bundleID: nil, objectIDs: [], pids: [], hasActiveOutput: false)
        coordinator.choose(app)
        #expect(coordinator.configuration.appID == nil)
        // Let the permission task run; this injected denial never opens hardware.
        for _ in 0..<10 { await Task.yield() }
        #expect(requests == 1)
        #expect(!coordinator.isBusy)
        #expect(!recorder.isRecording && !appAudio.isRecording)
        #expect(coordinator.error?.contains("Microphone access is off") == true)
        #expect(store.recordings.isEmpty)
        coordinator.choose(app)
        #expect(RecordingConfiguration.load(from: defaults).appID == app.id)
    }
}
