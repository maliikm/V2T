import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var keyInput = ""
    @State private var saved = false
    @State private var keyError: String?

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                SecureField("\(settings.provider.name) API key", text: $keyInput,
                            prompt: Text(settings.provider == .fal ? "key_id:key_secret" : "Deepgram API key"))
                HStack {
                    Button(saved ? "Saved ✓" : "Save Key") {
                        do {
                            try settings.saveAPIKey(keyInput)
                            saved = true
                            keyError = nil
                        } catch { keyError = error.localizedDescription; saved = false }
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Get a key", destination: settings.provider.keyURL)
                }
                if let keyError { Text(keyError).foregroundStyle(.red) }
            } header: {
                Text("Transcription Provider")
            } footer: {
                Text("Each provider's key is stored separately in your macOS Keychain. Changing providers affects new requests, not existing transcripts or jobs already running.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Transcribe new recordings automatically", isOn: $settings.autoTranscribe)
                if settings.provider == .fal {
                    Picker("Default speaker count", selection: $settings.defaultNumSpeakers) {
                        Text("Auto-detect").tag(0)
                        ForEach(2...16, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    Toggle("Tag audio events (laughter, applause…)", isOn: $settings.tagAudioEvents)
                    TextField("Language code (optional)", text: $settings.languageCode, prompt: Text("auto-detect"))
                        .help("ISO code like \"eng\" or \"spa\". Leave empty to auto-detect.")
                } else {
                    TextField("Language code", text: $settings.deepgramLanguageCode, prompt: Text("en, es, multi, or empty for detection"))
                        .help("Use Deepgram language codes such as en or es. Use multi for supported multilingual conversations, or leave empty to detect the dominant language.")
                    Text("Speaker labels and smart formatting are enabled. Speaker-count hints and audio-event tags are fal-only settings; they are retained when you switch back.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Audio is uploaded directly to Deepgram for transcription. Model-improvement opt-out is always enabled; this may increase Deepgram's listed rates. Recording files remain on your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Deepgram privacy and pricing details", destination: URL(string: "https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded")!)
                }
            } header: {
                Text("Transcription")
            } footer: {
                Text("Re-transcribing uses the selected provider. The previous transcript and speaker names are archived locally before replacement.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Start/stop recording", value: "⌘⌥R")
                LabeledContent("Pause/resume recording", value: "⌘⌥P")
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Global shortcuts work in any app. Start/stop uses the same source and microphone choice as the main window and menu bar. An unavailable app must be reselected; it never falls back to all Mac audio.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .padding(.vertical, 8)
        .onAppear { keyInput = settings.apiKey }
        .onChange(of: settings.provider) { _, _ in
            keyInput = settings.apiKey
            saved = false
            keyError = nil
        }
        .onChange(of: keyInput) { _, _ in saved = false }
    }
}
