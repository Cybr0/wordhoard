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

1. *Senses call.* One `LanguageModelSession`, returns `headword`, 1–3 senses
   (`partOfSpeech`, `definition`, `translation`, `synonyms`, `antonyms`) and `imagePrompt`.
   No examples. The instructions say most words have one or two senses, that only senses a learner's
   dictionary would list count, that the list must not be padded with paraphrases or inventions, and
   that every common part of speech is covered; two worked examples (*run* with three senses,
   *nevertheless* with one) show the shape. The first device run showed the model fills `.count(1...3)`
   regardless, which is why step 2 exists.
2. *Verification, one yes/no call per sense.* "Is the English word "however" commonly used as a noun
   meaning "a confusing or unclear situation"? Answer yes or no." The answer is a `@Generable` with a
   single `Bool` (`SenseVerdict.isCommonlyUsed`), so guided generation pins the model to a JSON
   boolean and nothing has to be parsed. Senses that get "no" are dropped before any example is
   written for them; the raw log records each verdict. A verification call that *fails* keeps its
   sense. If every sense is rejected, sense 1 is kept and an orange note on screen says so, rather
   than showing an empty card. The "Verify each sense" toggle (default on) switches this step off so
   its cost can be measured.
3. *One neutral example per sense.* Each example is a fresh session with a short prompt
   ("Write one natural English sentence (6–14 words) using "book" as a verb in the sense "…".")
   returning `{ text }`. The card is on screen from this point. The neutral example is mandatory.
4. *One example per (sense, topic)*, in the background, appended to the card as each arrives. The
   prompt names the topic and gives its one-line description; the topic tag is assigned by the caller,
   never classified by the model, so the mis-tagging seen in the first device run cannot recur.
   Topic examples are optional: the prompt says "If this sense cannot be used naturally in this
   grammar, return an empty string", and an empty answer gets no slot on the card (the raw log says
   "skipped"). This avoids forced sentences like a passive of an intransitive sense.

Calls for a 2-sense word with 3 topics: 1 senses + 2 verify + 2 neutral = 5 calls to the first card,
then up to 2 × 3 = 6 topic calls, 11 in total (9 with verification off). Verification calls run one
after another. Example calls run one after another by default; the "Parallel example calls" toggle
runs three at a time (one session per call — a `LanguageModelSession` must not be used concurrently)
so the device run can tell whether concurrent sessions help or just contend for the model.

There is no pronunciation field in either mode: the model's IPA was wrong on the device run
(`/ˈhʌvər/` for *however*), which settled `requirements.md` §10 Q6 — pronunciation will come from
`AVSpeechSynthesizer`, not from the language model.

**Single call**: the PR #9 shape, one big call for the whole card (now with the same three topics).
Kept for comparison only — it overflowed the 4096-token context on "however".

### Timings on screen (also printed to the console)

- **Senses** — the senses call alone.
- **First card** — senses, verification (when on) and one neutral example per sense; what a user
  would wait for.
- **Full card** — every topic example has arrived. In single-call mode first and full are the same.

The raw JSON of every call, with its own duration, is listed under the card and printed. The call
count on screen includes verification calls; skipped topic examples still count as calls.

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
misbehaved with the single call) and note senses, first-card and full-card times for #4, once with
verification on and once off. Then do the full `docs/regression-words.md` run for #2.

## Build check without a device

```
xcodebuild -project spike/WordhoardSpike.xcodeproj -scheme WordhoardSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build
```
