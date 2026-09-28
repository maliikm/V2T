# V2T — Voice Memos with real transcription

A native macOS app modeled on Apple Voice Memos, with one big upgrade: recordings are transcribed with **speaker diarization** (who said what) using [ElevenLabs Scribe v2](https://fal.ai/models/fal-ai/elevenlabs/speech-to-text/scribe-v2) via the fal.ai API, and every transcript is one click away from being pasted into Claude.

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
- **Edit mode** — the toolbar's Edit button switches the pane in place (waveform view is the default view): **REPLACE** records your mic over the audio from the playhead, **RESUME** appends when the playhead is at the end, and the crop tool selects a range to **Trim** (keep) or **Delete** (the selection strip shows the playhead and seeks on click, so cuts can be auditioned). Every edit is one **Undo** step; **Done** commits back to the library. **Trim/Delete keep the transcript** — it's retimed to match the edit, speaker names included; only REPLACE/RESUME (new audio content) require a re-transcribe.
- **Share & export** — share the audio file, copy the transcript as Markdown ready for Claude, copy plain text, or save a `.md`.

## Requirements

- macOS 14 (Sonoma) or later — app-audio capture from the menu bar needs 14.4+
- Xcode Command Line Tools (`xcode-select --install`) — no Xcode project needed
- A [fal.ai API key](https://fal.ai/dashboard/keys)

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

Set your fal.ai API key in **Settings (⌘,)**.

## Transcription accuracy

- The model is ElevenLabs **Scribe v2** on fal — the most accurate speech-to-text on fal, with built-in diarization.
- **Set the number of speakers** (per recording in the transcript pane, or a default in Settings). A known speaker count is far more reliable than auto-detection.
- fal's Scribe endpoints cap a single request at 20 minutes, so longer recordings are split into ~19-minute chunks overlapping by 2 minutes, transcribed in parallel, and stitched back together; speaker labels are matched across boundaries using the overlap. If someone is silent through an entire overlap window they can come back as a new "Speaker N" — give both chips the same name and exports read correctly.
- Trim/Delete retime the existing transcript. Replace/Resume add new speech and require re-transcription.

## Verify changes

With Swift 6 installed, run `bash Scripts/test.sh`. It uses isolated temporary libraries and synthetic audio bytes, never your recordings, microphone, Keychain, or transcription account. Tests cover source persistence/migration, exact app selection, overlapping start requests, recovery after metadata/track failures, safe edits, and transcript write errors.

Before relying on a long recording, run these hardware smoke checks on your Mac:

1. Record a short microphone take; pause/resume using ⌘⌥P and stop with ⌘⌥R. Confirm it appears in the selected folder and plays back.
2. Select a playing app, then try mic off and mic on. Check the separate meters and both sides of the saved audio. Repeat with All Mac Audio.
3. Change the source in the menu bar and verify the main-window summary matches. Quit the selected application before starting; V2T should require a new selection, never broaden capture.
4. Close the main window, start/stop from the menu bar, then reopen V2T and check the saved item. Test microphone denial, system-audio denial, and your usual output-device switch.
5. If a real save fails, free disk space or restore write access, then use Retry Save. Keep the Recovery files until playback of the recovered item is verified.

## Costs

Transcription is billed by fal.ai per audio minute; a typical 1-hour meeting costs well under a dollar. Recording, playback, editing, and search are all local and free.

## How transcription works

1. `POST https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3` → `PUT` the audio to the returned upload URL.
2. `POST https://queue.fal.run/fal-ai/elevenlabs/speech-to-text/scribe-v2` with `{ audio_url, diarize: true, num_speakers }`.
3. Poll the queue status URL, fetch the word-level result (`speaker_id` per word), and group words into per-speaker segments.
4. Recordings over 20 minutes are split with AVFoundation first; chunk-local speaker labels are mapped onto global ones by matching who talks at the same timestamps inside the 2-minute overlaps, then the duplicated overlap is cut at its midpoint.
