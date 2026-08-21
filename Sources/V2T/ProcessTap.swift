import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os.log

/// Owns the Core Audio process tap + private aggregate device that captures
/// the audio output of a set of process objects. (Ported from DesktopAudio.)
///
/// Lifecycle: `activate()` → `run(ioBlock:)` → `invalidate()`. Idempotent
/// teardown; safe to call `invalidate()` at any point.
@available(macOS 14.4, *)
final class ProcessTap {
    private static let logger = Logger(subsystem: kV2TSubsystem, category: "ProcessTap")

    enum Mode {
        /// Capture ONLY the listed process objects.
        case processes([AudioObjectID])
        /// Capture ALL system audio EXCEPT the listed process objects
        /// (empty list = everything).
        case globalExcluding([AudioObjectID])

        var objectIDs: [AudioObjectID] {
            switch self {
            case .processes(let ids), .globalExcluding(let ids): ids
            }
        }
    }

    private(set) var tapID: AudioObjectID = .unknown
    private(set) var aggregateDeviceID: AudioObjectID = .unknown
    /// The tap's stream format, valid after `activate()`.
    private(set) var tapFormat: AVAudioFormat?

    private var tapDescription: CATapDescription?
    private var ioProcID: AudioDeviceIOProcID?
    private var started = false

    /// Creates the tap and aggregate device for the given capture mode.
    func activate(mode: Mode) throws {
        precondition(tapID == .unknown, "ProcessTap already activated")

        // 1. Tap description: stereo mixdown, scoped by mode.
        let description: CATapDescription
        switch mode {
        case .processes(let objectIDs):
            guard !objectIDs.isEmpty else {
                throw CoreAudioError.osStatus(kAudioHardwareBadObjectError, "activate with no processes")
            }
            description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        case .globalExcluding(let objectIDs):
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: objectIDs)
        }
        description.uuid = UUID()
        description.name = "V2T-\(description.uuid.uuidString)"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        tapDescription = description

        var newTapID = AudioObjectID.unknown
        var err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr, newTapID.isValid else {
            throw CoreAudioError.osStatus(err, "AudioHardwareCreateProcessTap")
        }
        tapID = newTapID

        do {
            // 2. Aggregate device containing the default output device + the tap.
            let outputDeviceID: AudioObjectID = try AudioObjectID.system.read(
                kAudioHardwarePropertyDefaultOutputDevice,
                defaultValue: AudioObjectID.unknown
            )
            let outputUID = try outputDeviceID.readString(kAudioDevicePropertyDeviceUID)

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "V2T Capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
            ]

            var newAggregateID = AudioObjectID.unknown
            err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
            guard err == noErr, newAggregateID.isValid else {
                throw CoreAudioError.osStatus(err, "AudioHardwareCreateAggregateDevice")
            }
            aggregateDeviceID = newAggregateID

            // 3. The tap's stream format drives file writing — BUT the IO
            // proc delivers frames on the AGGREGATE device's clock (i.e. the
            // physical output device's rate, with drift compensation). When
            // that differs from the rate in the tap's advertised ASBD (e.g.
            // Chrome mixing at 48 kHz while the speakers run at 44.1 kHz),
            // trusting the ASBD mislabels the audio and playback comes out
            // pitched up / fast. The aggregate's nominal rate is the truth.
            var asbd = try tapID.read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
            let aggregateRate: Double = (try? aggregateDeviceID.read(
                kAudioDevicePropertyNominalSampleRate, defaultValue: Double(0)
            )) ?? 0
            if aggregateRate > 0, abs(asbd.mSampleRate - aggregateRate) > 1 {
                Self.logger.warning("Tap ASBD rate \(asbd.mSampleRate, privacy: .public) != aggregate rate \(aggregateRate, privacy: .public) — using the aggregate rate")
                asbd.mSampleRate = aggregateRate
            }
            guard let format = AVAudioFormat(streamDescription: &asbd) else {
                throw CoreAudioError.osStatus(kAudioHardwareUnsupportedOperationError, "AVAudioFormat from tap ASBD")
            }
            tapFormat = format
        } catch {
            invalidate()
            throw error
        }
    }

    /// Installs the IO proc on the aggregate device and starts it.
    func run(on queue: DispatchQueue, ioBlock: @escaping AudioDeviceIOBlock) throws {
        precondition(aggregateDeviceID.isValid, "activate() must succeed before run()")
        precondition(ioProcID == nil, "run() already called")

        var err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, queue, ioBlock)
        guard err == noErr, ioProcID != nil else {
            throw CoreAudioError.osStatus(err, "AudioDeviceCreateIOProcIDWithBlock")
        }
        err = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard err == noErr else {
            throw CoreAudioError.osStatus(err, "AudioDeviceStart")
        }
        started = true
    }

    func invalidate() {
        if let ioProcID, aggregateDeviceID.isValid {
            if started {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                started = false
            }
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
        tapFormat = nil
        tapDescription = nil
    }

    deinit { invalidate() }
}
