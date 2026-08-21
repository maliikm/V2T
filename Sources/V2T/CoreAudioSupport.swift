import CoreAudio
import Foundation
import os.log

// Core Audio plumbing for app-audio capture, ported from DesktopAudio.

let kV2TSubsystem = "com.wielventures.v2t"

enum CoreAudioError: LocalizedError {
    case osStatus(OSStatus, String)

    var errorDescription: String? {
        if case .osStatus(let status, let context) = self {
            return "\(context) failed (OSStatus \(status))"
        }
        return nil
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a fixed-size property value.
    func read<T>(_ selector: AudioObjectPropertySelector, defaultValue: T) throws -> T {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard err == noErr else {
            throw CoreAudioError.osStatus(err, "read \(selector.fourCharString) on #\(self)")
        }
        return value
    }

    /// Reads a CFString property (e.g. bundle ID, device UID).
    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else {
            throw CoreAudioError.osStatus(err, "readString \(selector.fourCharString) on #\(self)")
        }
        return (value as String?) ?? ""
    }

    /// Reads a variable-length array property of AudioObjectIDs.
    func readObjectList(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = Self.address(selector)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else {
            throw CoreAudioError.osStatus(err, "size of \(selector.fourCharString) on #\(self)")
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }
        var list = [AudioObjectID](repeating: .unknown, count: count)
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &list)
        guard err == noErr else {
            throw CoreAudioError.osStatus(err, "read \(selector.fourCharString) on #\(self)")
        }
        return list
    }
}

extension AudioObjectPropertySelector {
    var fourCharString: String {
        let chars = [
            UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF),
        ]
        return String(bytes: chars, encoding: .ascii) ?? String(self)
    }
}

/// Block-based property listener that removes itself on deinit/cancel.
final class AudioPropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private var block: AudioObjectPropertyListenerBlock?

    init(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) throws {
        self.objectID = objectID
        self.address = AudioObjectID.address(selector)
        self.queue = queue
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        self.block = block
        let err = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        guard err == noErr else {
            throw CoreAudioError.osStatus(err, "add listener \(selector.fourCharString)")
        }
    }

    func cancel() {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
        self.block = nil
    }

    deinit { cancel() }
}
