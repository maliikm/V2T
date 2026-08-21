import AppKit
import CoreAudio
import Foundation
import os.log

/// A user-facing app that owns one or more Core Audio process objects.
/// Multi-process apps (Chrome, Zoom, Safari) render audio in helper
/// processes; those are grouped under the app the user recognizes.
/// (Ported from DesktopAudio.)
struct AudioProcess: Identifiable, Hashable {
    /// Grouping key: the owning app's bundle ID when known, else "pid:<pid>".
    let id: String
    let name: String
    let bundleID: String?
    /// All Core Audio process objects belonging to this app right now.
    let objectIDs: [AudioObjectID]
    let pids: [pid_t]
    /// True if any process object has registered output IO
    /// (a hint that the app is playing audio, not a guarantee).
    let hasActiveOutput: Bool

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.id == rhs.id && lhs.objectIDs == rhs.objectIDs && lhs.hasActiveOutput == rhs.hasActiveOutput
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Enumerates Core Audio process objects and groups them by owning app,
/// so Chrome's N helper processes show up as one "Google Chrome" entry.
/// (Ported from DesktopAudio; Observation replaced with a change closure.)
@available(macOS 14.4, *)
@MainActor
final class AudioProcessController {
    private static let logger = Logger(subsystem: kV2TSubsystem, category: "AudioProcessController")

    private(set) var processes: [AudioProcess] = []

    /// Called after every reload (helper processes spawning/dying, apps
    /// starting/stopping playback) with the fresh process list.
    var onProcessesChanged: (() -> Void)?

    private var listener: AudioPropertyListener?
    /// Per-process listeners so the "playing" badge reacts when an app
    /// starts/stops rendering audio, not just when processes spawn/die.
    private var outputListeners: [AudioPropertyListener] = []
    private var reloadPending = false

    func activate() {
        guard listener == nil else {
            reload()
            return
        }
        do {
            listener = try AudioPropertyListener(
                objectID: .system,
                selector: kAudioHardwarePropertyProcessObjectList
            ) { [weak self] in
                Task { @MainActor in self?.scheduleReload() }
            }
        } catch {
            Self.logger.error("Failed to install process list listener: \(String(describing: error), privacy: .public)")
        }
        reload()
    }

    /// Coalesces listener storms into one reload per run-loop turn.
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        Task { @MainActor in
            self.reloadPending = false
            self.reload()
        }
    }

    func reload() {
        do {
            let objectIDs = try AudioObjectID.system.readObjectList(kAudioHardwarePropertyProcessObjectList)
            let entries = objectIDs.compactMap { Self.readEntry($0) }
            processes = Self.group(entries)
            watchOutputState(of: objectIDs)
            onProcessesChanged?()
        } catch {
            Self.logger.error("Process enumeration failed: \(String(describing: error), privacy: .public)")
            processes = []
        }
    }

    private func watchOutputState(of objectIDs: [AudioObjectID]) {
        outputListeners = objectIDs.compactMap { objectID in
            try? AudioPropertyListener(
                objectID: objectID,
                selector: kAudioProcessPropertyIsRunningOutput
            ) { [weak self] in
                Task { @MainActor in self?.scheduleReload() }
            }
        }
    }

    // MARK: - Enumeration

    private struct ProcessEntry {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    private static func readEntry(_ objectID: AudioObjectID) -> ProcessEntry? {
        guard let pid = try? objectID.read(kAudioProcessPropertyPID, defaultValue: pid_t(-1)) else {
            return nil
        }
        let bundleID = (try? objectID.readString(kAudioProcessPropertyBundleID)) ?? ""
        let isRunningOutput = ((try? objectID.read(kAudioProcessPropertyIsRunningOutput, defaultValue: UInt32(0))) ?? 0) != 0
        return ProcessEntry(objectID: objectID, pid: pid, bundleID: bundleID, isRunningOutput: isRunningOutput)
    }

    // MARK: - Grouping

    private struct Owner: Hashable {
        let key: String
        let name: String
        let bundleID: String?
    }

    private static func group(_ entries: [ProcessEntry]) -> [AudioProcess] {
        let runningApps = NSWorkspace.shared.runningApplications
        let ownBundleID = Bundle.main.bundleIdentifier

        var groups: [Owner: [ProcessEntry]] = [:]
        for entry in entries {
            guard let owner = resolveOwner(for: entry, runningApps: runningApps) else { continue }
            guard owner.bundleID != ownBundleID else { continue } // never list ourselves
            groups[owner, default: []].append(entry)
        }

        return groups
            .map { owner, members in
                AudioProcess(
                    id: owner.key,
                    name: owner.name,
                    bundleID: owner.bundleID,
                    objectIDs: members.map(\.objectID),
                    pids: members.map(\.pid),
                    hasActiveOutput: members.contains(where: \.isRunningOutput)
                )
            }
            .sorted {
                if $0.hasActiveOutput != $1.hasActiveOutput { return $0.hasActiveOutput }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// Maps a (possibly helper) audio process to the user-visible app that
    /// owns it, or nil for system daemons the user wouldn't recognize.
    private static func resolveOwner(
        for entry: ProcessEntry,
        runningApps: [NSRunningApplication]
    ) -> Owner? {
        let visibleApps = runningApps.filter { $0.activationPolicy == .regular }

        func owner(for app: NSRunningApplication) -> Owner? {
            guard let bundle = app.bundleIdentifier else { return nil }
            return Owner(key: bundle, name: app.localizedName ?? bundle, bundleID: bundle)
        }

        if !entry.bundleID.isEmpty {
            if let app = visibleApps.first(where: { $0.bundleIdentifier == entry.bundleID }) {
                return owner(for: app)
            }
            // Helper bundle IDs extend the parent app's bundle ID
            // (com.google.Chrome.helper → com.google.Chrome). Longest prefix wins.
            let parent = visibleApps
                .filter { app in
                    guard let appBundle = app.bundleIdentifier else { return false }
                    return entry.bundleID.lowercased().hasPrefix(appBundle.lowercased() + ".")
                }
                .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            if let parent {
                return owner(for: parent)
            }
            // WebKit helpers render Safari's audio but live under
            // com.apple.WebKit.* — attribute them to Safari when it's running.
            if entry.bundleID.hasPrefix("com.apple.WebKit"),
               let safari = visibleApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
                return owner(for: safari)
            }
        }

        if let app = NSRunningApplication(processIdentifier: entry.pid),
           app.activationPolicy == .regular {
            return owner(for: app) ?? Owner(key: "pid:\(entry.pid)", name: app.localizedName ?? "PID \(entry.pid)", bundleID: nil)
        }

        return nil
    }
}
