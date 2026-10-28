# V2T interface review

The primary workflow is recording a meeting, finding its transcript, copying it, and correcting who said what. The original interface borrowed heavily from a voice memo editor: prominent animated audio levels, large hundredths-of-a-second counters, and a waveform-first detail pane. Those elements consumed attention without advancing the main workflow.

| Finding | Decision and resulting behavior |
| --- | --- |
| The recording screen replaced any selected recording | Separate live capture from library selection. Keep capture controls visible above another recording's transcript. |
| Live meters, two waveform views, and large precise timers dominated recording | Remove the live visualizations and their continuously growing meter histories. Show a compact elapsed time, status, transcript, and recording controls. |
| Several source choices differed only in whether the mic was included | Preserve the three source cards and extend the independent microphone toggle into the running session. Keep the same mic wording and behavior in the window, persistent bar, menu bar, and shortcut. |
| Waveforms were shown before transcripts | Open saved recordings to the transcript. Preserve waveform view for deliberate listening/seeking and audio editing. |
| Copying a transcript required opening an export menu | Add a direct Copy Transcript button. Keep Markdown copying and audio sharing in a secondary menu and remove assistant-specific labels. |
| Relative dates made identically titled meetings hard to distinguish | Always show actual calendar date and start time in the list and detail header. |
| Renaming a speaker could not repair individual attribution mistakes | Add a speaker menu on every passage, with individual reassignment, whole-label reassignment, and undo. Persist corrections at word and passage level. |
| Background title generation could surprise users | Limit it to newly captured recordings and stop automatic renaming after a manual title edit. Keep date/time independent of titles. |
| Final transcription hid text while it was processing | Save and display the Deepgram live preview until a final transcript is ready, with clear preview labeling. |
| Old-recording playback could contaminate a current call | Block all playback entry points during capture, including Space and transcript context menus, and explain availability in the detail pane. |
| Multiple record controls could start competing engines | Preserve the existing shared coordinator and recovery workflow; route runtime mic controls through the active capture. |

Retained features: the permanent recording library, search, folders, favorites, audio import, speaker names, playback speed, skip-silence, and audio editing. Each supports an identifiable retrieval, correction, or listening task. Advanced editing stays behind its explicit toolbar action rather than competing with reading.

The interface uses native SwiftUI controls, semantic colors, selectable transcript text, text labels for recording/mic state, and explicit accessibility labels on icon-only playback controls. Status does not depend on color alone. Settings groups live recognition, final transcription, local titles, synced calendar access, and shortcuts by user purpose.

Scope of validation: source review and native build, automated workflow checks, and window inspection where available. Echo reduction quality, recognition accuracy, VoiceOver navigation, Calendar permission, and local-model behavior still require checks with actual devices and accounts; these are not inferred from a successful compile.
