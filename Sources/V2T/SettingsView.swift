import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: TranscriptionModel
    @State private var keyInput = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                SecureField("fal.ai API key", text: $keyInput, prompt: Text("key_id:key_secret"))
                HStack {
                    Button(saved ? "Saved ✓" : "Save Key") {
                        model.saveAPIKey(keyInput)
                        saved = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            saved = false
                        }
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Get a key", destination: URL(string: "https://fal.ai/dashboard/keys")!)
                }
            } header: {
                Text("fal.ai")
            } footer: {
                Text("Stored securely in your macOS Keychain.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Default speaker count", selection: $model.numSpeakers) {
                    Text("Auto-detect").tag(0)
                    ForEach(2...16, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                Toggle("Tag audio events (laughter, applause…)", isOn: $model.tagAudioEvents)
                TextField("Language code (optional)", text: $model.languageCode, prompt: Text("auto-detect"))
                    .help("ISO code like \"eng\" or \"spa\". Leave empty to auto-detect.")
            } header: {
                Text("Transcription")
            } footer: {
                Text("Setting the real number of speakers markedly improves who-said-what accuracy.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
        .onAppear { keyInput = model.apiKey }
    }
}
