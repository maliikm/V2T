# V2T

A native macOS app for recording calls, reading transcripts, and keeping a searchable meeting library. Audio stays in your local library. Live previews and AI titles run on the Mac; final transcription uses your selected provider: **Deepgram Nova-3** or ElevenLabs Scribe v2 through fal.ai. Saved provider choices and separate Keychain credentials are preserved.

## Recording and browsing

Click the source summary above Record to choose **Microphone**, **Application**, or **All Mac Audio**. Application mode provides a searchable app list. **Include my microphone** controls whether your mic starts on; you can change it during the recording. The main window, menu bar, and shortcuts share this configuration. An unavailable app must be reselected; it never falls back to another source.

- Select any saved recording while a call continues. Its transcript and copy controls remain available. A persistent bar provides pause/resume, stop, mic control, and **Show Recording**.
- Saved recordings open to their transcript. **Copy Transcript** copies speaker names, timestamps, and text; the More menu provides **Copy Markdown**, audio sharing, favorites, and playback options.
- Library previews and recording headers always show the **actual date and start time**, including today's recordings. Automatic titles never remove this information.
- Playback and audio editing are unavailable during capture so an old recording cannot leak into the call recording. Reading, copying, searching, and organizing remain available.
- The recording view emphasizes the live transcript and essential controls. Audio-level meters and large precision timers have been removed. Waveforms remain available for playback, seeking, and audio editing.

### Microphone and echo reduction

Use **Mic on / Mic off** in the recording window or persistent bar, the mic button in the menu bar, or **⌘⌥M**. You can enable the mic even if the call started with it off. This controls V2T's recording only; it does not change the meeting app's mute button.

The mic uses macOS voice processing for echo reduction. Keep it off while listening and turn it on when speaking. Muted sections are written as silence, including in the saved raw mic track, so your later speech stays aligned with the call. Pausing removes time from both tracks; enabling the mic after a pause accounts for the removed time.

Echo reduction depends on the input/output devices and room. Headphones can still help if speaker bleed remains. Once enabled, the input engine stays running while V2T mutes its saved output; the macOS microphone indicator may remain visible.

Global shortcuts:

| Action | Shortcut |
| --- | --- |
| Start/stop recording | ⌘⌥R |
| Pause/resume recording | ⌘⌥P |
| Include/mute mic in a call recording | ⌘⌥M |

## Live and final transcripts

Live previews use Apple's **on-device** speech recognition. Enable them and select a language in Settings. V2T requests Speech Recognition permission when you record. If the device or selected language does not support on-device recognition, V2T keeps recording audio and explains why the preview is unavailable. It does not silently send live audio to a cloud recognizer.

Call previews distinguish **Call audio** from **My microphone**. They do not reliably identify individual participants. Recognition requests rotate during long recordings, so previews may contain incomplete wording around boundaries. They are a convenience while recording, not the final transcript.

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

## Google Calendar & local AI titles

V2T connects **directly to Google Calendar**, independently of the macOS Calendar app. It requests read-only access to events and the calendar list. Select which calendars can be used in V2T Settings.

For a personal build, configure Google OAuth once:

1. Create or choose a project in [Google Cloud Console](https://console.cloud.google.com/).
2. Enable **Google Calendar API** and configure the OAuth consent screen. If the app is in testing, add your Google account as a test user.
3. Create an OAuth client with application type **Desktop app**, and download its JSON file.
4. In V2T Settings → Google Calendar, choose **Import Desktop OAuth Client JSON…**, then **Connect Google Calendar…**.
5. Complete Google sign-in in your browser and select the calendars to use.

The app uses a loopback callback, PKCE, and a random state value. Client configuration and access/refresh tokens stay in Keychain; do not commit the downloaded JSON to this repository. **Disconnect** removes stored tokens from the Mac. You can also revoke the app's access from your Google account. See [Google's desktop OAuth documentation](https://developers.google.com/identity/protocols/oauth2/native-app).

With **Automatically title new recordings** enabled, V2T checks events overlapping the actual recording period and uses transcript content to generate a concise title with Apple's on-device Foundation Models framework. A title can improve after the final transcript arrives. Calendar context stays out of cloud transcription requests. Renaming a recording yourself prevents subsequent automatic changes; imports and older library items are not automatically renamed.

Local AI requires **macOS 26+, an Apple Intelligence-capable Mac, and an available Apple Intelligence model**. Settings reports availability. When the model is unavailable, an unambiguous calendar match can still supply a title; ambiguous matches keep the existing title. Calendar failures do not interrupt recording or transcription.

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
- A [Deepgram API key](https://console.deepgram.com/) or [fal.ai API key](https://fal.ai/dashboard/keys) for final transcription. Live previews, recording, browsing, and local AI do not require that key.

```sh
git clone --branch main https://github.com/maliikm/V2T.git
cd V2T
./Scripts/make-app.sh
```

The script builds `V2T.app`, generates its **V2T text icon** at native macOS sizes, adds permission descriptions, and signs it locally. Move the app to `/Applications` if desired. Building the bundle is recommended for microphone and speech permission prompts. Choose the final transcription provider and save its key in Settings. Existing provider preferences remain unchanged.

To select a particular installed SDK, set `SDKROOT` when building. Tests use Swift Testing (Swift 6+):

```sh
bash Scripts/test.sh
```

Tests use isolated libraries, injected credentials, and mocked network responses. They cover provider/key isolation, Deepgram parsing and request options, cancellation races, recovery and transactional saves, transcript archives, trim/apply/cancel behavior, mute/pause timing, stereo silence, speaker correction persistence/retiming/undo, calendar matching, manual-title protection, absolute dates, OAuth PKCE/callback validation, calendar pagination/filtering, token refresh, and disconnect races. Live audio devices, Google consent, and Apple Intelligence availability also need a manual check on the target Mac; no real account credentials or microphone audio are used by the automated tests.

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
