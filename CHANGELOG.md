# Changelog

All notable changes to Mimika (formerly Pocket TTS).

## 1.5.12

Chat threads, reasoning-model support, and a round of performance fixes.

- **Chat threads** — Solo and Ensemble conversations are saved as threads and
  listed in a new sidebar. Pin, rename, and delete them; each gets a short
  auto-written summary. Start a new chat or a new cast without clearing your
  history, and pick any conversation up where you left off.
- **Reasoning models work** — models that think before answering (Qwen3,
  DeepSeek-R1, and similar) no longer return blank turns in Ensemble. A turn
  that spends its whole budget thinking is retried uncapped, inline
  `<think>` reasoning is stripped from the transcript and never read aloud,
  and the Thinking control can be changed mid-episode (it applies on the
  next turn).
- **Ensemble transcript actions** — copy, edit, or delete any line. Edits
  steer what the cast says next. Skip an invited turn instead of waiting out
  the 60 s countdown. Markdown tables now render in both Solo and Ensemble.
- **Settings fit a MacBook Air** — App Settings and Speaker Isolation scroll
  instead of running off the screen. Done closes Settings immediately instead
  of waiting on a model load; Load and Eject buttons sit under the model
  picker, plus an option to load the model automatically at launch. The
  chunk-budget slider now respects Cancel like every other field.
- **Update badge** — the window header shows when a newer version is on the
  App Store, and App Settings gains an App Information card with a manual
  check.
- **Performance** — fixed an app-wide stall in the Chat tab caused by SwiftUI
  layout re-negotiation with the sidebar open; the toolbar no longer flickers
  once a second; the idle window no longer redraws at 30 fps; two runaway
  1 Hz endpoint polls stopped.
- **Fixes** — titles like "Lt. Commander" are no longer split mid-sentence
  when spoken; thread files decode tolerantly so one bad field can't wipe
  the thread list.

## 1.5.11

Voice-pipeline hotfix and spoken-output fixes.

- **Crash fix on long synthesis** — the frame budget is clamped to the KV
  cache capacity, fixing a hard crash on Apple Neural Engine (M4 / macOS
  26.6) and silent audio corruption on other devices past the cache limit.
- **Silent-voice bake fixed** — on macOS 27 beta the voice encoder could
  return an all-zero state and save a dead, identity-less voice. The bake now
  validates its output and retries on CPU; existing broken voices surface a
  clear re-import error instead of garbling.
- **Mic capture no longer saturates** — removed a waveshaper that clipped
  speech peaks on healthy-level microphones (7–22% distortion) invisibly.
- **Ensemble image attachments** — attach images in the Ensemble composer
  with the same picker and drag-and-drop as Solo; the cast sees and reacts
  to them (Vision-capable models only).
- **Force-capability overrides apply immediately** — forced Reasoning /
  Vision / Tools no longer wait for a re-probe, and the Thinking toggle no
  longer vanishes when switching models.
- **Spoken numbers and symbols** — `45,607` and `$1,500` read correctly (they
  were spoken as two numbers); questions keep their rising tone through the
  sanitizer; stray joiners no longer swallow the letter before them; ™ is
  spoken.

## 1.5.10

- **Speak as any character** — a Speaking-as picker above the Ensemble
  composer lets you seed your own name from Cast & Settings, add aliases
  mid-chat, and switch between them (You stays the default).
- **Multi-Talk voice map** — before Open in Multi-Talk, map each human
  character to a stock or custom voice so your lines no longer collapse onto
  one default voice. Export tags follow per-turn speaker names.
- **Director's Chair** — a Direct badge marks transcript lines that honored a
  directive; Direct and Boot instructions land more reliably; Boot cuts the
  current speaker off cleanly without stalling the cast.
- **Connection honesty** — clearer connection errors, real load state, and
  the model loads automatically when you pick it.

## 1.5.9

Ensemble cast portability, the Director's Chair, and the Compact context
meter.

- **Cast export / import** — save a cast as JSON and load it later or on
  another Mac. Missing voices remap to a default; run settings are clamped to
  valid ranges; casts cap at 8.
- **Cast editing after creation** — add or remove roster members, edit scene
  and mood, and name your own character.
- **Director's Chair** — a glass overlay over the transcript with live run
  controls: turn order, Free vs Scene-first play, pace, limits, and
  include-me. **Boot** removes a speaker with an exit line and a scene beat.
  **Direct** hands one speaker a private instruction. **Compact** frees
  context without losing the on-screen transcript, with a fill ring showing
  how much of the loaded context is in use.
- **Invited user turns** — "Include me in turn order" gives you a 60 s window
  to jump in.
- **LM Studio connection accuracy** — the Connected pill and Test Connection
  only count loaded models; App Settings lists the full downloaded catalog
  and can load a model into LM Studio directly; friendly disconnect messages
  instead of raw JSON; a Get LM Studio badge when the app isn't installed.
- **Emoji stripped from speech and exports** — the on-screen transcript keeps
  them; TTS and Multi-Talk / Markdown export don't.
- Muting in Chat no longer leaves Single Voice or Multi-Talk silent.

## 1.5.8

- **Model capability badges** — the Chat toolbar shows what the active model
  supports (Vision, Tools, Reasoning), read live from LM Studio, with
  force-supported overrides in App Settings for servers that don't publish
  metadata.
