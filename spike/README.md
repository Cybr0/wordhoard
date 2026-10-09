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
- `WordhoardSpike/WordNetLookup.swift` — loads the bundled WordNet once and answers "which senses
  does this headword have" without the model. No `FoundationModels` import.
- `WordhoardSpike/Resources/oewn-2024.json` — the WordNet bundle (13.8 MB) and `OEWN-LICENSE.txt`.
- `tools/convert_oewn.py` — builds that bundle from the Open English WordNet release.

## Three modes (issues #4 and #11)

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

**WordNet + model** (issue #11): the sense *inventory* is where the on-device model fails (three
prompt iterations never produced *book → to reserve*; the verifier rejected both senses of *look up*),
while everything downstream of a correct sense is good. So the senses come from a dictionary and the
model only writes.

1. *Lookup, no model call.* `WordNetLookup` returns the headword's senses from the bundled Open
   English WordNet 2024: part of speech, gloss, synonyms (other members of the synset) and antonyms,
   in WordNet sense order. The card shows the top 3: round-robin over parts of speech in noun, verb,
   adjective, adverb order (for *book*: noun 1, verb 1, noun 2). The log line says how many senses the
   bundle has for the word and which were kept. No verification call — WordNet is authoritative.
2. *One writing call per sense.* Prompt: the word, part of speech, gloss and synonyms; the model
   returns `SenseWriting { learnerDefinition, translation }` — a one-sentence learner-friendly
   rewrite of the gloss and the Russian translation of the word in that sense. Synonyms and antonyms
   on the card come from WordNet, never from this call. A failed writing call keeps the sense with
   the raw gloss as its definition.
3. *One neutral example per sense*, with the learner definition in the prompt — the card is on screen
   from this point ("time to first card").
4. *One example per (sense, topic)* in the background, as in split mode ("time to full card").

Calls for a word with 2 WordNet senses and 3 topics: 2 writing + 2 neutral = 4 calls to the first
card, then up to 2 × 3 = 6 topic calls, 10 in total. With 3 senses: 6 to the first card, then up
to 9. The timings line adds **Lookup** (the bundle lookup alone; the first one includes decoding the
bundle unless the launch-time warm-up has finished — 0.4 s on the iPhone 17 simulator, Debug build;
the console prints `WordNet: loaded …` with the time).

*Fallback.* When the headword is not in the bundle (`by the book`, `break the ice`, `asdfgh` from the
regression list) the log and the screen say `WordNet: "<word>" not found → model-only senses call`
and the split flow above runs unchanged, including its verification toggle. The card marks every
sense with its source: `Sense 1 — verb [wordnet]` or `[model]`; WordNet senses also show the gloss
the definition was written from. There is no image prompt in WordNet mode.

*Known limits of the bundle* (for ADR 0001): WordNet has no prepositions or other function words
(*despite* is found, but only as an archaic noun, "contemptuous disregard" — the model-only path
would be right here); no recent senses (*gaslight* is a noun only, the lamp); only one sense of *look
up* ("seek information from" — the literal "raise one's eyes" is not an entry); no idioms beyond its
own list (*by the book*, *break the ice* are missing); and the sense order is WordNet's, which puts
*book* → "engage for a performance" before "reserve" (SemCor counts 3 vs 1), so *reserve* is verb
sense 2 and outside the top 3 as long as the cut is three senses in total.

### The WordNet bundle

`WordhoardSpike/Resources/oewn-2024.json`, 13.8 MB (14 494 184 bytes), plain JSON with no
whitespace: a `synsets` array (`[gloss]` or `[gloss, [member lemma, …]]`, the index is the synset
id) and a `lemmas` map from the lowercased lemma (multi-word lemmas with spaces: `look up`) to its
senses per part of speech (`n`, `v`, `a`, `r`), each sense an int synset index or
`[index, [antonym, …]]`. Only the top 3 senses per part of speech are kept (the card never shows more
than 3 in total), which drops 15k of 212k senses and 6k of 121k synsets; satellite adjectives are
folded into `a`; examples, pronunciations, ILI and all other relations are stripped. The full
dump would be 16.7 MB. SemCor tag counts are not in the LMF release, so sense order within a part of
speech is the `<Sense>` element order of the entry, which is WordNet's own ranking.

Source: Open English WordNet, 2024 edition, CC BY 4.0, derived from Princeton WordNet
(https://github.com/globalwordnet/english-wordnet). Attribution is in
`WordhoardSpike/Resources/OEWN-LICENSE.txt`, which ships inside the app bundle.

To regenerate (the release is not committed; download it into an empty directory outside the
repo and treat it as untrusted input):

```
gh release download 2024-edition --repo globalwordnet/english-wordnet --pattern '*.xml.gz' --dir <dir>
python3 -I spike/tools/convert_oewn.py <dir>/english-wordnet-2024.xml.gz spike/WordhoardSpike/Resources/oewn-2024.json
python3 -I spike/tools/convert_oewn.py --check spike/WordhoardSpike/Resources/oewn-2024.json
```

The script is standard-library Python 3.9 (the system `python3`), takes about 5 s, and `--check`
prints, for the 22 words of `docs/regression-words.md`, whether the lemma is found and the top 3
senses with the same selection policy as `WordNetLookup`.

### Timings on screen (also printed to the console)

- **Lookup** — WordNet mode only: the bundle lookup.
- **Senses** — split mode: the senses call alone. WordNet mode: lookup plus the writing calls, i.e.
  the moment every sense has a definition and translation.
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

For #11, run regression words 1–5 (**book**, **run**, **light**, **set**, **apple**) in "WordNet +
model" and compare the learner definitions, translations and timings with split mode; then
**look up** and **give up** (multi-word entries), **gaslight** (noun only in WordNet) and
**by the book** (not in WordNet → fallback, check the log line).

## Build check without a device

```
xcodebuild -project spike/WordhoardSpike.xcodeproj -scheme WordhoardSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build
```
