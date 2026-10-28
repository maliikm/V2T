# Capture and streaming validation — 2026-10-28

## Chrome follow-up — build 4

The earlier system-wide test below did not establish that Chrome capture was reliable. A subsequent Chrome recording retained only 25.25 seconds of call audio from a roughly 48-second session while its microphone track continued for 46.1 seconds.

A local diagnostic using the production `TapRecordingSession`, file writers, and live PCM conversion/queues reproduced the failure. After the silence watchdog rebuilt the tap, call-file writes stopped: a 65.79-second session saved 13.08 seconds of call audio and 65.1 seconds of microphone audio. Silence had been treated both as permission denial and as a reason to restart an otherwise healthy tap.

Build 4 removes silence-driven recovery, starts the aggregate device clock without waiting for process audio, and changes Chrome's tapped process set in place. Missing file writes still trigger bounded recovery; quiet samples alone do not. Quiet-source notices are informational, clear when sound returns, and share one status surface per window. Persistent warnings about genuinely incomplete saved tracks remain.

Before replacing the installed app, two Chrome tests used a local 431 Hz fixture with a scheduled twelve-second silent interval. Both exercised the production capture and live PCM conversion paths; no audio was uploaded and the recording library was untouched.

| Chrome configuration | Active session | Saved call audio | Saved mic audio | Final playback |
| --- | ---: | ---: | ---: | ---: |
| Mic off | 75.15 s | 75.16 s | — | 75.16 s |
| Mic on; process set narrowed and restored mid-recording | 75.80 s | 75.81 s | 75.10 s | 75.81 s |

The mic starts slightly after the call track; the production mixdown aligns it using capture timestamps. Decoding the saved files confirmed the fixture before and after the silent interval, including every one-second window in the final ten seconds. The mic-on test also confirmed the quiet notice appeared and cleared automatically. Both process updates completed without recreating the tap or losing the saved timeline.

An initial process-update implementation exposed a runtime `CATapDescription.copy()` exception during testing. The final implementation constructs a new description with the same tap identity instead; the passing mic-on test above used that correction. A regression test verifies identity, scope, and process membership. The complete automated suite passed 62 tests in 18 suites, and the signed release bundle built successfully.

These are controlled capture tests on the target Mac, not a multi-hour call or a device-switch test. Deepgram WebSocket connectivity was tested separately below; this follow-up exercised its local audio conversion and buffering without sending microphone audio.

## Earlier system-wide capture and Deepgram checks — build 3

The full-duplex microphone voice-processing path introduced a capture regression on the target Mac. An isolated diagnostic played a quiet tone and recorded a system process tap, adding the microphone after two seconds. It used separate temporary files and did not open or alter the recording library.

| Capture path | Saved call audio | Saved mic audio | Result |
| --- | ---: | ---: | --- |
| System audio only | 12.67 s | — | Continuous |
| Previous voice-processing microphone | 2.55 s | 0 s | Call tap stopped after mic activation |
| Regular microphone, first run | 13.05 s | 10.40 s | Both tracks continuous |
| Regular microphone, second run | 13.29 s | 10.40 s | Both tracks continuous |

The diagnostic's nominal duration was 12 seconds; engine setup and scheduling account for the small timing differences. The previous path reproduced the reported short-file failure. The revised capture uses the regular input engine. Headphones or mic muting are still needed to avoid speaker bleed.

The app now monitors successful audio writes, reports stalled capture, attempts bounded tap recovery, and checks each finalized track against active recording time. It preserves captured tracks and displays incomplete-recording warnings. It never stretches a short file merely to match the session timer.

A separate live Deepgram check streamed a 7.26-second synthesized speech fixture through the production request builder, PCM converter, and WebSocket client. Deepgram returned six interim results and two final results containing the complete fixture text. No meeting audio was sent for this test.

The automated suite passed 60 tests across 18 suites, including stream lifecycle, corrected-key retry, PCM conversion, bounded buffers, Calendar permission/selection behavior, capture-stall detection, individual-track validation, and finalized AAC duration. Apple Calendar account syncing and permission still require an interactive check with the user's account.
