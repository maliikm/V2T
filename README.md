# V2T — Voice Memos with real transcription

A native macOS app modeled on Apple Voice Memos, with one big upgrade: recordings are transcribed with **speaker diarization** (who said what) using [ElevenLabs Scribe v2](https://fal.ai/models/fal-ai/elevenlabs/speech-to-text/scribe-v2) via the fal.ai API, and every transcript is one click away from being pasted into Claude.

## Features

- **Recording library** — a permanent recordings-list column with title, date ("Today", "Yesterday", weekday), duration, favorites, and a transcript badge. Stored in `~/Library/Application Support/V2T/Library/`.
- **Folders** — a collapsible folder sidebar (toolbar sidebar button) with All Recordings, Favorites, and your own folders: create, rename, delete, and move recordings between them; new recordings land in the folder you're viewing.
- **Record** — red record button at the bottom of the sidebar captures AAC m4a (48 kHz), just like Voice Memos.
- **Menu bar app-audio capture** — the V2T menu bar item records **another app's audio** (Zoom, Meet in a browser, etc.) or all system audio via ScreenCaptureKit, desktop-audio style. Pick "Record System Audio" or a specific app, stop from the same menu, and the capture lands in the library and auto-transcribes. Requires the **Screen Recording** permission (macOS gates system-audio capture behind it) — approve V2T in System Settings → Privacy & Security → Screen Recording on first use. The menu bar item keeps working with the main window closed.
- **Import** — drag audio straight out of Apple Voice Memos (or any m4a/mp3/wav file) into the list, or use the import button.
- **Playback** — overview waveform with click-to-seek, a zoomed scrubbing waveform view (toggle with the waveform/transcript toolbar button; drag it to scrub), big time counter, ±15 s skip, play/pause, and **Space** to play/pause anywhere (except while typing in a text field).
- **Options** — playback speed (0.5×–2×) and Skip Silence (V2T precomputes quiet ranges from the waveform and jumps over them).
- **Search** — the search field matches titles *and* transcript text.
- **Transcripts** — auto-transcribed on record/import (toggleable). Speaker-labeled blocks with timestamps; long single-speaker turns are split at pauses and sentence ends so every block is a precise seek target; renameable speaker chips; **click any block to move playback there** (right-click for Play from Here / Copy Text); the current block highlights and follows during playback. Word-level timing is stored with each transcript. Recordings transcribed before this feature keep their coarse blocks — right-click → Re-transcribe to upgrade them.
- **Trim editor** — select a range on the waveform, then **Trim** (keep selection) or **Delete** (remove selection); Apply/Cancel commit semantics like Voice Memos.
- **Share & export** — share the audio file, copy the transcript as Markdown ready for Claude, copy plain text, or save a `.md`.

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (`xcode-select --install`) — no Xcode project needed
- A [fal.ai API key](https://fal.ai/dashboard/keys)

## Run it

```bash
git clone https://github.com/maliikm/V2T.git
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
- Editing audio (trim/delete) invalidates the transcript; re-transcribe from the transcript pane.

## Costs

Transcription is billed by fal.ai per audio minute; a typical 1-hour meeting costs well under a dollar. Recording, playback, editing, and search are all local and free.

## How transcription works

1. `POST https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3` → `PUT` the audio to the returned upload URL.
2. `POST https://queue.fal.run/fal-ai/elevenlabs/speech-to-text/scribe-v2` with `{ audio_url, diarize: true, num_speakers }`.
3. Poll the queue status URL, fetch the word-level result (`speaker_id` per word), and group words into per-speaker segments.
4. Recordings over 20 minutes are split with AVFoundation first; chunk-local speaker labels are mapped onto global ones by matching who talks at the same timestamps inside the 2-minute overlaps, then the duplicated overlap is cut at its midpoint.
