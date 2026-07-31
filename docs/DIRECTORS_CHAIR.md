# Director’s Chair — design capture

Living design notes for the Ensemble mid-run control surface. Update when
shipping Boot / User turn / Context dump.

---

## Shipped

### Chair chrome (v1 → glass overlay pass)

- Toolbar: `chair.lounge.fill` to the right of Thinking (Ensemble only).
- Toggle expands a **floating glass card** over the transcript (ZStack overlay),
  not a layout-pushing full-width strip.
- Collapse: chair again, or chevron in the panel.
- Hosts all **Run Settings** (turn order, randomness, scene play, pace, max
  turns, context window, speak aloud, rolling summary).
- Cast & Settings keeps scene/mood + roster/voices only.

### Scene play

- `Scene-first` (default) / `Free` — see `ScenePlayMode` + `framedSystemPrompt`.

---

## Planned order

1. **Director’s Chair chrome** (glass overlay) — shipped  
2. **Boot** (2A) — shipped (MVP)  
3. **Context soft-dump** (2C) — shipped (MVP); Reset icon under Boot  
4. **User turn** (2B) — shipped (MVP)  

---

## 2A — Boot (shipped MVP)

**Intent:** Director removes a cast member mid-scene with a reason the table can hear.

**UI (Chair):**

- Orange `figure.kickboxing` on the right of the glass card.
- Tap → picker + reason field + Send.
- Disabled when only one speaker remains or a boot is already armed.

**Runtime:**

1. `pendingBoot` forces that speaker **next**.
2. BOOT PROTOCOL on their system prompt → one exit line in character.
3. After the turn: remove from cast; `lastDepartureNote` injected into
   everyone else's framing (public fact, not private persona).
4. Notice: “Booted {name}”.

**Not v1:** add-character mid-run; multi-boot queue.

---

## 2B — User turn — shipped MVP

**Intent:** User is a peer who can be *tapped* to speak next (not only barge-in).

**Prereqs:**

- Real character name in Cast & Settings (**YOU**) or New Cast wizard.
- Chair toggle: **Include me in turn order**.

**Runtime:**

- Synthetic `userTurnSpeakerID` in `effectiveCastForTurnOrder()` for pick only.
- Conductor/Director may select the human; loop awaits submit or 25s timeout.
- Banner above composer + system beep + toast.
- Timeout skips (notice); empty submit doesn’t complete invited wait.
- Barge-in mic during invite only opens dictation; finish/submit completes wait.

---

## 2C — Context dump (soft) — shipped MVP

**Intent:** Reset app-side request context when small models loop/degrade —
not LM Studio’s UI clear, same *effect* on next request size.

**UI:** Director’s Chair → **Reset context** (with info.circle).

**Runtime (`softDumpContext`):**

- Does **not** delete `turns` (transcript / Multi-Talk / Markdown stay full).
- Cancels in-flight rolling summarizer.
- Keeps last `verbatimWindow` turns model-facing (`summarizedUpTo` advanced).
- Folds older turns into a short non-LLM brief (scene, mood, cast, recent lines).
- Notice + app toast: how many turns models still see.

**Not v1:** hard wipe of transcript; per-agent dump.

---

## Non-goals (for now)

- Moving persona/voice editors into the Chair.
- Content filters / NSFW blocks via Boot.
- Sharing private persona scripts between agents.
