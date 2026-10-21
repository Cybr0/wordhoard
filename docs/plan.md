# Wordhoard — Implementation plan

Phased plan for v1 as defined in `requirements.md` §8. Each task gets a GitHub issue and one PR. Acceptance criteria here are the contract between the analyst, the developer and qa; they reference requirement IDs (C1, A4, …) from `requirements.md` §4.

Checkbox = merged to `main` with tests passing and qa sign-off.

---

## Phase 0 — Spike: does the on-device model deliver?

Code in a separate Xcode project (`spike/`), not held to project conventions. Goal: answer `requirements.md` §10 before committing to the architecture. Outcome: ADR 0001, verdict **adjust**. The spike is kept as the on-device regression runner (0.10), not as product code.

- [ ] **0.1 Minimal generator.** One screen, text field, button, `@Generable` card struct, raw output. Result: the single call overflowed the 4K context on *however* and mis-tagged grammar (#4). *(#1, PR #9)*
- [ ] **0.2 Regression word list.** Superseded by the automated runner in 0.10: the full 22-word list was run six times on device under #14 and the results are in `docs/regression-words.md` "Known results" and ADR 0001 appendix A/B. Close #2 against #14. *(#2 → #14)*
- [ ] **0.3 Translation check.** Settled by the #11 device run without a side-by-side table: the model's Russian contained non-words ("ночальница", "нечаростно"), so the Translation framework is the only translation path (A9); #14 then showed bare-word framework translation is wrong for synonyms and phrasal headwords. Record: ADR 0001 appendix C, requirements §11. *(#3, settled by #11/#14)*
- [ ] **0.4 Latency.** Done: a full single-call card took 26.8 s and the design was split into senses-first plus one example per sense and topic (PRs #10/#12); the runner then measured first card 7.6–9.9 s median, full card 12.5–14.3 s median and 35–43 s for 3–4-sense words. Record: ADR 0001 appendix A/D. *(#4, measured by #14)*
- [ ] **0.5 Image Playground check.** **Not done in Phase 0.** Moves to Phase 4: task 4.2 starts with exactly #5's criteria (availability, 5 images, refusals, styles, recommendation on/opt-in/drop) before any product code. §10 Q4 stays open. *(#5, open)*
- [ ] **0.6 Siri check.** **Not done in Phase 0.** Moves to Phase 5: task 5.1 starts with #6's criteria (10 words with Russian Siri, 10 with English). §10 Q3 stays open. *(#6, open)*
- [ ] **0.7 Free signing check.** Partially answered: the on-device Foundation Models model works with a free personal team (every spike run); Private Cloud Compute needs a managed entitlement and a paid account (#15). Image Playground and App Intents remain to be checked in 4.2 and 5.1. *(#7, partial)*
- [ ] **0.8 ADR 0001.** Analyst writes the verdict and propagates adjustments into requirements and plan. *(#8)*
- [ ] **0.9 WordNet-first senses.** Bundle Open English WordNet 2024 (15 492 477 bytes, CC BY 4.0), 2 senses per part of speech, function-word stoplist, model-only fallback with verifier and "not found" state, Translation framework for translations. Result: no invented senses where the lemma is found. *(#11, PR #13)*
- [ ] **0.10 Regression runner and tuning loop.** `WordhoardSpikeRegression` test target runs the 22 words on device, mechanical checks plus a pre-filled judged table; five iterations, stop rule reached. Best commit `665d06d`: judged 10/12, mechanical 86.0 %. Decision B (SemCor ranking) reverted. *(#14, PR #17)*
- [ ] **0.11 Private Cloud Compute probe.** PCC mode in the spike; on device `availability` says `available` but the first request crashes without the entitlement. PR #16 stays open as the probe to re-run when the entitlement is granted. *(#15, PR #16 — not merged)*

**Exit criteria:** met by ADR 0001 (`docs/decisions/0001-spike-results.md`), verdict **adjust**. Adjustments: senses from bundled WordNet with a model-only fallback (A1); per-sense model calls instead of one card call, topic examples optional and in the background (A2); no model IPA (A3 dropped, W5); translations via the Translation framework only, per-sense equivalents verified by back-translation (A9, #22); PCC as an entitlement-gated tier (A10); About-screen attribution (S6); iOS 27 minimum; the spike kept as the prompt-regression tool. Images and Siri remain unvalidated and are checked first in 4.2 and 5.1.

---

## Phase 1 — Skeleton: a dictionary you can keep by hand

- [x] **1.1 Project setup.** `project.yml` → `Wordhoard` app target (iOS 27.0, iPhone only, portrait, `dev.wordhoard.app`) + local `WordhoardCore` package (Swift 6 language mode, Swift Testing) + `WordhoardUITests`; `.swiftformat`, `.swiftlint.yml`; GitHub Actions CI on PRs and pushes to `main` (lint, regenerate-and-diff the committed `.xcodeproj`, `swift test`, simulator build). App launches to an empty list: a `NavigationStack` titled "Wordhoard" with an empty-state view, strings in `Localizable.xcstrings`, no data layer yet (1.2/1.4). `spike/` stays outside the project, lint and CI. Detail in the issue. *(#24)*
  *AC:* on a clean clone `xcodegen generate` leaves `Wordhoard.xcodeproj` unchanged (`git diff --exit-code`) and `xcodebuild build` for an iOS 27 iPhone simulator succeeds; `cd WordhoardCore && swift test` passes ≥ 1 Swift Testing test; `xcodebuild test` runs the Core tests plus one UI smoke test that sees the empty state; `swiftformat --lint .` and `swiftlint --strict` report nothing; CI is green on the PR with all four steps.
- [ ] **1.2 Data model.** SwiftData models in `WordhoardCore` per `requirements.md` §5: `Word`, `Sense`, `Example`, `Tag`, `ImageAsset`, `UserSettings`, plus `ReviewEvent` in the schema but written by nothing. CloudKit-compatible shape: no `@Attribute(.unique)`, every property optional or defaulted, every relationship with an inverse and optional to-one ends, client-generated `UUID` ids, soft delete via `deletedAt`, `learningLanguage = "en"`, namespaced topic keys. String-backed enums: `PartOfSpeech` with exactly the eight §5 cases (`preposition` and `conjunction` from the start, ADR 0001; `determiner`/`pronoun` stay with 2.7), `SenseSource` (`wordnet`, `model`; `nil` = entered by hand), `FieldSource` (`auto`, `user`), `ImageSource`. `Example.grammarTopic` is an optional key, not validated here (1.3). `UserSettings` is one record via a fetch-or-create helper, `activeGrammarTopics = []` until 1.3 supplies the default. `Word.normalize(_:)` (lowercase, trimmed, whitespace collapsed, Unicode NFC so canonically-equivalent spellings compare byte-equal in a `#Predicate`; no diacritic folding) fills `normalized` (C4). A container factory in Core (in-memory for tests, on-disk for the app) and a not-deleted fetch descriptor sorted newest first; no `WordStore` (1.4), no UI wiring (1.5). Detail in the issue. *(#26)*
  *AC:* `swift test` covers: the in-memory container's schema has exactly the seven models; a `Word` with two senses, three examples, a tag and an image round-trips with `order` preserved, and the same data survives reopening an on-disk store; hard-deleting a word removes its senses, examples and image but not its tags; setting `deletedAt` hides the word from the not-deleted descriptor but not from a plain fetch; `normalize("  look   up ") == "look up"`; a new `Word` has `learningLanguage == "en"`; a sense with `senseSource = .wordnet`, a gloss and `fieldSources` round-trips, a hand-entered one has `senseSource == nil`; `PartOfSpeech.allCases.count == 8` and the enums encode as their case names; the settings helper returns one record however often it is called, with `learningLanguage == "en"`, `nativeLanguage == nil`, `activeGrammarTopics == []`; a `ReviewEvent` is storable and referenced nowhere else; `grep '\.unique'` over Core sources finds nothing; lint, build and CI green.
- [ ] **1.3 Grammar catalog.** `en.json` resource with the topics in `requirements.md` Appendix A; `GrammarCatalog` loader; `UserSettings.activeGrammarTopics` with the default set.
  *AC:* every key in the JSON is unique and prefixed `en.`; unknown key lookup returns `nil`, not a crash; default active set matches the requirements.
- [ ] **1.4 WordStore.** Add, fetch (sorted by `createdAt` desc), search by normalized headword, soft delete, duplicate detection. (C1, C4, W3, B1)
  *AC:* adding `"Book "` when `"book"` exists returns the existing word; search is case- and whitespace-insensitive; deleted words are excluded from list and search but still present in the store.
- [ ] **1.5 Word list + capture UI.** List screen, search bar, add field, empty state. Tapping an existing duplicate opens its card. (C1, C4, C5-without-autofill, B1)
  *AC:* UI test: type a word → it appears at the top; type it again → card of the existing word opens.
- [ ] **1.6 Word card, manual editing.** Card view with senses, inline editing of every field, add/remove/reorder senses and examples, delete word with confirmation. (W1, W2, W3)
  *AC:* edits persist across relaunch; removing the last sense is allowed (card shows "add a sense"); edited fields are marked `FieldSource.user`.
- [ ] **1.7 Export / import JSON.** Versioned schema (`"schemaVersion": 1`), share sheet for export, file importer for import with merge-by-id. (S3)
  *AC:* export → wipe → import reproduces the same words, senses, examples, tags and settings; importing the same file twice does not duplicate; import of a file with a higher `schemaVersion` fails with a clear message.

**Exit criteria:** the author can keep a word list by hand on device; `swift test` covers 1.2–1.4 and 1.7.

---

## Phase 2 — Autofill

- [ ] **2.1 `CardGenerator` protocol + stub.** `generateCard(for word: String, nativeLanguage: String, topics: [GrammarTopicID]) async throws -> GeneratedCard`, where the result carries per-sense source (wordnet / model), gloss, and reports first-card and full-card stages so 2.3 can show the card before topic examples arrive. `StubCardGenerator` returns fixtures; `UnavailableCardGenerator` throws `.unavailable`. (A8)
  *AC:* protocol has no Foundation Models, WordNet or Translation types in its signature; stub is used by all tests.
- [ ] **2.2 WordNet-first generator (ADR 0001).** Two reviewable PRs are fine: **(a)** sense inventory — move the OEWN 2024 bundle, `function-words.txt`, `OEWN-LICENSE.txt` and `tools/convert_oewn.py` from `spike/` into `WordhoardCore` resources; `WordNetLookup` returns up to 2 senses per part of speech, 4 in all, in WordNet order, with gloss, synonyms, antonyms and the synset example; stoplist check before lookup. **(b)** model writing — `@Generable` types and prompts in `Prompts/` for: model-only senses call + yes/no verifier (fallback path), per-sense learner definition from gloss + synonyms + example, neutral example, topic example with the topic assigned by the caller; one fresh session per call; Translation framework for the per-sense translation (current shape; 2.10 changes it). Availability check before any model call. (A1, A2, A6, A9)
  *AC:* when `SystemLanguageModel.default.availability != .available`, the generator throws `.unavailable` without calling the model; `book` → 4 senses (2 noun, 2 verb incl. *reserve*) all marked `wordnet`, and no model-only senses call runs; `however` → stoplist path, one adverb sense marked `model`; `asdfgh` → "not found", no sense; a refused definition call keeps the gloss as the definition and the card is still produced; no single call produces more than one sense's prose; unit tests with the stub cover every path (wordnet / stoplist / model-only / not-found); the bundle has a sibling `OEWN-LICENSE.txt` and is listed in `NOTICE`; the regression runner on device gives judged ≥ 10/12 (the Phase 0 baseline) — results in the PR.
- [ ] **2.3 Background fill + card states.** On add: save immediately, enqueue generation, card shows `filling` → `ready` / `failed` / `unavailable`. The card becomes `ready` after the first-card stage (senses, definitions, translations, one neutral example per sense); topic examples keep arriving in the background (A2, #20). Retry action on failure. (C5, A6, A7)
  *AC:* list is usable while generation runs; killing the app mid-generation leaves the word saved with state `failed` or `pending`, never half-written; `unavailable` shows a one-line explanation and an editable empty card; a card with senses and neutral examples is visible before any topic example exists.
- [ ] **2.4 Merge with provenance.** Apply `GeneratedCard` to a `Word`: fill `.auto` fields, never touch `.user` fields, append new examples without duplicating existing text. (A4)
  *AC:* regenerate after editing a definition keeps the user's definition and refreshes synonyms; regenerate twice does not double the examples.
- [ ] **2.5 Regenerate actions.** Per card and per sense/field. (A5)
  *AC:* available only when generator is available; respects 2.4.
- [ ] **2.6 Sense selection by the model from WordNet's full list.** Give the on-device model all WordNet senses of the lemma (gloss + part of speech, up to ~10) and ask for the indices of the ≤ 4 most useful for a learner; guarantee at least one sense per part of speech WordNet lists; fall back to the 2-per-POS cap when the call fails. Replaces the per-POS cap of 2.2 as the default. (A1) *(#18)*
  *AC:* runner: *book* keeps a noun and *reserve*; *run* gains *manage/operate* and keeps *move fast*; *light* keeps noun, verb, adjective; *lead* keeps ≥ 1 noun and ≥ 1 verb; added latency ≤ 3 s per word; judged ≥ 10/12 with no regression on words that passed at `665d06d`; unit test: a failing selection call yields the 2-per-POS fallback.
- [ ] **2.7 Part-of-speech cases for prepositions and conjunctions.** `preposition` and `conjunction` are in `PartOfSpeech` since 1.2; add `determiner` / `pronoun` if cheap; map WordNet POS and the stoplist onto them; the verifier prompt names the POS in plain words ("as a preposition"). (A1, §5) *(#19)*
  *AC:* runner: *despite* → one `preposition` sense meaning *in spite of* with a sane definition (it was `adverb` in 6/6 Phase 0 runs); *however* unchanged (one adverb); export/import round-trips the new cases.
- [ ] **2.8 Autofill latency.** Topic examples generated after the card is shown and saved, appended as they arrive; example calls run concurrently (start with 3 at a time, one session per call) and the chosen concurrency is recorded in the PR with device measurements; Translation calls batched per word, not per sense. (C5, A2, §6 Performance) *(#20)*
  *AC:* runner: time-to-first-card median ≤ 10 s; full card for 4-sense words ≤ 25 s, or the measured floor is documented in `docs/regression-words.md`; the card is visible and saved before any topic example exists (UI check).
- [ ] **2.9 Typed "does not fit" for topic examples + headword post-check.** Example schema becomes `{ fits: Bool, text: String }` (or an optional) so a skip is a value, not an empty-string convention; the caller drops `fits == false`. In code: an example that does not contain the headword or an inflection is regenerated once, then dropped. (A2, G4) *(#21)*
  *AC:* runner: "headword in every example" ≥ 95 % (was 12/20 words at `665d06d`); zero literal "Empty" strings; a `fits == false` example never reaches the store; unit test: a stub example without the headword is regenerated once and then dropped.
- [ ] **2.10 Per-sense word translation: model proposes, Translation framework verifies.** Per sense, a model call with gloss, example and synonyms returns a 1–3-word equivalent; back-translate it with the framework and accept if the lemmatized back-translation (`NLTagger`) contains the headword or a WordNet synonym of that sense; otherwise show the framework's translation of the learner definition, flagged as a fallback. Synonyms and antonyms are not translated; the card-level headword translation from `665d06d` is removed. (A9) *(#22)*
  *AC:* runner reports accepted / rejected / fallback counts and the rejected proposals verbatim, ≥ 80 % accepted on the regression words; *book* shows книга and бронировать (or a synonym) on its noun and *reserve* senses; *look up* no longer shows посмотреть вверх anywhere; missing language pack → empty translation with a note, no model text shown.

**Exit criteria:** add "book" → the card shows a noun sense and the verb *reserve* within ~10 s and the topic examples fill in afterwards; edits survive regeneration; the app behaves well on a non-AI device (simulate via `UnavailableCardGenerator` behind a debug toggle); the on-device regression runner over `docs/regression-words.md` reports **judged ≥ 10/12, mechanical ≥ 90 %, first-card median ≤ 10 s** (Phase 0 baseline at `665d06d`: 10/12, 86.0 %, 7.6–9.9 s), with the run summary added to "Known results".

---

## Phase 3 — Grammar topics in the product

- [ ] **3.1 Topic settings screen.** Pick active topics, grouped as in Appendix A. (G2)
- [ ] **3.2 Topic-aware examples.** Generator receives the active topics and issues one example call per sense × topic with the topic's name and one-line description in the prompt; the `grammarTopic` tag is set by the caller from the request, never parsed from model output; a topic the model marks "does not fit" (2.9) gets no example for that sense. (A2, G4)
  *AC:* with topics `{present_perfect}` the fixture-driven test asserts one request per sense contains the topic descriptor and the resulting example carries `en.present_perfect`; no example ever carries a topic that was not requested; device check on 5 words shows tagged examples whose grammar matches the tag.
- [ ] **3.3 Badges and browse-by-topic.** Topic badge on each example; "Topics" tab listing active topics with example counts; tapping shows all examples for that topic. (G3, B2)
  *AC:* counts match the store; neutral examples have no badge.

---

## Phase 4 — Images

- [ ] **4.1 `ImageGenerator` protocol + stub**, image file storage (`ImageStore`: write, read, delete, thumbnail). (I6)
  *AC:* deleting a word deletes its image file; orphan scan on launch removes files without a `Word`.
- [ ] **4.2 Image Playground implementation.** Starts with the check Phase 0 did not do (#5, §10 Q4): availability on the author's device and region, 5 images from model-written prompts (apple, book, run, xylophone, achieve), refusals, time, styles, and a recorded recommendation — images on by default / opt-in / dropped from v1 — before product code; the recommendation goes into an ADR and, if "opt-in" or "dropped", into I1–I5. Then: the `imagePrompt` is a separate small model call per word (the WordNet-first pipeline has no card-level call to carry it), nullable for abstract words; availability check, refusal handling. (I1, I4, I5)
  *AC:* #5's five criteria recorded in the PR; `nil` prompt → no generation attempted; refusal → card has no image and offers manual pick; no crash on unsupported device; a failed image prompt call never delays or fails the card.
- [ ] **4.3 Manual pick: photo library and camera.** (I2)
- [ ] **4.4 Background generation and placeholder.** (I3) Settings toggle for auto-generation. (S5)

---

## Phase 5 — Siri, onboarding, settings

- [ ] **5.1 App Intent `AddWordIntent`** with `word` parameter, App Shortcut phrases ("Add a word to Wordhoard", "Save a word in Wordhoard"), result dialog. Shares `WordStore` with the app via the Core package. Starts with the Siri check Phase 0 did not do (#6, §10 Q3): 10 English words dictated with Siri in Russian and 10 in English, recognition rate and the two-step dialog recorded in the PR; also confirms the intent works with free personal-team signing (#7). (C2)
  *AC:* recognition rates recorded; invoking the intent saves the word and triggers autofill on next foreground; duplicate word responds "already in your hoard" and does not create a copy.
- [ ] **5.2 Onboarding.** One screen: native language picker preselected from system language; explain where translations come from. (S1)
  *AC:* skipping is impossible by accident (default is valid); choice persists; shown exactly once.
- [ ] **5.3 Settings screen.** Native language, grammar topics (links 3.1), auto-images, export/import (links 1.7), "Use Apple's server model when online" (only when the PCC tier is compiled in, A10), About. (S1–S3, S5, S6, A10)
  *AC:* About screen shows "Open English WordNet 2024 — CC BY 4.0, derived from Princeton WordNet" with a link or sheet showing the full `OEWN-LICENSE.txt` text, plus the app license; the credit is visible without scrolling past other content on an iPhone 15 Pro-size screen; the PCC toggle is absent in builds without the entitlement.
- [ ] **5.4 Share extension** — text → `AddWordIntent`. (C3) *May slip to v1.1.*

---

## Phase 6 — v1 polish

- [ ] **6.1 Accessibility pass.** Dynamic Type at the largest sizes, VoiceOver labels on list, card, badges.
- [ ] **6.2 Empty, loading, error states** reviewed on every screen.
- [ ] **6.3 App icon, launch screen, display name, `Localizable.xcstrings` audit.** Includes a licensing audit: every bundled third-party file has its sibling `*-LICENSE.txt`, `NOTICE` lists it, and the About screen (5.3) credits it (CLAUDE.md licensing rules, S6).
- [ ] **6.4 Privacy manifest and App Privacy answers** ("Data not collected").
- [ ] **6.5 TestFlight build** to the author's device; one month of daily use.

**v1 exit criteria:** `requirements.md` §8 "Done when" — the author prefers it to a spreadsheet after a month.

---

## Later (v1.1, v2) — not planned in detail yet

TTS pronunciation (W5), tags (W4), capture note (C6), tip jar (S4), landing page and App Store release; then flashcards + FSRS, reminders, grammar drills, CloudKit sync. Plan these when v1 is in daily use.

---

## Working agreements

- A task is not started until its acceptance criteria are agreed (analyst) and its issue exists.
- A task is not done until qa has run the suite and checked each criterion on simulator or device.
- Anything discovered during a task that is not in the criteria becomes a new issue, not scope added to the PR.
- Prompt changes re-run `docs/regression-words.md` with the on-device runner in `spike/WordhoardSpikeRegression` (ADR 0001); the scorecard (mechanical rate, judged table, timings) goes in the PR description and a row in "Known results".
