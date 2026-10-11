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
- `WordhoardSpike/SpikeTranslator.swift` — English → Russian through Apple's Translation framework
  (WordNet mode only). No `FoundationModels` import.
- `WordhoardSpike/PCCStatus.swift` — issue #15: `ModelBackend`, the launch-time Private Cloud
  Compute probe (availability, context size, languages, quota), the PCC request counter and the
  error describer that names PCC / iOS 27 `LanguageModelError` cases.
- `WordhoardSpike/Resources/oewn-2024.json` — the WordNet bundle (14.8 MB) and `OEWN-LICENSE.txt`.
- `WordhoardSpike/Resources/function-words.txt` — the closed-class stoplist; these words are always
  model-only.
- `tools/convert_oewn.py` — builds that bundle from the Open English WordNet release.

## Four modes (issues #4, #11 and #15)

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
   English WordNet 2024: part of speech, gloss, synonyms (other members of the synset), antonyms and
   the synset's example sentence, in WordNet sense order. The card shows **up to 2 senses per part of speech**, nouns first, then
   verbs, adjectives, adverbs (for *book*: noun, noun, verb *engage for a performance*, verb *reserve*).
   Missing a real sense costs more than showing a spare one — the user can delete a sense but will
   not know to add one (issue #11, decision 1). The log line says how many senses the bundle has for
   the word and which were kept. No verification call — WordNet is authoritative. When WordNet knows
   the lemma, the senses come **only** from WordNet: the model-only senses call never runs for it and
   the model never adds a sense (that would reopen hallucination). Gaps are filled by manual sense
   editing in the real app (requirements W2) — e.g. *look up* has one WordNet sense, "seek information
   from"; the compositional "raise one's eyes" is not a lexical entry and is not added (issue #11,
   decision 2).
2. *One writing call per sense.* Prompt: the word, part of speech, gloss, synonyms and the WordNet
   example sentence of the synset (it may use a synonym rather than the headword); the model returns
   `SenseWriting { learnerDefinition }` — a one-sentence learner-friendly rewrite of the gloss. The
   example and synonyms are there because the gloss alone was misread on the first device run
   ("engage for a performance" became *rehearse*). Synonyms and antonyms on the card come from
   WordNet, never from this call, and **the model does not translate in this mode** (see 3). A failed
   writing call (including a guardrail refusal, seen for *gaslight*) keeps the sense with the raw
   gloss as its definition.
3. *Translation, no model call.* The first device run showed the model's Russian is unreliable to
   the point of non-words ("ночальница" for *however*), which settled issue #3 early. In WordNet mode
   the learner definition of every sense and every WordNet synonym go through Apple's on-device
   **Translation framework** instead (`SpikeTranslator`): `LanguageAvailability().status(from: en,
   to: ru)` is checked first; only `.installed` proceeds, with a `TranslationSession(installedSource:
   target:)` (iOS 26) created and used inside one nonisolated function — `TranslationSession` is not
   `Sendable`, so it never crosses an isolation boundary. One `translations(from:)` batch per sense
   (definition + synonyms); a failed batch is logged and skipped. Translated synonyms appear next to
   the originals on the card (`volume → том`). If the pack is missing the log and the screen say
   `Translation: en→ru language pack not installed → no translation` and the card shows `—`; the
   model is **never** used as a fallback for translation. The split and single modes keep the
   model's translation, which the readable card marks `[model]`; only the WordNet mode uses the
   framework in the spike.
4. *One neutral example per sense*, with the learner definition in the prompt — the card is on screen
   from this point ("time to first card").
5. *One example per (sense, topic)* in the background, as in split mode ("time to full card").

Model calls for a word with 2 WordNet senses and 3 topics: 2 writing + 2 neutral = 4 calls to the
first card, then up to 2 × 3 = 6 topic calls, 10 in total. With 4 senses (*book*): 8 to the first
card, then up to 12. Translation framework calls are not model calls and are not in the call count.
The timings line adds **Lookup** (the bundle lookup alone; the first one includes decoding the
bundle unless the launch-time warm-up has finished — 0.4 s on the iPhone 17 simulator, Debug build;
the console prints `WordNet: loaded …` with the time) and **Translation** (the framework calls alone).

