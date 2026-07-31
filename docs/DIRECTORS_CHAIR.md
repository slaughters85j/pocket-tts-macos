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
3. **Direct** (megaphone) — shipped (MVP)  
4. **Context Compact** (2C) — shipped; Compact icon under Boot + fill %  
5. **User turn** (2B) — shipped (MVP)  

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

## Direct (shipped MVP)

**Intent:** Private, cast-specific director note — steer a tangent, ban a
phrase, demand a beat — without removing them (unlike Boot) and without a
generic chaos bomb (unlike Grenade).

**UI (Chair):**

- Orange `megaphone.fill` between Boot and Compact.
- Tap → picker + free-text instruction + Send (same layout as Boot).
- Disabled while a direction is already armed; instruction required (non-empty).
- Only one of Boot / Direct composers open at a time.

**Runtime:**

1. `pendingDirective` forces that speaker **next** (Boot still wins if both armed).
2. DIRECTOR DIRECTIVE on their system prompt — follow the note; one short line;
   never mention the director.
3. Sampling forced to **Strict** (temp / top-p / top-k) for that turn only;
   transcript badge shows Strict.
4. Cleared after a successful directed line (retries on empty/fail).
5. Notice: “Direction armed — {name}”.

**Not v1:** multi-directive queue; sticky multi-turn notes; public table announcement.

---

## 2B — User turn — shipped MVP

**Intent:** User is a peer who can be *tapped* to speak next (not only barge-in).

**Prereqs:**

- Real character name in Cast & Settings (**YOU**) or New Cast wizard.
- Chair toggle: **Include me in turn order**.

**Runtime:**

- Synthetic `userTurnSpeakerID` in `effectiveCastForTurnOrder()` for pick only.
- Conductor/Director may select the human; loop awaits submit or **60s** timeout
  with a live countdown on the composer banner.
- Banner above composer + system beep + toast.
- Timeout skips (notice); empty submit doesn’t complete invited wait.
- Barge-in mic during invite only opens dictation; finish/submit completes wait
  and always resets the mic to idle (avoids sticky `.unavailable`).

---

## 2C — Context Compact — shipped

**Intent:** Compact model-facing context when small models loop/degrade —
not LM Studio’s UI clear, same *effect* on next request size.

**UI:** Director’s Chair → **Compact** icon under Direct, with **~N%** fill
(Qwen reference tokenizer vs loaded context length). Color: orange → amber ≥75%
→ red ≥90%. Toast at ≥90%: “Compact recommended”.

**Runtime (`compactContext` / `softDumpContext`):**

- Does **not** delete `turns` (transcript / Multi-Talk / Markdown stay full).
- Cancels in-flight rolling summarizer.
- Keeps last `verbatimWindow` turns model-facing (`summarizedUpTo` advanced).
- Folds older turns into a short non-LLM brief (scene, mood, cast, recent lines).
- Top-of-window toast only.

**Tokenizer:** vendored `Resources/tokenizers/qwen3/tokenizer.json` (from
froggeric Qwen3.5 MLX layout). Denominator from LM Studio `context_length` /
`max_context_length` when available, else tokenizer `model_max_length`.

**Not v1:** hard wipe of transcript; per-agent dump; exact per-model tokenizer.

---

## Non-goals (for now)

- Moving persona/voice editors into the Chair.
- Content filters / NSFW blocks via Boot.
- Sharing private persona scripts between agents.
