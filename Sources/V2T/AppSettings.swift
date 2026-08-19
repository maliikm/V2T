import Foundation

/// User preferences. The fal API key lives in the Keychain; everything else
/// in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    @Published var apiKey: String
    @Published var tagAudioEvents: Bool {
        didSet { UserDefaults.standard.set(tagAudioEvents, forKey: "tagAudioEvents") }
    }
    @Published var languageCode: String {
        didSet { UserDefaults.standard.set(languageCode, forKey: "languageCode") }
    }
    /// Automatically transcribe new recordings and imports.
    @Published var autoTranscribe: Bool {
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: "autoTranscribe") }
    }
    /// Default expected speaker count for new recordings; 0 = auto-detect.
    @Published var defaultNumSpeakers: Int {
        didSet { UserDefaults.standard.set(defaultNumSpeakers, forKey: "defaultNumSpeakers") }
    }

    init() {
        let defaults = UserDefaults.standard
        apiKey = Keychain.loadAPIKey() ?? ""
        tagAudioEvents = defaults.bool(forKey: "tagAudioEvents")
        languageCode = defaults.string(forKey: "languageCode") ?? ""
        autoTranscribe = defaults.object(forKey: "autoTranscribe") as? Bool ?? true
        defaultNumSpeakers = defaults.integer(forKey: "defaultNumSpeakers")
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveAPIKey(_ key: String) {
        apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.saveAPIKey(apiKey)
    }
}
