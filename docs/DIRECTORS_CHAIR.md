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
3. **Context soft-dump** (2C)  
4. **User turn** (2B)  

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

## 2B — User turn

**Intent:** User is a peer who can be *tapped* to speak next (not only barge-in).

**Prereqs:**

- User must have a **real character name** (not default “You” / “Guest”).
- **User peer name** is editable in Cast & Settings (**YOU** section) and in
  the New Cast wizard.
- Checkbox in Director’s Chair: **Include me in turn order** (only enabled when
  name is set).

**Runtime:**

- Conductor/Director may select the human as next speaker.
- Loop parks in `.userTurn`; toast above composer (“You’re up”); optional tone.
- Timeout → skip / resume AI; never block forever.
- Complements barge-in; does not replace it.

---

## 2C — Context dump (soft)

**Intent:** Reset app-side request context when small models loop/degrade —
not LM Studio’s UI clear, same *effect* on next request size.

**Soft dump (preferred):**

- Keep scene + mood + last K turns (and optional short “state of play” brief).
- Clear or fold older transcript from the window / refresh rolling summary.
- Universal first; per-agent smaller window optional later.

**Hard dump** (full `turns` wipe) — usually too harsh; avoid as default.

---

## Non-goals (for now)

- Moving persona/voice editors into the Chair.
- Content filters / NSFW blocks via Boot.
- Sharing private persona scripts between agents.
