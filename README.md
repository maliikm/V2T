# V2T — Voice Memos with real transcription

A native macOS app modeled on Apple Voice Memos, with **speaker diarization** (who said what) using your choice of [ElevenLabs Scribe v2 through fal](https://fal.ai/models/fal-ai/elevenlabs/speech-to-text/scribe-v2) or [Deepgram Nova-3](https://developers.deepgram.com/docs/pre-recorded-audio). Transcripts can be copied as plain text or Markdown.

## Features

- **Recording library** — a permanent recordings-list column with title, date ("Today", "Yesterday", weekday), duration, favorites, and a transcript badge. Stored in `~/Library/Application Support/V2T/Library/`.
- **Folders** — a collapsible folder sidebar (toolbar sidebar button) with All Recordings, Favorites, and your own folders: create, rename, delete, and move recordings between them; new recordings land in the folder you're viewing.
- **Recording setup** — click the source summary above Record to open a native popover with **Microphone**, **Application**, and **All Mac Audio** cards. Application mode has a searchable, alphabetically stable list with icons, audio-activity hints, and a selected checkmark. **Include my microphone** is independent of the app/Mac source. The summary makes the selection explicit; an unavailable app never falls back to another app or all Mac audio. Browser capture includes all audio from that browser, not just a meeting tab.
- **One recording workflow** — the main window, menu-bar panel, and global shortcuts share the same source, mic choice, and active recording. **⌘⌥R** starts/stops; **⌘⌥P** pauses/resumes. Every engine saves into the folder selected at the start of the take, and the saved recording is selected automatically. App/Mac sessions show separate app and microphone meters. Quit is blocked while recording or saving.
- **App and Mac audio** — Core Audio process taps capture a selected app or the whole system, with optional microphone mixdown and preserved raw tracks. Requires macOS 14.4+ and System Audio Recording permission (System Settings → Privacy & Security → Screen & System Audio Recording). Microphone access is requested only when needed. The menu-bar panel keeps working with the main window closed.
- **Save recovery** — captures stay in `~/Library/Application Support/V2T/Recovery/` until audio, raw tracks, and metadata are installed successfully. A failed save exposes **Retry Save** and **Show Files** in the main window. Retry also works after relaunch when the capture manifest was saved. Interrupted captures without a manifest remain available for manual import. Metadata and transcript write errors are surfaced instead of reporting success; a failed edit keeps the original audio and editor working file.
- **Import** — drag audio straight out of Apple Voice Memos (or any m4a/mp3/wav file) into the list, or use the import button.
- **Playback** — overview waveform with click-to-seek, a zoomed scrubbing waveform view (toggle with the waveform/transcript toolbar button; drag it to scrub), big time counter, ±15 s skip, play/pause, and **Space** to play/pause anywhere (except while typing in a text field).
- **Options** — playback speed (0.5×–2×) and Skip Silence (V2T precomputes quiet ranges from the waveform and jumps over them).
- **Search** — the search field matches titles *and* transcript text.
- **Transcripts** — auto-transcribed on record/import (toggleable). Speaker-labeled blocks with timestamps; long single-speaker turns are split at pauses and sentence ends so every block is a precise seek target; renameable speaker chips; **click any block to move playback there** (right-click for Play from Here / Copy Text); the current block highlights and follows during playback. Word-level timing is stored with each transcript. Recordings transcribed before this feature keep their coarse blocks — right-click → Re-transcribe to upgrade them.
- **Edit mode** — **Edit Audio** opens the editor. **REPLACE** records your mic over audio from the playhead; **RESUME** appends at the end. **Trim Audio** opens a compact, Voice Memos-style view: drag the yellow handles, then choose **Trim** to keep the selection or **Delete** to remove it. Playback stays separate from editing, and **Undo** remains in the toolbar. **Apply** saves your edits; **Cancel** discards all unsaved audio edits. Leaving trim mode by switching recordings also discards unapplied edits. Trims preserve and retime the transcript, including speaker names; only REPLACE/RESUME require re-transcription. Outside trim mode, **Save Changes** (or switching recordings) saves edits as before.
- **Share & copy** — share the audio file, or use **Copy Transcript → Copy Markdown / Copy Plain Text**. Markdown includes speaker labels and timestamps and works with any Markdown-compatible app. There is no separate Save Markdown action.

## Requirements

- macOS 14 (Sonoma) or later — app-audio capture from the menu bar needs 14.4+
- Xcode Command Line Tools (`xcode-select --install`) — no Xcode project needed
- A [fal.ai API key](https://fal.ai/dashboard/keys) or [Deepgram API key](https://console.deepgram.com/) for transcription. Recording and playback do not require a key.

## Run it

```bash
git clone --branch main https://github.com/maliikm/V2T.git
cd V2T
swift run
```

Or build a double-clickable app bundle (recommended, especially for microphone permission):

```bash
./Scripts/make-app.sh
mv V2T.app /Applications/
```

Choose your transcription provider and save its API key in **Settings (⌘,)**. Keys are stored separately in macOS Keychain. Existing installations keep fal as the default; provider changes apply only to new requests.

## Deepgram setup

1. Open Settings → Transcription Provider and select **Deepgram · Nova-3**.
2. Paste your Deepgram API key and click **Save Key**. The existing fal key is retained.
3. Set the Deepgram language code (`en` by default, `es`, or `multi` for supported multilingual conversations). Leave it empty to detect the dominant language. This setting is separate from fal's `eng`/`spa` codes.
4. Transcribe a short recording. Word timing, speaker renaming, click-to-seek, export, and transcript-preserving trims use the same local format as fal transcripts.

Deepgram receives the audio directly via HTTPS; no public file URL or fal CDN upload is involved. V2T requests Nova-3, the v2 batch diarizer, smart formatting, and `mip_opt_out=true`. Model-improvement opt-out is always enabled and may increase listed rates; it does not mean transcription happens locally. See the [API documentation](https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded) and [pricing](https://deepgram.com/pricing).

Deepgram speaker-count hints and audio-event tagging are not implemented; the fal-only controls are hidden without discarding their saved values. Deepgram files are sent whole, up to 2 GB, rather than using fal's overlapping chunks. The API has a processing-time limit; a long or difficult recording can still time out. V2T does not automatically retry paid requests or fall back to a different provider. Cancelling stops the local request, but does not guarantee the provider stops processing or waives charges.

Changing providers never bulk-transcribes or modifies your library. To compare an existing recording, switch providers and use **Re-transcribe**. Before replacement, V2T archives the previous transcript, recording metadata/speaker names, and a readable Markdown export under `Library/<recording-id>/Transcript History/`. **Previous Versions** opens that folder in Finder (manual comparison, not an in-app restore browser). Speaker names are reset on the new transcript because provider speaker numbers aren't stable identities. The current transcript remains unchanged if the request or archive write fails.

## Transcription accuracy

- Choose between ElevenLabs **Scribe v2** on fal and Deepgram **Nova-3**. Compare representative recordings before choosing a default; accuracy and speaker assignments depend on the audio.
- With fal, **set the number of speakers** (per recording or in Settings) to provide a diarization hint. Deepgram uses automatic speaker detection.
- fal's Scribe endpoints cap a single request at 20 minutes, so longer recordings are split into ~19-minute chunks overlapping by 2 minutes, transcribed in parallel, and stitched back together; speaker labels are matched across boundaries using the overlap. If someone is silent through an entire overlap window they can come back as a new "Speaker N" — give both chips the same name and exports read correctly.
- Trim / Delete retime the existing transcript. Replace/Resume add new speech and require re-transcription.

## Verify changes

With Swift 6 installed, run `bash Scripts/test.sh`. It uses isolated temporary libraries and synthetic audio, never your recordings, microphone, Keychain, or transcription account. Tests cover capture/recovery, provider and credential isolation, request parameters, HTTP errors, speaker/word parsing, old transcript compatibility, transcript archives, settings changes during jobs, cancellation/restart races, trim boundaries, real audio keep/remove/undo/save operations, transcript retiming, and Markdown formatting. Network responses are mocked; a successful live transcription with your own key is still a manual smoke check.

Before relying on a long recording, run these hardware smoke checks on your Mac:

1. Record a short microphone take; pause/resume using ⌘⌥P and stop with ⌘⌥R. Confirm it appears in the selected folder and plays back.
2. Select a playing app, then try mic off and mic on. Check the separate meters and both sides of the saved audio. Repeat with All Mac Audio.
3. Change the source in the menu bar and verify the main-window summary matches. Quit the selected application before starting; V2T should require a new selection, never broaden capture.
4. Close the main window, start/stop from the menu bar, then reopen V2T and check the saved item. Test microphone denial, system-audio denial, and your usual output-device switch.
5. If a real save fails, free disk space or restore write access, then use Retry Save. Keep the Recovery files until playback of the recovered item is verified.

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
