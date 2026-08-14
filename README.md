# V2T — Voice to Text for Mac

A small native macOS app that turns meeting recordings (e.g. from **Apple Voice Memos**) into accurate, speaker-labeled transcripts you can paste straight into Claude.

- **Model:** [ElevenLabs Scribe v2](https://fal.ai/models/fal-ai/elevenlabs/speech-to-text/scribe-v2) via the fal.ai API — currently the most accurate speech-to-text available on fal, with built-in **speaker diarization** (who said what), word-level timestamps, and 90+ language support.
- **Privacy:** audio is uploaded to fal.ai storage only for transcription; your API key lives in the macOS Keychain.

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (`xcode-select --install`) — no Xcode project needed
- A [fal.ai API key](https://fal.ai/dashboard/keys)

## Run it

```bash
git clone https://github.com/maliikm/v2t.git
cd v2t
swift run
```

Or build a double-clickable app bundle:

```bash
./Scripts/make-app.sh
mv V2T.app /Applications/
```

## Usage

1. First launch: paste your fal.ai API key (get one at [fal.ai/dashboard/keys](https://fal.ai/dashboard/keys)). It's stored in your Keychain.
2. **Drag a memo straight out of the Voice Memos app** into the window (or click *Choose File…* — m4a, mp3, wav, and most other formats work).
3. Click **Transcribe**. The app uploads the file, runs Scribe v2 with diarization, and shows the transcript grouped into speaker turns with timestamps.
4. **Rename speakers**: click a speaker chip at the top (e.g. "Speaker 1") and type the person's real name — the transcript and exports update everywhere.
5. Share with Claude:
   - **Copy for Claude** — copies the transcript as Markdown with a short header, ready to paste into a Claude conversation for summarization, action items, etc.
   - **Copy Text** — plain text.
   - **Save…** — writes a `.md` file.

## Settings (⌘,)

- fal.ai API key
- Tag audio events (laughter, applause) — off by default
- Language code hint (e.g. `eng`) — leave empty for auto-detect

## Notes & limits

- fal's Scribe endpoints cap a single request at **20 minutes** of audio. Longer recordings are handled automatically: V2T splits them into overlapping ~19-minute chunks, transcribes the chunks in parallel, matches the speaker labels across chunk boundaries (using the shared overlap audio), and stitches everything into one continuous transcript.
- If a speaker is silent for the entire overlap window between two chunks, they can occasionally come back as a new "Speaker N" in the next chunk — just give both chips the same name and the exports will read correctly.
- Transcription cost is billed by fal.ai per audio minute; a typical 1-hour meeting costs well under a dollar.
- Voice Memos stores recordings in `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/` — but dragging directly from the Voice Memos app is easiest.

## How it works

1. `POST https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3` → `PUT` the audio file to the returned upload URL.
2. `POST https://queue.fal.run/fal-ai/elevenlabs/speech-to-text/scribe-v2` with `{ audio_url, diarize: true }`.
3. Poll the queue status URL, then fetch the result: word-level output with `speaker_id` per word.
4. Words are grouped into contiguous per-speaker segments for display and export.
5. Recordings longer than 20 minutes are first split with AVFoundation into 19-minute chunks that overlap by 45 seconds; each chunk's local speaker labels are mapped onto the global ones by finding which speakers talk at the same timestamps inside the overlap, and the duplicated overlap words are cut at its midpoint.
