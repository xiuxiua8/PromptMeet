# Native Audio Preprocessing Validation

This record covers the signed macOS bundle built from checkpoint
`19bb25d04898bce4461bdf9979df9b245139d96b`. Generated stimuli lived under
the ignored `build/audio-reproduction/` directory. No captured audio or model
file is part of the repository.

## Baseline reproduction

| Scenario | Expected | Observed before fix | Repeatability |
| --- | --- | --- | --- |
| Exact digital silence submitted directly to packaged Whisper | No transcript | Whisper returned a short hallucinated utterance | Reproduced in a deterministic WAV run |
| Constant DC offset at about -48 dBFS | Dropped before Whisper | Passed the RMS gate and Whisper returned text | Reproduced in a deterministic WAV run |
| Steady white noise at about -23 dBFS | Dropped before Whisper | Both native sources produced transcript events and suggestion generation began | Repeated across consecutive 8-second windows |
| Quiet room with microphone and system capture active | No transcript | Both `我` and `会议` timeline entries appeared without an intentional utterance | Repeated across consecutive 8-second windows |
| Speech after silence | Preserve onset and transcribe | Packaged Whisper recognized the main phrase, but the first word was vulnerable at the existing chunk boundary | Reproduced once in the packaged app and deterministically through Whisper |
| Quiet speech at about -55 dBFS | Transcribe | Direct Whisper recognized the phrase, while the current RMS gate is high enough to discard it | Reproduced in a deterministic WAV run |
| Overlapping microphone pickup and system playback | Keep sources independent | Both source labels remained independent, but noise and unrelated queued text obscured the intended speech | Reproduced in the packaged app |
| Pause, play speech, resume | Do not replay paused audio | Audio played while paused did not replay after resume | Reproduced once in the packaged app |
| End meeting with a transcription backlog | Stop capture promptly with no phantom final text | End remained in progress while queued Whisper jobs continued to publish visible transcripts | Reproduced once and terminated to prevent further capture |
| One source unavailable | Other source remains active and correctly labeled | Existing packaged behavior and coordinator tests keep the surviving source active | Deterministic coordinator coverage exists; post-fix walkthrough repeats it |

## Failure anatomy

- Initiating trigger: a non-speech buffer reaches `PCMTranscriptionSegmenter` with whole-buffer RMS at or above 80, or an already queued job remains when stop begins.
- Masking condition: the existing test covers only constant near-silence below 80. It does not cover DC offset, white noise, adaptive floor changes, or the stop queue.
- Visible symptom: hallucinated timeline rows appear as real microphone or meeting speech, which then advances context revisions, suggested-question work, and summary inputs. During stop, more phantom rows remain visible.

## Working and failing path comparison

The packaged Whisper binary was run with the app's model and non-speech suppression settings against deterministic PCM:

- exact silence, DC offset, and white noise can all produce text if submitted;
- normal speech after two seconds of silence transcribes correctly;
- quiet speech around -55 dBFS also transcribes correctly.

The original segmenter was introduced with a single `minimumRMS = 80` check and no empirical speech or noise model. Raising that threshold cannot solve the problem: loud white noise remains above it, while proven quiet speech is already below it. Lowering it preserves more quiet speech but submits more noise. This falsifies a one-threshold explanation as a sufficient fix.

## Post-fix evidence

The signed packaged walkthrough covered the native capture path rather than only
feeding the segmenter in tests:

| Scenario | Post-fix result |
| --- | --- |
| Combined microphone and system capture | Real microphone speech opened only the microphone gate; digitally silent system audio remained `静音，未送入转写`. Ending the meeting returned within the three-second observation window without later transcript rows. |
| System-audio-only digital silence | The fresh meeting remained at zero transcript events. No suggestion, summary, or context work began. |
| Ten seconds of steady white noise | The meeting remained at zero transcript events after the noise ended and after the Whisper observation window. |
| Normal speech after silence | The packaged Whisper path recognized the controlled phrase and displayed it as the live system-audio transcript. |
| Missing ScreenCaptureKit tail buffers | The walkthrough exposed that an application can stop producing system-audio buffers immediately after speech. The valid preview then remained unfinalized. A regression reproduced this without a trailing silence packet, failed before the boundary fix, and passed after a source-scoped 600 ms inactivity close applied the configured hangover and submitted one final system transcript. |
| Pause and meeting end | Pause cleared the unfinalized preview without replay. Stop remained prompt. Automated generation-scoped queue tests confirm late results and inactivity tasks cannot publish after pause or stop. |

The final deterministic suite also covers exact silence, empty input, DC offset,
near-silence, steady white noise, quiet speech, brief speech across chunk
boundaries, pre-roll, hangover, overlapping sources, source failure,
pause/resume, monotonic timing, and packaging entitlements. Diagnostics expose
only aggregate per-source frame and utterance counters and never audio samples or
recognized content.
