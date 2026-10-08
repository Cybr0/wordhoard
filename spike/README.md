# Wordhoard spike (Phase 0)

Throwaway app that answers `docs/requirements.md` §10 Q1: can the on-device Foundation Models
language model produce a usable vocabulary card? One screen: a text field, a Generate button,
the model availability line, a mode picker, timings, the decoded card and the raw output.

Not held to the root `CLAUDE.md` conventions (no `WordhoardCore`, no tests, `print` is fine).
Nothing here is meant to survive into the real app except the lessons.

## Layout

- `project.yml` — XcodeGen spec. Regenerate with `cd spike && xcodegen generate`.
- `WordhoardSpike/CardGeneration.swift` — instructions, prompts, `@Generable` types and the
  individual model calls for both modes. Everything the model sees is in this one file; iterate here.
- `WordhoardSpike/CardGenerationModel.swift` — the `@MainActor @Observable` orchestrator: runs the
  calls, keeps the on-screen card, records timings, cancels the previous run when a new word is typed.
- `WordhoardSpike/ContentView.swift` — the screen.

## Two modes (issue #4)

**Split calls** (default, the one to measure):

1. *Senses call.* One `LanguageModelSession`, returns `headword`, `pronunciation`, 1–3 senses
   (`partOfSpeech`, `definition`, `translation`, `synonyms`, `antonyms`) and `imagePrompt`.
   No examples. Instructions insist that senses differ in meaning and that a word used as both noun
   and verb gets one sense of each. Pronunciation and image prompt stayed in this call because the
   senses-only schema is small (a few hundred tokens); if they turn out to push the context, move them
   to a separate tiny call.
2. *One neutral example per sense.* Each example is a fresh session with a short prompt
   ("Write one natural English sentence (6–14 words) using "book" as a verb in the sense "…".")
   returning `{ text }`. The card is on screen from this point.
3. *One example per (sense, topic)*, in the background, appended to the card as each arrives. The
   prompt names the topic and gives its one-line description; the topic tag is assigned by the caller,
   never classified by the model, so the mis-tagging seen in the first device run cannot recur.

Calls for a 2-sense word with 3 topics: 1 + 2 + 2 × 3 = 9. Example calls run one after another by
default; the "Parallel example calls" toggle runs three at a time (one session per call — a
`LanguageModelSession` must not be used concurrently) so the device run can tell whether concurrent
sessions help or just contend for the model.

**Single call**: the PR #9 shape, one big call for the whole card (now with the same three topics).
Kept for comparison only — it overflowed the 4096-token context on "however".

### Timings on screen (also printed to the console)

- **Senses** — the senses call alone.
- **First card** — senses plus one neutral example per sense; what a user would wait for.
- **Full card** — every topic example has arrived. In single-call mode first and full are the same.

The raw JSON of every call, with its own duration, is listed under the card and printed.

## Default grammar topics

`en.present_perfect`, `en.second_conditional`, `en.passive_voice` — per `docs/regression-words.md`.
Each has a name and a one-line description in `GrammarTopic.active`; the description goes into the
example prompt.

## Run on a device

The simulator usually reports the model as unavailable (`deviceNotEligible` or
`appleIntelligenceNotEnabled`), so use a real iPhone with Apple Intelligence.

1. On the phone: Settings → Apple Intelligence & Siri → turn on Apple Intelligence, wait for the
   model download to finish. Device language should be English.
2. `open spike/WordhoardSpike.xcodeproj`.
3. Select the `WordhoardSpike` target → Signing & Capabilities → Team: pick your personal
   (free) team. The team is intentionally not committed in `project.yml`; do not commit the
   `DEVELOPMENT_TEAM` Xcode writes into the `.xcodeproj`.
4. Select the phone as the run destination and run.
5. Type a word, tap Generate. The card fills in as calls complete; the timings line updates; the raw
   JSON of each call appears below the card and in the Xcode console.

Re-run **book**, **however** and **look up** first in split mode (these are the words that failed or
misbehaved with the single call) and note senses, first-card and full-card times for #4. Then do the
full `docs/regression-words.md` run for #2.

## Build check without a device

```
xcodebuild -project spike/WordhoardSpike.xcodeproj -scheme WordhoardSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build
```
