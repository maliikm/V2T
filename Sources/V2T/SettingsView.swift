import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var calendar: CalendarConnection
    @EnvironmentObject var titleService: RecordingTitleService
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
                Text("Final Transcript Service")
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
                Toggle("Show live transcripts while recording", isOn: $settings.liveTranscriptionEnabled)
                LabeledContent("Live service", value: "Deepgram · Nova-3")
                TextField("Live language code", text: $settings.deepgramLanguageCode, prompt: Text("en or multi"))
                    .help("Use a supported Deepgram language code. Empty uses multilingual recognition. This language also applies to Deepgram final transcripts.")
                if settings.deepgramAPIKey.isEmpty {
                    Text("Select Deepgram above and save its API key to enable live transcripts.")
                        .foregroundStyle(.secondary)
                }
                Button("Open Live Transcript Log") { NSWorkspace.shared.open(LiveDiagnostics.url.deletingLastPathComponent()) }
            } header: {
                Text("Live Transcripts")
            } footer: {
                Text("Streams audio directly to Deepgram using your saved Deepgram key. Live transcription has its own usage charges; model-improvement opt-out is enabled. The preview is saved separately, and your selected final service still processes the completed recording.")
            }

            Section {
                Toggle("Automatically title new recordings", isOn: $settings.autoTitle)
                Text(RecordingTitleService.modelStatus).font(.caption).foregroundStyle(.secondary)
                if titleService.status != "Titles are generated on this Mac." {
                    Text(titleService.status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Local AI Titles")
            } footer: {
                Text("Uses recording time, selected calendars, and transcript content. Titles can improve when the final transcript arrives. Renaming a recording yourself keeps that title.")
            }

            Section {
                if calendar.isConnected {
                    Label("Apple Calendar connected", systemImage: "checkmark.circle.fill")
                    ForEach(calendar.calendars) { item in
                        Toggle(isOn: Binding(
                            get: { calendar.selectedCalendarIDs.contains(item.id) },
                            set: { selected in
                                if selected { calendar.selectedCalendarIDs.insert(item.id) }
                                else { calendar.selectedCalendarIDs.remove(item.id) }
                            }
                        )) {
                            VStack(alignment: .leading) {
                                Text(item.title)
                                Text(item.account).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Button("Refresh Calendars") { calendar.refreshCalendars() }
                        Button("Disconnect") { calendar.disconnect() }
                    }
                } else {
                    Button(calendar.isConnecting ? "Waiting for Calendar Access…" : "Connect Apple Calendar…") {
                        Task { await calendar.connect() }
                    }.disabled(calendar.isConnecting)
                    Text("Add your Google account in Apple Calendar → Add Account, then connect here.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Apple Calendar") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                if let error = calendar.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            } header: {
                Text("Calendars")
            } footer: {
                Text("Uses calendars already synced on this Mac, including Google and Outlook. macOS calls the required permission Full Access; V2T only reads events and never changes them. Event titles stay on your Mac for local title suggestions.")
            }

            Section {
                LabeledContent("Start/stop recording", value: "⌘⌥R")
                LabeledContent("Pause/resume recording", value: "⌘⌥P")
                LabeledContent("Mic on/off during app-audio recording", value: "⌘⌥M")
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Global shortcuts work in any app. Start/stop uses the same source and microphone choice as the main window and menu bar. An unavailable app must be reselected; it never falls back to all Mac audio.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 740)
        .padding(.vertical, 8)
        .onAppear { keyInput = settings.apiKey }
        .onChange(of: settings.provider) { _, _ in
            keyInput = settings.apiKey
            saved = false
            keyError = nil
        }
        .onChange(of: keyInput) { _, _ in saved = false }
        .task { calendar.refreshCalendars() }
    }
}