*Fallback, two triggers (issue #11, decision 3).* **Function words:** before the lookup, the headword
is checked against `Resources/function-words.txt`, a closed-class stoplist of about 385 lemmas —
determiners, pronouns, prepositions, conjunctions, auxiliaries and modals, discourse adverbs and
connectives (*however*, *despite*, *although*, *nevertheless*, *moreover*, *therefore*, *whereas*,
*unless*, …). WordNet is useless or misleading for these (no prepositions at all, *despite* only as an
archaic noun) while the model-only senses call handled *however* perfectly, so they never reach the
bundle: the log and the screen say `WordNet: "<word>" is a function word → model-only senses call`.
The file is one lowercase lemma per line, `#` comments allowed, matched against the normalised
headword; `--check` applies it too when it sits next to the bundle. **Not in the bundle:** `by the
book`, `break the ice`, `asdfgh` from the regression list give `WordNet: "<word>" not found →
model-only senses call`. In both cases the split flow above runs, including its verification toggle,
with one difference — the **unknown-word policy** (issue #11, decision 6): when the verifier is on
and rejects *every* model sense, the card is not shown at all; the screen and log say `Not found. Add
senses manually.` instead of displaying the invented sense (the first device run showed *asdfgh*
with an invented sense the verifier had already said no to). With the verifier off the model's
senses are shown as they are, as before. WordNet-sourced senses are never verified.
Recent senses missing from WordNet (*gaslight* as a verb) are **not** a trigger: the noun sense is
shown and the user adds the verb manually — accepted limitation for v1. The card marks every
sense with its source: `Sense 1 — verb [wordnet]` or `[model]`; WordNet senses also show the gloss
the definition was written from. There is no image prompt in WordNet mode.

*Known limits of the bundle* (for ADR 0001): WordNet has no prepositions or other function words
(*despite* is found, but only as an archaic noun, "contemptuous disregard" — hence the stoplist
above); no recent senses (*gaslight* is a noun only, the lamp); only one sense of *look
up* ("seek information from" — the literal "raise one's eyes" is compositional, not an entry, and
that one sense is the accepted result); no idioms beyond its
own list (*by the book*, *break the ice* are missing); and the sense order is WordNet's, which puts
*book* → "engage for a performance" before "reserve" (SemCor counts 3 vs 1) — *reserve* is verb
sense 2, which is why the cut is two per part of speech rather than three in total.

**PCC + model** (issue #15, a probe — no prompt tuning): the same prompts and `@Generable` types
sent to Apple's server model, `PrivateCloudComputeLanguageModel` (iOS 27; 32K context; reasoning
levels). Every model call in the spike goes through one `respond(backend:…)` helper in
`CardGeneration.swift`; with `ModelBackend.privateCloudCompute` it creates the session as
`LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions:)` and passes
`ContextOptions(reasoningLevel: .light)` (the constant `pccReasoningLevel`; the launch log and each
`[pcc, reasoning: light]` console line say which level ran). The on-device backend is untouched: it
still uses the iOS 26 `respond` overload with no context options. The mode is guarded by
`#available(iOS 27, *)`; the deployment target stays iOS 26.0, where the "PCC" segment can be
selected but shows `PCC: requires iOS 27 — this mode is disabled` and Generate stays disabled.
Two variants, chosen by the **"PCC alone (single call, no WordNet)"** toggle that appears only in
this mode:

- *(a) WordNet + PCC* (toggle off, default): exactly the WordNet + model pipeline above — bundle
  lookup → one PCC writing call per sense → Translation framework → one neutral PCC example per
  sense → one PCC example per (sense, topic). Same stoplist and not-found fallback, with the
  fallback senses call and its verifier also on PCC (the log says `→ PCC-only senses call`).
- *(b) PCC alone* (toggle on): the "Single call" `GeneratedCard` on PCC — one request for the whole
  card including the model's own senses, Russian and examples; no WordNet, no Translation
  framework. The on-device single call overflowed the 4K context on *however*; PCC has 32K. The
  guides on `GeneratedCard` were already `senses` 1…4 and `examples` 1…4 per sense (one neutral
  plus one per active topic), which equals the limits the issue suggests for the larger context,
  so nothing was widened and the on-device single call is unchanged. The *only* differences from
  "Single call" are the backend and the reasoning level.

The card marks the provenance: `Backend: pcc` on the first line; model senses that came from PCC
are `[pcc]` (translation tag `[pcc]` too); WordNet senses written by PCC read
`[wordnet, definition by pcc]`. Timings (`First card`, `Full card`), the call count and the raw
JSON log work as in the other modes, plus a line `PCC requests this run: N · since launch: M`
(requests are counted *before* each call, so failed ones count) and a purple
`PCC: quota after <stage> …` line with `quotaUsage` after every batch (senses call, verification,
writing calls, neutral examples, topic examples, end of run); the same lines go to the raw log and
the console.

*Launch log* (console and the collapsible **PCC status** section at the top of the screen; tap the
cloud line to expand). On iOS 27 the lines to look for are:

```
PCC: availability = available | unavailable(deviceNotEligible) | unavailable(systemNotReady) | unavailable(unknown case: …)
PCC: isAvailable = true|false
PCC: capabilities: guidedGeneration=…, reasoning=…, toolCalling=…, vision=…
PCC: contextSize = 32768 tokens              (or "contextSize failed: <error case>")
PCC: supportedLanguages = 24: da, de, en, …  (count + the first eight identifiers)
PCC: supportsLocale(en_US) = true
PCC: quotaUsage at launch: status=belowLimit(isApproachingLimit: false) | status=limitReached, isLimitReached=…, resetDate=…, limitIncreaseSuggestion=nil|present
PCC: generation uses ContextOptions(reasoningLevel: .light); …
PCC: quota sheet API: PrivateCloudComputeLanguageModel.QuotaUsage.LimitIncreaseSuggestion.show() (not wired in the spike)
```

On iOS 26 the only line is `PCC: requires iOS 27`. "Re-read availability and quota" in the status
section re-reads both without relaunching. The system upgrade sheet is
`quotaUsage.limitIncreaseSuggestion?.show()` — it is logged as nil/present but no button is wired.

*Errors.* A failing PCC call is logged by case name in the raw log and the console:
`PCC Error.networkFailure | .quotaLimitReached (resetDate, limitIncreaseSuggestion) | .serviceUnavailable`,
and the iOS 27 `LanguageModelError` cases `contextSizeExceeded (contextSize, tokenCount) |
rateLimited (resetDate) | guardrailViolation | refusal | unsupportedCapability |
unsupportedTranscriptContent | unsupportedGenerationGuide | unsupportedLanguageOrLocale | timeout`.
Anything else prints its Swift type and `NSError` domain/code. On-device calls keep their previous
handling (`GenerationError` text unchanged). A failed writing call keeps the gloss, a failed example
shows `⚠︎ failed`, exactly as in WordNet mode.

*Headless probe.* `-pccProbeWord <word>` (plus `-pccProbeVariant a|b`, default `a`) as launch
arguments make the app select PCC mode and generate that word right after the launch probe,
printing everything; useful from `xcrun simctl launch --console-pty <udid> dev.wordhoard.spike
-pccProbeWord book -pccProbeVariant b` or an Xcode scheme. It is skipped (with a log line) when
PCC is unavailable.

*What the iOS 27.0 simulator does* (Xcode 27.0, iPhone 17, host macOS 26): it reports
`availability = available`, `contextSize = 32768`, 24 languages and `belowLimit`, but every request
fails instantly with `SystemLanguageModel.Error.assetsUnavailable: Host is not running macOS 27.`
(the on-device error type, thrown from a PCC session) — the simulator proxies PCC through the Mac
and needs a macOS 27 host. So availability on the simulator says nothing about a real device, and a
run there shows the failure path only (gloss kept, `⚠︎ failed` examples, request count still
incremented).

*Entitlement.* The iOS 27.0 SDK has no public entitlement key for PCC: nothing in the
`FoundationModels` swiftinterface, the cross-import overlays, the SDK `Entitlements.plist`, or
Xcode's capability specs mentions private cloud compute; the only entitlement-related symbol in
`FoundationModels.tbd` is the SPI `AgentDefinition_V1.entitlementsRequired`, not in the public
interface. The spike deliberately ships no entitlements file: the device run is the test of what
happens on a free personal team without the managed entitlement.

### The WordNet bundle

`WordhoardSpike/Resources/oewn-2024.json`, 14.8 MB (15 492 477 bytes), plain JSON with no
whitespace: a `synsets` array (`[gloss]`, `[gloss, [member lemma, …]]` or
`[gloss, [members], [example, …]]`, the index is the synset id) and a `lemmas` map from the
lowercased lemma (multi-word lemmas with spaces: `look up`) to its senses per part of speech (`n`,
`v`, `a`, `r`), each sense an int synset index or `[index, [antonym, …]]`. Only the top 2 senses per
part of speech are kept (the card shows every kept sense), which drops 25k of 212k senses and 10k of
121k synsets; satellite adjectives are folded into `a`; the first example sentence of each synset is
kept (28k examples — two per synset made the bundle 15.1 MB, over the 15 MB target, one keeps it
under); further examples, pronunciations, ILI and all other relations are stripped. Without examples
the same bundle was 13.5 MB; with three senses per part of speech and no examples, 13.8 MB. SemCor tag counts are not in the LMF release, so sense order within a part of
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
prints, for the 22 words of `docs/regression-words.md`, whether the lemma is found and the senses
the card shows, with the same selection policy as `WordNetLookup`.

### Timings on screen (also printed to the console)

- **Lookup** — WordNet mode only: the bundle lookup.
- **Senses** — split mode: the senses call alone. WordNet mode: lookup plus the writing calls, i.e.
  the moment every sense has its learner definition.
- **Translation** — WordNet mode only: the Translation framework calls for the definitions and
  synonyms (en→ru). Absent when the language pack is not installed.
- **First card** — senses, verification (when on), translation (WordNet mode) and one neutral example
  per sense; what a user would wait for.
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
   For translations in WordNet mode, also download **English** and **Russian** in the Translate app
   (or Settings → Apps → Translate → Downloaded Languages); otherwise the app logs
   `Translation: en→ru language pack not installed → no translation` and shows the card without
   Russian. The simulator normally has no language packs.
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
**look up** and **give up** (multi-word entries), **gaslight** (noun only in WordNet),
**however** and **despite** (function words → model-only, check the log line) and **by the book**
(not in WordNet → fallback, check the log line).

### PCC probe on a device (issue #15)

Prerequisites: an iPhone with Apple Intelligence running **iOS 27** (the author's iPhone 15 Pro
Max), Apple Intelligence on, a network connection (Wi-Fi), the app signed with the **free personal
team** as in step 3 above and **no** PCC entitlement (none is in the project). For variant (a)
translations, the en/ru Translate packs as in step 1.

1. Build and run on the phone; expand **PCC status** at the top (or read the Xcode console).
   Record every `PCC:` launch line: the availability case, `contextSize`, the
   `supportedLanguages` count, and `quotaUsage at launch`.
2. If availability is `unavailable(…)`: record the case (`deviceNotEligible` / `systemNotReady` /
   other) and stop — that is the answer to the issue's third criterion. Try once more after
   toggling Wi-Fi and after a few minutes (`Re-read availability and quota`) in case it is
   `systemNotReady`.
3. If `available`: select **PCC**, leave "PCC alone" **off** (variant a) and run the 22 words of
   `docs/regression-words.md` in order. Per word note: `First card` / `Full card` seconds, the
   number of senses, any `FAILED` / error-case line, and the pass/fail of the four key checks —
   **book** shows a verb sense meaning *reserve* with a definition about reserving; **look up**
   shows one sense (*seek information*); **however** goes `is a function word → PCC-only senses
   call` and ends with exactly one adverb sense; **asdfgh** ends in `Not found. Add senses
   manually.` with no sense displayed. After the run note `PCC requests … since launch` and the
   last `PCC: quota after run` line.
4. Switch "PCC alone" **on** (variant b) and repeat the 22 words. Same per-word notes; here the
   senses and the Russian come from PCC, so also note whether the Russian is real (the on-device
   model produced non-words) and whether *however* still overflows (it should not with 32K).
5. Paste the two tables, the launch lines, the total request count and the final quota status into
   issue #15 in the scorecard shape of #14. The first `PCC Error.quotaLimitReached` or
   `isApproachingLimit: true` is worth noting with the request number it appeared at.

The whole regression list is about 22 × (≈10–20 calls) ≈ 300 requests for (a) plus 22 for (b);
if the daily quota is hit, the log says so (`quotaLimitReached`, `resetDate`) and the remaining
words can wait for the reset.

## Build check without a device

```
xcodebuild -project spike/WordhoardSpike.xcodeproj -scheme WordhoardSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build
```
