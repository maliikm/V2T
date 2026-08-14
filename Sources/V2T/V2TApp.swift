import SwiftUI

@main
struct V2TApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = TranscriptionModel()

    var body: some Scene {
        WindowGroup("V2T — Voice to Text") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 520)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

/// Ensures the app behaves like a regular foreground app even when launched
/// from the terminal via `swift run` (no bundle Info.plist).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
