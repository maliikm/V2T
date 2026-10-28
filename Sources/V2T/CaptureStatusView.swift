import SwiftUI

/// One status surface per window, independent of which recording is selected.
struct CaptureStatusView: View {
    @EnvironmentObject var capture: RecordingCoordinator
    var recordingWarning: String? = nil

    private var notice: CaptureNotice? {
        if let error = capture.error, error != recordingWarning {
            return CaptureNotice(message: error, severity: .error)
        }
        return capture.appAudio.captureNotice
    }

    var body: some View {
        if let notice {
            Label(notice.message, systemImage: notice.severity == .error ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.callout)
                .foregroundStyle(notice.severity == .error ? Color.red : Color.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.bar)
        }
    }
}
