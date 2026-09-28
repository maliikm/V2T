import Foundation

/// Stored beside finished capture files before attempting to install them in
/// the library. Relative names let a failed save be retried after relaunch.
struct CaptureDraft: Codable {
    let recording: Recording
    let audioFileName: String
    /// Library filename -> captured filename.
    let tracks: [String: String]

    static let manifestName = "capture.json"
}
