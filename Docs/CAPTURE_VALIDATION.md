# Capture and streaming validation — 2026-10-28

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
