# Wordhoard — Implementation plan

Phased plan for v1 as defined in `requirements.md` §8. Each task gets a GitHub issue and one PR. Acceptance criteria here are the contract between the analyst, the developer and qa; they reference requirement IDs (C1, A4, …) from `requirements.md` §4.

Checkbox = merged to `main` with tests passing and qa sign-off.

---

## Phase 0 — Spike: does the on-device model deliver?

Throwaway code in a separate Xcode project (`spike/`), not held to project conventions. Goal: answer `requirements.md` §10 before committing to the architecture. Budget: a few evenings.

- [ ] **0.1 Minimal generator.** One screen, text field, button, `@Generable` card struct (senses → definition, translation, synonyms, antonyms, examples with topic tag). Print raw output. *(#1)*
- [ ] **0.2 Regression word list.** Run the generator over `docs/regression-words.md` (≈20 words: common nouns and verbs, a polysemous word, two phrasal verbs, an idiom, two abstract words, one rare word). Record the output verbatim in `docs/decisions/0001-spike-results.md`. *(#2)*
- [ ] **0.3 Translation check.** Compare model translations into Russian against the Translation framework (`TranslationSession`) for the same words. Decide: model, Translation framework, or manual. Record in ADR 0001. *(#3)*
- [ ] **0.4 Latency.** Time a full card on the author's device. If > ~10 s, try splitting into two calls (senses first, then examples per sense) and time again. *(#4)*
- [ ] **0.5 Image Playground check.** Generate 5 images from model-written prompts. Note availability, refusals, time, visual quality. Record in ADR 0001. *(#5)*
- [ ] **0.6 Siri check.** Minimal App Intent with a `String` parameter. Test "add a word to Wordhoard" with device language Russian and with English. Record recognition quality in ADR 0001. *(#6)*
- [ ] **0.7 Free signing check.** Confirm Foundation Models, Image Playground and App Intents work when signed with a free personal team. *(#7)*
- [ ] **0.8 ADR 0001.** Analyst writes the verdict and propagates adjustments into requirements and plan. *(#8)*

**Exit criteria:** ADR 0001 written; it states go / adjust / stop. "Adjust" might mean: translations via Translation framework; examples generated per sense in separate calls; images optional by default. Requirements updated accordingly by the analyst.

---

## Phase 1 — Skeleton: a dictionary you can keep by hand

- [ ] **1.1 Project setup.** `project.yml` (app target + `WordhoardCore` package + test targets), `.swiftformat`, `.swiftlint.yml`, CI workflow running `swift test` and a simulator build on PRs. App launches to an empty list.
  *AC:* `xcodegen generate && xcodebuild build` succeeds on a clean clone; CI is green on the PR.
- [ ] **1.2 Data model.** SwiftData models per `requirements.md` §5: `Word`, `Sense`, `Example`, `Tag`, `ImageAsset`, `UserSettings`. `ReviewEvent` defined but unused. CloudKit-compatible shape (optional/defaulted properties, inverse relationships).
  *AC:* in-memory container creates all models; a `Word` with two senses and three examples round-trips; soft delete hides the word from the default fetch; `learningLanguage` defaults to `"en"`.
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

- [ ] **2.1 `CardGenerator` protocol + stub.** `generateCard(for word: String, nativeLanguage: String, topics: [GrammarTopicID]) async throws -> GeneratedCard`. `StubCardGenerator` returns fixtures; `UnavailableCardGenerator` throws `.unavailable`. (A8)
  *AC:* protocol has no Foundation Models types in its signature; stub is used by all tests.
- [ ] **2.2 Foundation Models implementation.** `@Generable` types, prompt in `Prompts/`, availability check, mapping to `GeneratedCard`. Uses spike findings (single vs split calls). (A1, A2, A6)
  *AC:* when `SystemLanguageModel.default.availability != .available`, the generator throws `.unavailable` without calling the model; manual check on device with the regression list produces well-formed cards.
- [ ] **2.3 Background fill + card states.** On add: save immediately, enqueue generation, card shows `filling` → `ready` / `failed` / `unavailable`. Retry action on failure. (C5, A6, A7)
  *AC:* list is usable while generation runs; killing the app mid-generation leaves the word saved with state `failed` or `pending`, never half-written; `unavailable` shows a one-line explanation and an editable empty card.
- [ ] **2.4 Merge with provenance.** Apply `GeneratedCard` to a `Word`: fill `.auto` fields, never touch `.user` fields, append new examples without duplicating existing text. (A4)
  *AC:* regenerate after editing a definition keeps the user's definition and refreshes synonyms; regenerate twice does not double the examples.
- [ ] **2.5 Regenerate actions.** Per card and per sense/field. (A5)
  *AC:* available only when generator is available; respects 2.4.

**Exit criteria:** add "book" → card fills itself with two senses in a few seconds; edits survive regeneration; the app behaves well on a non-AI device (simulate via `UnavailableCardGenerator` behind a debug toggle).

---

## Phase 3 — Grammar topics in the product

- [ ] **3.1 Topic settings screen.** Pick active topics, grouped as in Appendix A. (G2)
- [ ] **3.2 Topic-aware prompt.** Generator receives active topics; output has at least one example per active topic per sense when the model complies; examples carry `grammarTopic`. (A2, G4)
  *AC:* with topics `{present_perfect}` the fixture-driven test asserts the request contains the topic descriptor; device check on 5 words shows tagged examples.
- [ ] **3.3 Badges and browse-by-topic.** Topic badge on each example; "Topics" tab listing active topics with example counts; tapping shows all examples for that topic. (G3, B2)
  *AC:* counts match the store; neutral examples have no badge.

---

## Phase 4 — Images

- [ ] **4.1 `ImageGenerator` protocol + stub**, image file storage (`ImageStore`: write, read, delete, thumbnail). (I6)
  *AC:* deleting a word deletes its image file; orphan scan on launch removes files without a `Word`.
- [ ] **4.2 Image Playground implementation.** Prompt comes from the card generator's `imagePrompt` (nullable). Availability check, refusal handling. (I1, I4, I5)
  *AC:* `nil` prompt → no generation attempted; refusal → card has no image and offers manual pick; no crash on unsupported device.
- [ ] **4.3 Manual pick: photo library and camera.** (I2)
- [ ] **4.4 Background generation and placeholder.** (I3) Settings toggle for auto-generation. (S5)

---

## Phase 5 — Siri, onboarding, settings

- [ ] **5.1 App Intent `AddWordIntent`** with `word` parameter, App Shortcut phrases ("Add a word to Wordhoard", "Save a word in Wordhoard"), result dialog. Shares `WordStore` with the app via the Core package. (C2)
  *AC:* invoking the intent saves the word and triggers autofill on next foreground; duplicate word responds "already in your hoard" and does not create a copy.
- [ ] **5.2 Onboarding.** One screen: native language picker preselected from system language; explain where translations come from. (S1)
  *AC:* skipping is impossible by accident (default is valid); choice persists; shown exactly once.
- [ ] **5.3 Settings screen.** Native language, grammar topics (links 3.1), auto-images, export/import (links 1.7), about. (S1–S3, S5)
- [ ] **5.4 Share extension** — text → `AddWordIntent`. (C3) *May slip to v1.1.*

---

## Phase 6 — v1 polish

- [ ] **6.1 Accessibility pass.** Dynamic Type at the largest sizes, VoiceOver labels on list, card, badges.
- [ ] **6.2 Empty, loading, error states** reviewed on every screen.
- [ ] **6.3 App icon, launch screen, display name, `Localizable.xcstrings` audit.**
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
- Prompt changes re-run `docs/regression-words.md`; results go in the PR description.
