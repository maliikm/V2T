import Foundation

enum RecordingSource: String, Codable, CaseIterable, Identifiable {
    case microphone, application, system

    var id: String { rawValue }
    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .application: return "Application"
        case .system: return "All Mac Audio"
        }
    }
    var icon: String {
        switch self {
        case .microphone: return "mic.fill"
        case .application: return "app.dashed"
        case .system: return "speaker.wave.2.fill"
        }
    }
}

/// One selection shared by the window, menu bar and global shortcuts.
struct RecordingConfiguration: Codable, Equatable {
    var source: RecordingSource = .microphone
    var includesMicrophone = true
    var appID: String?
    var appName: String?

    var usesMicrophone: Bool { source == .microphone || includesMicrophone }

    func target(in apps: [AudioProcess]) throws -> AudioProcess? {
        guard source == .application else { return nil }
        guard let appID, let app = apps.first(where: { $0.id == appID }) else {
            throw SelectionError.unavailable(appName)
        }
        return app
    }

    enum SelectionError: LocalizedError {
        case unavailable(String?)
        var errorDescription: String? {
            switch self {
            case .unavailable(let name):
                return name.map { "\($0) is unavailable. Open it or choose another application before recording." }
                    ?? "Choose an application before recording."
            }
        }
    }

    static func load(from defaults: UserDefaults) -> Self {
        if let data = defaults.data(forKey: "recordingConfiguration"),
           let saved = try? JSONDecoder().decode(Self.self, from: data) { return saved }
        // Migrate the former window picker once, preserving its mic intent.
        let legacy = defaults.string(forKey: "recordSource") ?? "mic"
        let appID = defaults.string(forKey: "appAudioLastTarget")
        return Self(
            source: legacy == "systemMic" ? .system : (["appAudio", "appAudioMic"].contains(legacy) ? .application : .microphone),
            includesMicrophone: legacy != "appAudio",
            appID: appID?.isEmpty == false ? appID : nil
        )
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: "recordingConfiguration")
        }
    }
}
