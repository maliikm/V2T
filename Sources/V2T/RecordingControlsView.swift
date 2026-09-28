import SwiftUI
import AppKit

struct RecordingControlsView: View {
    @EnvironmentObject var capture: RecordingCoordinator
    @State private var showingSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { showingSetup.toggle() } label: {
                HStack {
                    Image(systemName: capture.configuration.source.icon)
                    Text(capture.summary).lineLimit(2)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).disabled(capture.isBusy).help("Choose what to record")
            .popover(isPresented: $showingSetup, arrowEdge: .top) {
                RecordingSetupView { showingSetup = false }.environmentObject(capture)
            }
            RecordingTransportView()
            if let error = capture.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }.padding(14).background(.bar)
    }
}

struct RecordingTransportView: View {
    @EnvironmentObject var capture: RecordingCoordinator
    var body: some View {
        HStack {
            if capture.isRecording {
                Button { capture.togglePause() } label: {
                    Image(systemName: capture.isPaused ? "play.fill" : "pause.fill")
                }.accessibilityLabel(capture.isPaused ? "Resume recording" : "Pause recording")
                Text(TranscriptFormatter.clock(capture.elapsed)).monospacedDigit()
                Spacer()
            }
            Button { capture.toggleRecording() } label: {
                Label(capture.isRecording ? "Stop Recording" : capture.isSaving ? "Saving…" : capture.isBusy ? "Starting…" : "Record",
                      systemImage: capture.isRecording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .disabled(capture.isBusy && !capture.isRecording)
            .help("Start or stop recording (⌘⌥R)")
        }.controlSize(.large)
    }
}

/// Shared native setup surface for the library popover and menu-bar window.
struct RecordingSetupView: View {
    @EnvironmentObject var capture: RecordingCoordinator
    @State private var search = ""
    var onStart: () -> Void = {}

    private var apps: [AudioProcess] {
        capture.appAudio.availableApps
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }
    private var selectionAvailable: Bool {
        capture.configuration.source != .application ||
        capture.appAudio.availableApps.contains { $0.id == capture.configuration.appID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What would you like to record?").font(.headline)
                Text("Your choice also applies to ⌘⌥R.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(RecordingSource.allCases) { source in sourceButton(source) }
            }
            if capture.configuration.source == .application {
                applicationList
            } else {
                Text(capture.configuration.source == .system
                     ? "Captures sound from every application, including notification sounds."
                     : "Record your voice using the Mac’s selected input device.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if capture.configuration.source != .microphone {
                Toggle(isOn: $capture.configuration.includesMicrophone) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Include my microphone")
                        Text("Capture your side of the conversation, too.").font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch)
            }
            if capture.configuration.usesMicrophone {
                LabeledContent("Microphone input", value: "System default").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Label(capture.summary, systemImage: capture.configuration.source.icon).font(.callout.weight(.medium)).lineLimit(2)
            Button { onStart(); capture.start() } label: {
                Label("Start Recording", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            .disabled(!selectionAvailable || capture.isBusy ||
                      (capture.configuration.source != .microphone && !AppAudioRecorder.isSupported))
            if !AppAudioRecorder.isSupported {
                Text("Application and Mac audio require macOS 14.4 or later.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20).frame(width: 380).disabled(capture.isBusy)
        .task { if AppAudioRecorder.isSupported { await capture.appAudio.refreshApps() } }
    }

    private func sourceButton(_ source: RecordingSource) -> some View {
        let selected = capture.configuration.source == source
        return Button { capture.configuration.source = source } label: {
            VStack(spacing: 8) {
                Image(systemName: source.icon).font(.title2)
                Text(source.title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
        .disabled(source != .microphone && !AppAudioRecorder.isSupported)
    }

    private var applicationList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search applications", text: $search).textFieldStyle(.roundedBorder)
                Button { Task { await capture.appAudio.refreshApps() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh applications").accessibilityLabel("Refresh applications")
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(apps) { app in
                        Button { capture.choose(app) } label: {
                            HStack(spacing: 10) {
                                appIcon(app).frame(width: 28, height: 28)
                                Text(app.name).lineLimit(1)
                                Spacer(minLength: 4)
                                if app.hasActiveOutput {
                                    Text("Audio active").font(.caption2).foregroundStyle(.secondary)
                                }
                                Image(systemName: capture.configuration.appID == app.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(capture.configuration.appID == app.id ? Color.accentColor : Color.secondary)
                            }
                            .padding(8)
                            .background(capture.configuration.appID == app.id ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(capture.configuration.appID == app.id ? [.isSelected] : [])
                    }
                    if apps.isEmpty {
                        Text(search.isEmpty ? "Open an application and play audio to make it available here." : "No matching applications.")
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
            }.frame(height: 168)
            if !selectionAvailable {
                Text(capture.configuration.appName.map { "\($0) is unavailable. Open it or select another app." } ?? "Select an application to continue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("All audio from the selected app is included—not just one tab or meeting.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func appIcon(_ app: AudioProcess) -> some View {
        if let bundleID = app.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        } else {
            Image(systemName: "app.fill").font(.title2).foregroundStyle(.secondary)
        }
    }
}

struct LibraryStatusView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var capture: RecordingCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = store.lastError {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button { store.lastError = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss storage error")
                }
            }
            if !store.recoveryDirectories.isEmpty {
                HStack {
                    Text("\(store.recoveryDirectories.count) unfinished capture(s) kept in Recovery.")
                    Spacer()
                    Button("Show Files") { NSWorkspace.shared.open(store.recoveryRootURL) }
                    Button("Retry Save") { capture.retrySaves() }.disabled(capture.isBusy)
                }
            }
        }
        .font(.callout).padding(store.lastError != nil || !store.recoveryDirectories.isEmpty ? 12 : 0).background(.bar)
    }
}
