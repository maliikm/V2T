import Foundation

/// User preferences. Provider API keys live in Keychain; everything else
/// in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    private let persistKey: (String, TranscriptionProvider) throws -> Void
    @Published private(set) var falAPIKey: String
    @Published private(set) var deepgramAPIKey: String
    @Published var provider: TranscriptionProvider {
        didSet { defaults.set(provider.rawValue, forKey: "transcriptionProvider") }
    }
    @Published var deepgramLanguageCode: String {
        didSet { defaults.set(deepgramLanguageCode, forKey: "deepgramLanguageCode") }
    }
    @Published var tagAudioEvents: Bool {
        didSet { defaults.set(tagAudioEvents, forKey: "tagAudioEvents") }
    }
    @Published var languageCode: String {
        didSet { defaults.set(languageCode, forKey: "languageCode") }
    }
    /// Automatically transcribe new recordings and imports.
    @Published var autoTranscribe: Bool {
        didSet { defaults.set(autoTranscribe, forKey: "autoTranscribe") }
    }
    /// Default expected speaker count for new recordings; 0 = auto-detect.
    @Published var defaultNumSpeakers: Int {
        didSet { defaults.set(defaultNumSpeakers, forKey: "defaultNumSpeakers") }
    }

    init(defaults: UserDefaults = .standard,
         loadAPIKey: () -> String? = { Keychain.loadAPIKey(for: .fal) },
         loadDeepgramAPIKey: () -> String? = { Keychain.loadAPIKey(for: .deepgram) },
         persistKey: @escaping (String, TranscriptionProvider) throws -> Void = { try Keychain.saveAPIKey($0, for: $1) }) {
        self.defaults = defaults
        self.persistKey = persistKey
        falAPIKey = loadAPIKey() ?? ""
        deepgramAPIKey = loadDeepgramAPIKey() ?? ""
        provider = TranscriptionProvider(rawValue: defaults.string(forKey: "transcriptionProvider") ?? "") ?? .fal
        deepgramLanguageCode = defaults.string(forKey: "deepgramLanguageCode") ?? "en"
        tagAudioEvents = defaults.bool(forKey: "tagAudioEvents")
        languageCode = defaults.string(forKey: "languageCode") ?? ""
        autoTranscribe = defaults.object(forKey: "autoTranscribe") as? Bool ?? true
        defaultNumSpeakers = defaults.integer(forKey: "defaultNumSpeakers")
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var apiKey: String { provider == .fal ? falAPIKey : deepgramAPIKey }
    var selectedLanguageCode: String {
        (provider == .fal ? languageCode : deepgramLanguageCode).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try persistKey(trimmed, provider)
        if provider == .fal { falAPIKey = trimmed } else { deepgramAPIKey = trimmed }
    }
}
