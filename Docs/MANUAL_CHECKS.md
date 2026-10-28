# Device and account checks

Use a disposable test recording rather than an important call for the first run.

- Start app/system capture with mic off. Select a different recording, search/filter the library, copy its transcript, and return with Show Recording. Confirm the capture timer continues and pause/stop remain available.
- Toggle the mic on, off, and back on using the window, menu bar, and ⌘⌥M. Repeat after pausing and resuming, including enabling it for the first time while paused. Listen for continuous call audio, silent muted sections, and correct voice alignment.
- Deny mic permission while app capture runs: the call must continue, with a useful message. Stop while a permission request is open and verify a late response cannot enable an old session.
- Try speakers and headphones; check speaker bleed with the mic enabled. Switch output devices mid-call. Verify the microphone is never monitored audibly.
- Enable live previews in a supported language; confirm text arrives for call audio and mic speech, stops updating while paused/muted, and continues after a minute. Test a missing/invalid Deepgram key, a network interruption, and a long silent interval. Recording must survive these failures.
- Stop the recording and open the preview while final transcription runs. Confirm final text replaces the preview when available and that the saved preview can still be found on disk.
- Connect a Google account in Apple Calendar, then connect V2T; test denied/revoked Calendar permission, calendar selection, recurring events, account syncing, and disconnect. Calendar errors must not interrupt recording.
- Test title generation with one matching meeting, simultaneous meetings, no meeting, a paused meeting, and an unavailable local model. A manual rename must survive a late generated title.
- Reassign one passage, then all passages of a label. Undo, reopen the app, copy/export, and trim audio. Check that corrected labels and word times remain consistent.
- Check the library at narrow and wide widths, with long duplicate titles, multiple dates, and recordings on the same day. Dates must remain actual dates rather than relative terms.
- Review keyboard-only navigation, VoiceOver labels, dark mode, and large text settings. Inspect the V2T icon in Finder and the Dock.

- Compare elapsed recording time against the saved file duration, including a long call, mic toggles, and device switches. Force a stalled source and verify the capture warning appears and saved partial audio is not presented as a full recording. Original tracks must remain available.
- Check recording timers in the window, sidebar, and menu bar: `00:00:00` initially, then `01:00:00` at one hour, with no fractional seconds.