- **Image attachments in Solo Chat** — attach via picker or drag-and-drop
  when the model supports Vision; previews in the composer and transcript; a
  failed send restores your exact draft and attachments.
- **Thinking controls** — turn reasoning on or off, or pick Low / Medium /
  High effort where the model supports it, in both Solo and Ensemble.
- **Per-prompt inference settings** — Temperature, Top P, Top K, Repeat
  Penalty, and optional Max Tokens saved with each system prompt.
- **Chat polish** — Apple-style bubbles, Markdown rendering, hover actions,
  transcript reset, response shimmer, a multiline composer, and audio mute.

## 1.5.7

- **App Store rating prompt** — asked at most once every four months, only
  after a week of use and a few successful syntheses, and never at launch or
  mid-task. Help ▸ "Rate Mimika on the App Store…" opens the listing any
  time.
- **Pocket ↔ Fish backend switching** — voice assignments reconcile in both
  directions instead of stranding pickers on a stale voice.
- **Script reuse keeps names straight** — History restores speaker names
  verbatim; Ensemble and Chat imports normalize to Speaker N with the voice
  carrying identity.
- **Edit personas before the conversation starts** — the pencil in Cast &
  Settings opens the persona editor any time before the first turn.
- Fixed the ~5 s lag switching from Chat to Multi-Talk, Format Script
  shrinking the font, black borders around sheets, and picker console
  warnings.

## 1.5.6

- **Reproducible takes** — pin a synthesis seed to an imported voice so a take
  you like can be regenerated exactly. Synthesize, like the result, tap
  "Assign seed?", and future generations reproduce it. Works across Single
  Voice, Multi-Talk, Chat, Ensemble, and Read Aloud.
- **Voice from video** — drop an .mp4 or .mov onto the Voice Manager; the app
  detects the speakers, previews each one, and turns the one you pick into a
  custom voice. No audio tooling needed.
- **Import queue hardening** — rapid back-to-back voice imports no longer
  leave voices half-encoded; opening the Voice Manager heals every incomplete
  voice at once; WAV-only orphans can be previewed and adopted.
- **Enhancement Studio fixes** — the "ready for synthesis" toast fires once,
  after Accept & Save; the Play B preview is faithful to the level slider; a
  new headroom meter shows how much of the audio is being limited at the
  current level.

## 1.5.5

Speaker Isolator accuracy + re-voice quality overhaul.

- **Speaker detection you can actually tune** — the Speaker Sensitivity
  slider's dead zone is gone (the full travel now does real work), a new
  "Re-detect speakers" button re-runs detection on the cached audio without
  repeating the slow separation step, phantom duplicate speakers are merged
  automatically, and "Number of Speakers" now genuinely merges the detected
  speakers down to the count you set.
- **Re-voiced speech tracks the original lips** — systematic lip-sync drift
  eliminated (measured ~2.3 s/min → ~0.1 s/min on a 3-speaker test clip, no
  word more than ~0.7 s off): word-aware segment caps, diarization
  end-padding recaptures trailing words, and an internal timing-QA pass
  measures every re-voice and automatically re-renders drifting takes.
- **Cleaner re-voiced audio** — the scratchy, robotic line starts under
  "Match original speaking pace" are fixed (onset-protected compression +
  improved WSOLA alignment); long sentences share their timing slack instead
  of clipping words at chunk boundaries; over-long synthesis takes are
  automatically re-rolled; segment ends are pulled back toward the original
  timing; and years/numbers are never split across synthesis boundaries
  ("nineteen eighty three" stays one utterance).

## 1.5.4

- **Ensemble Mode** (Chat → Ensemble) — you and multiple AI personas hold one
  shared, autonomous, voiced conversation. Cast written by a local LLM or by
  Claude (native structured outputs); Director / round-robin / weighted
  turn-taking with first-name mention addressing; per-speaker sampling presets
  shown as live per-turn badges; an agreement-collapse "grenade" to break a
  stale consensus; rolling-summary context; mic barge-in; export to
  Multi-Talk / History / Markdown.
- **Menu Bar & Read Aloud** — a menu-bar voice picker plus a system-wide
  "Read Selection Aloud" macOS Service: select text in any app, right-click →
  Services (or assign a keyboard shortcut), and Mimika reads it aloud with its
  warm on-device engine. Opt-in, resident menu bar with optional
  launch-at-login. No separate app, server, or Python.

## 1.5.3

- **Record reference audio with your microphone** — live level meter, count-up
  timer, 45-second cap, mono capture; no file needed.
- **Guided script** shown while you record for a better voice match.
- **Listen before you save**, with instant quality tips (too quiet, background
  noise, clipping…).
- Automatic input gain so you can record at a comfortable distance from the mic.

## 1.5.2

- **Rebrand to Mimika** — the app surface was renamed from "Pocket TTS" for
  App Store Guideline 5.2.5 compliance (dropping the "macOS" term and the
  upstream project name). The on-device TTS engine name is unchanged.
- **Audio follows the system default output** — fixed playback being silent
  through AirPods / headphones that became the default output after launch.
  The engine now binds to the current default output device and re-routes
  live when you switch outputs.
- **Fixed an audio-engine priority inversion** around playback teardown — all
  blocking AVAudioEngine lifecycle calls now run on a dedicated serial queue
  at matched QoS, clearing the Thread Performance Checker "Hang Risk".

## 1.5.1

- Fix sidebar layout clipping on short windows.
