# V2T

A native macOS app for recording calls, reading transcripts, and keeping a searchable meeting library. Audio stays in your local library. Live transcripts stream directly to **Deepgram Nova-3**. AI titles run on the Mac; final transcription uses your selected provider: **Deepgram Nova-3** or ElevenLabs Scribe v2 through fal.ai. Saved provider choices and separate Keychain credentials are preserved.

## Recording and browsing

Click the source summary above Record to choose **Microphone**, **Application**, or **All Mac Audio**. Application mode provides a searchable app list. **Include my microphone** controls whether your mic starts on; you can change it during the recording. The main window, menu bar, and shortcuts share this configuration. An unavailable app must be reselected; it never falls back to another source.

- Select any saved recording while a call continues. Its transcript and copy controls remain available. A persistent bar provides pause/resume, stop, mic control, and **Show Recording**.
- Saved recordings open to their transcript. **Copy Transcript** copies speaker names, timestamps, and text; the More menu provides **Copy Markdown**, audio sharing, favorites, and playback options.
- Library previews and recording headers always show the **actual date and start time**, including today's recordings. Automatic titles never remove this information.
- Playback and audio editing are unavailable during capture so an old recording cannot leak into the call recording. Reading, copying, searching, and organizing remain available.
- The recording view emphasizes the live transcript and essential controls. Audio-level meters and large precision timers have been removed. Recording counters consistently show hours, minutes, and seconds (`HH:MM:SS`). Waveforms remain available for playback, seeking, and audio editing.

### Microphone and echo reduction

Use **Mic on / Mic off** in the recording window or persistent bar, the mic button in the menu bar, or **⌘⌥M**. You can enable the mic even if the call started with it off. This controls V2T's recording only; it does not change the meeting app's mute button.

Use headphones or keep the mic off while listening and turn it on when speaking to avoid speaker bleed. Muted sections are written as silence, including in the saved raw mic track, so your later speech stays aligned with the call. Pausing removes time from both tracks; enabling the mic after a pause accounts for the removed time.

Once enabled, the input engine stays running while V2T mutes its saved output; the macOS microphone indicator may remain visible.

Global shortcuts:

| Action | Shortcut |
| --- | --- |
| Start/stop recording | ⌘⌥R |
| Pause/resume recording | ⌘⌥P |
| Include/mute mic in a call recording | ⌘⌥M |

## Live and final transcripts

Live transcripts use **Deepgram Nova-3 streaming** with your saved Deepgram API key. Enable them in Settings and use a supported Deepgram language code (`en` by default; `multi` or an empty value for multilingual recognition). Audio is sent directly over an authenticated secure WebSocket, normalized to 16 kHz mono PCM16. Model-improvement opt-out is always enabled. Streaming has its own Deepgram usage charges, separate from final transcription.

Call previews distinguish **Call audio** from **My microphone**, using separate streams. The microphone stream only runs while microphone recording is enabled. Pausing closes the streams; resuming creates fresh streams with recording-relative timestamps. Interim words update in place, finalized passages stay visible, and stopping allows a bounded three-second drain for the last words. Network interruptions use bounded retries; account/key errors show an actionable message. A five-second audio queue bounds memory; network gaps can leave gaps in the preview, while the locally recorded audio remains available for final transcription.

When recording stops, the preview is saved as `live-preview.txt` beside the audio and remains readable/copyable while the final transcript is processing. With the selected provider’s key and automatic transcription enabled, Deepgram Nova-3 or fal’s Scribe v2 produces the final speaker-labeled transcript. Provider/model metadata and transcript history remain available. Deepgram receives a direct upload; fal’s long recordings are chunked with overlap and stitched together.

### Correcting speakers

Name speakers using the fields above the transcript. Each passage has a speaker menu:

- Choose an existing speaker to reassign **that passage**.
- Use **Reassign All … Passages** to merge a mistaken label into another speaker.
- **Undo Speaker Change** reverses recent corrections during the current app session.

Corrections are saved to disk, applied to exports, and kept in word timing so trim/delete edits preserve them. Re-transcribing archives the previous transcript and its names, then replaces the transcript and resets speaker names. **Previous Versions** opens the archive in Finder. With fal, supplying the expected speaker count can improve the initial assignment; Deepgram uses automatic speaker detection.

## Deepgram setup

