import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var capture: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if capture.isBusy {
                VStack(alignment: .leading, spacing: 14) {
                    Text(capture.summary).font(.headline)
                    RecordingTransportView()
                }.padding(20).frame(width: 380)
            } else {
                RecordingSetupView()
            }
            if let error = capture.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 20).padding(.bottom, 12).frame(maxWidth: 380)
            }
            Divider()
            HStack {
                Button("Open V2T") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit V2T") { NSApp.terminate(nil) }.disabled(capture.isBusy)
            }.padding(16)
        }
    }
}