1. Open Settings → Final Transcript Service and select **Deepgram · Nova-3**.
2. Paste your Deepgram API key and click **Save Key**. The existing fal key is retained.
3. Set the Deepgram language code (`en` by default, `es`, or `multi` for supported multilingual conversations). Leave it empty to detect the dominant language. This setting is separate from fal's `eng`/`spa` codes.
4. Transcribe a short recording. Word timing, speaker renaming, click-to-seek, export, and transcript-preserving trims use the same local format as fal transcripts.

Deepgram receives the audio directly via HTTPS; no public file URL or fal CDN upload is involved. V2T requests Nova-3, the v2 batch diarizer, smart formatting, and `mip_opt_out=true`. Model-improvement opt-out is always enabled and may increase listed rates; it does not mean transcription happens locally. See the [API documentation](https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded) and [pricing](https://deepgram.com/pricing).

Deepgram speaker-count hints and audio-event tagging are not implemented; the fal-only controls are hidden without discarding their saved values. Deepgram files are sent whole, up to 2 GB, rather than using fal's overlapping chunks. The API has a processing-time limit; a long or difficult recording can still time out. V2T does not automatically retry paid requests or fall back to a different provider. Cancelling stops the local request, but does not guarantee the provider stops processing or waives charges.

Changing providers never bulk-transcribes or modifies your library. To compare an existing recording, switch providers and use **Re-transcribe**. Before replacement, V2T archives the previous transcript, recording metadata/speaker names, and a readable Markdown export under `Library/<recording-id>/Transcript History/`. **Previous Versions** opens that folder in Finder (manual comparison, not an in-app restore browser). Speaker names are reset on the new transcript because provider speaker numbers aren't stable identities. The current transcript remains unchanged if the request or archive write fails.

## Calendars & local AI titles

V2T reads calendars already synced with **Apple Calendar**, including Google and Outlook accounts. This works without a Google Cloud project, OAuth JSON, or a public/private calendar link.

1. In Apple Calendar, choose **Calendar → Add Account → Google** and sign in. Enable calendar syncing and wait for your events to appear.
2. In V2T Settings → Calendars, choose **Connect Apple Calendar…** and allow Calendar access.
3. Select the calendars V2T may use for recording titles. Account names distinguish similarly named calendars.

macOS calls this permission **Full Access** because EventKit does not offer a separate read-only permission. V2T only reads selected calendar events; it never creates, changes, or deletes them. Disconnect stops calendar matching in V2T. Permission can also be revoked in System Settings → Privacy & Security → Calendars. Work administrators may restrict access or account syncing.

EventKit supplies recurring events, exceptions, and time zones. All-day, cancelled, and declined events are excluded. Event titles remain on this Mac and are never sent to Deepgram or fal. Local AI on macOS 26 with Apple Intelligence uses meeting overlap and transcript content to suggest titles; a clear calendar match is the fallback when local AI is unavailable. Manual recording names are preserved.


## Other library features

- Search titles and transcript text; favorites and folders help organize recordings.
- Import audio by dragging a file into the list or using Import Audio.
- Playback includes click-to-seek, ±15 seconds, speed adjustment, and Skip Silence.
- **Edit Audio** supports microphone replacement/appending and a compact trim view. Drag the yellow handles and choose **Trim** to keep the selection or **Delete** to remove it. **Apply** saves; **Cancel** or navigating away discards unapplied trim edits. Undo, transcript retiming, and speaker names are preserved. Replacement/appending requires a new final transcript.
- Recordings live in `~/Library/Application Support/V2T/Library/`. Call captures retain separate app and mic tracks alongside the mix.
- Menu bar capture works with the main window closed. Quit is blocked during capture or saving.
- Captures stay in `~/Library/Application Support/V2T/Recovery/` until audio, raw tracks, and metadata are saved successfully. **Retry Save** and **Show Files** remain available after a failed save; interrupted captures without a manifest can be imported manually. A failed edit keeps the original audio and working file.

## Build and run

- macOS 14+; app/system audio capture requires macOS 14.4+ and System Audio Recording permission.
- Xcode Command Line Tools. Build with a macOS 26+ SDK to include local AI title generation; older SDKs omit it.
- A [Deepgram API key](https://console.deepgram.com/) or [fal.ai API key](https://fal.ai/dashboard/keys) for final transcription. Deepgram live transcripts require a Deepgram key even if the final service is fal. Recording, browsing, and local AI do not require a key.

```sh
git clone --branch main https://github.com/maliikm/V2T.git
cd V2T
./Scripts/make-app.sh
```

The script builds `V2T.app`, generates its **V2T text icon** at native macOS sizes, adds permission descriptions, and signs it locally. Move the app to `/Applications` if desired. Building the bundle is recommended for microphone, system audio, and Calendar permission prompts. Choose the final transcription provider and save its key in Settings. Existing provider preferences remain unchanged.

To select a particular installed SDK, set `SDKROOT` when building. Tests use Swift Testing (Swift 6+):

```sh
bash Scripts/test.sh
```

Tests use isolated libraries, injected credentials, and mocked network responses. They cover provider/key isolation, Deepgram parsing and request options, cancellation races, recovery and transactional saves, transcript archives, trim/apply/cancel behavior, mute/pause timing, stereo silence, speaker correction persistence/retiming/undo, calendar matching, manual-title protection, absolute dates, streaming request configuration, PCM conversion, bounded buffers, partial/final text updates, pause/mute/stop behavior, Calendar permission/selection handling, capture stalls, playable file finalization, and incomplete-recording warnings. Live audio devices, Deepgram connectivity, Calendar permission/sync, and Apple Intelligence availability also need a manual check on the target Mac; no real account credentials or microphone audio are used by the automated tests.

See [the design review](Docs/DESIGN_REVIEW.md) for the interface decisions and [the manual validation checklist](Docs/MANUAL_CHECKS.md) for device/account-dependent checks.

## Costs

Transcription is billed by the selected provider. Check [fal pricing](https://fal.ai/models/fal-ai/elevenlabs/speech-to-text/scribe-v2) or [Deepgram pricing](https://deepgram.com/pricing), including privacy/add-on adjustments. Re-transcription is another paid request. Recording, playback, editing, and search are local.

## How transcription works

Both providers return words that are normalized into V2T's local `Transcript` format. Each new transcript records its provider/model. Existing transcript files remain compatible.

### fal

1. `POST https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3` → `PUT` the audio to the returned upload URL.
2. `POST https://queue.fal.run/fal-ai/elevenlabs/speech-to-text/scribe-v2` with `{ audio_url, diarize: true, num_speakers }`.
3. Poll the queue status URL, fetch the word-level result (`speaker_id` per word), and group words into per-speaker segments.
4. Recordings over 20 minutes are split with AVFoundation first; chunk-local speaker labels are mapped onto global ones by matching who talks at the same timestamps inside the 2-minute overlaps, then the duplicated overlap is cut at its midpoint.

### Deepgram

1. Upload the local file directly to `POST https://api.deepgram.com/v1/listen` with token authentication and the options described above.
2. Decode the returned word timestamps, punctuated words, language, and speaker numbers. Reject malformed, empty, or undiarized responses without replacing an existing transcript.
3. Use the same segmentation, local persistence, search, export, and editing logic as the other provider. Settings are snapshotted when the request starts; switching providers mid-job does not redirect it.

## Capture integrity and diagnostics

V2T watches successful audio writes independently of the recording timer. If capture stalls, it warns immediately and attempts bounded call-tap recovery. Finished recordings use the playable file duration, and substantially incomplete captures receive a persistent warning. Original call and mic tracks are retained. Incomplete captures are not automatically titled or submitted for final transcription. The app never stretches a truncated file to match the wall-clock timer.

Quiet audio does not restart capture or imply that macOS denied permission. After ten seconds without sound, one neutral status message suggests checking the source if audio should be playing; it clears when sound returns. Capture status appears once per window, including when browsing another recording. Chrome audio-process changes update the existing tap, and its recording clock starts immediately so quiet intervals remain in the saved timeline.

Microphone capture uses the regular input engine. The prior full-duplex voice-processing path stalled both the app tap and microphone on the target Mac, and has been removed. Use headphones or enable the mic only while speaking to avoid speaker bleed.

Metadata-only diagnostics are stored in `~/Library/Logs/V2T/live-transcription.log` (bounded to roughly 256 KB). Open the folder from Settings. No administrator or Console access is needed; logs exclude audio, transcript text, calendar titles, and credentials.
