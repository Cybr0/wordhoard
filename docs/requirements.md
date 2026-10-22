# Wordhoard — Requirements

*Status: draft; Phase 0 spike closed by ADR 0001 (verdict: adjust); v1 built through plan Phase 6 (PR #63), awaiting the owner's device checks and TestFlight month. Last updated: 2026-10-23 (Phases 4–6 as shipped: `imageStatus`, `hasCompletedOnboarding`, `WORDHOARD_PCC`, §8 scope, ADRs 0002–0004).*

Wordhoard is a personal English vocabulary app for iOS. You capture a word, the app fills in the rest (definition, translation, synonyms, examples tied to grammar topics, a picture), and later helps you remember it. Everything runs on the device; there is no backend.

The name comes from Old English *word-hord* — "word-hoard", the stock of words a poet carried in memory.

---

## 1. Goals and non-goals

### Goals

- Make capturing a new word nearly effortless: type it, say it to Siri, or share it from another app.
- Fill the word card automatically with on-device AI, with the user able to edit anything.
- Tie example sentences to grammar topics, so learning a word also reinforces grammar (tenses, conditionals, passive voice, ...).
- Keep all data on the device. No account, no server, no tracking.
- Stay a small, finishable project: one platform, one developer.

### Non-goals (for now)

These were considered and deliberately deferred. See §11 for the full list and the reasoning.

- Backend, web app, Telegram bot, cross-platform sync via own server.
- Subscriptions or paid tiers.
- Languages other than English as the learning language (the schema allows it; the content work does not fit v1 — see §11).

---

## 2. Users and platform

- **Primary user:** the author, learning English with Russian as the native language.
- **Secondary users:** anyone learning English who wants a private, offline word list with smart autofill. Native language is configurable.
- **Platform:** iPhone, **iOS 27+**, SwiftUI. iPad and Mac may work "for free" via SwiftUI but are not a target. Rationale for 27 rather than 26: AI features already require iPhone 15 Pro or newer, and every such device runs iOS 27; the author has no iOS 26 device to test on; iOS 27 adds the `LanguageModel` protocol and Private Cloud Compute (§7), which would otherwise need `#available` branches. Confirmed by ADR 0001.
- **Hardware for AI features:** Apple Intelligence-capable device (iPhone 15 Pro or newer) with Apple Intelligence enabled. On other devices the app works fully, but cards are filled in manually.

---

## 3. Core concepts

| Concept | Description |
|---|---|
| **Word** | The headword as the user entered it, normalized (lowercase, trimmed). One entry per distinct word per user. Multi-word entries (phrasal verbs, idioms) are allowed: "look up", "by the book". |
| **Sense** | One meaning of a word. "book" has at least two: the noun (a written work) and the verb (to reserve). Definition, translation, synonyms, antonyms and examples belong to a sense, not to the word. The sense is also the unit of learning. |
| **Example** | A sentence using the word in a given sense, optionally tagged with a **grammar topic**. |
| **Grammar topic** | A fixed catalog entry such as *Present Perfect*, *Second Conditional*, *Passive Voice*. See Appendix A. |
| **Image** | One picture per word (optional). Generated on device, picked from the photo library, or taken with the camera. |
| **Review event** | An append-only record: "on date D the user reviewed sense S with rating R". Used for spaced repetition (post-v1). |

---

## 4. Functional requirements

Priorities: **M** = must have for v1, **S** = should have, **L** = later.

### 4.1 Capturing words

| # | Requirement | Pri |
|---|---|---|
| C1 | Add a word by typing it in the app. | M |
| C2 | Add a word via Siri using App Intents / App Shortcuts: "Hey Siri, add a word to Wordhoard" → Siri asks for the word → confirmation. The word phrase cannot be embedded in the trigger sentence (iOS limitation); the two-step dialog is the expected flow. | M |
| C3 | Add a word from the Share sheet (select text in Safari / Books / any app → Share → Wordhoard). | S |
| C4 | Duplicate handling: adding a word that already exists opens the existing card instead of creating a copy. Comparison is case-insensitive and whitespace-normalized. | M |
| C5 | Capture is instant. Autofill runs in the background after the word is saved; the card shows a "filling in…" state. | M |
| C6 | Optional note at capture time: where the word came from ("from *The Expanse* S2E4"). | S |
| C7 | Home-screen widget / Control Center button for quick add. | L |

### 4.2 Autofill (on-device AI)

| # | Requirement | Pri |
|---|---|---|
| A1 | **Senses come from the bundled Open English WordNet 2024, prose from the model** (ADR 0001). For a headword: (a) if it is on the function-word stoplist (~385 closed-class lemmas) or WordNet does not have the lemma, one model call proposes senses (part of speech, definition) and a yes/no verifier call checks each; if every sense is rejected the card shows "Not found. Add senses manually." and nothing invented. (b) Otherwise WordNet supplies the senses — up to 2 per part of speech, 4 in all, in WordNet order — with part of speech, synonyms, antonyms and a source example; the model never adds a sense when WordNet knows the lemma (gaps are closed by hand, W2). Each sense is marked with its source (WordNet / model). Per sense, separate guided-generation calls (`@Generable`, one fresh session each) write the learner definition from the gloss, synonyms and example, then the examples (A2). There is no single call that produces a whole card. Sense selection within WordNet's list is being improved in plan 2.6 (#18). | M |
| A2 | Examples per sense: one neutral example (required; the card is shown once every sense has one) plus one example per grammar topic the user is learning (4.5). The topic is assigned by the caller, never classified by the model. Topic examples are optional — the model may answer "does not fit" for a sense that cannot use that grammar naturally (plan 2.9, #21) — and are generated in the background after the card is shown, appended as they arrive (plan 2.8, #20). Every example must contain the headword or an inflection of it; one that does not is regenerated once, then dropped (#21). | M |
| A3 | ~~Pronunciation (IPA) from the model~~ **Dropped** (ADR 0001): the model's IPA was wrong (`/ˈhʌvər/` for *however*). No IPA field is generated or shown in v1; pronunciation is text-to-speech only (W5). | — |
| A4 | Every generated field is marked `source = auto`. When the user edits a field it becomes `source = user` and is never overwritten by a later re-generation. | M |
| A5 | "Regenerate" action per card and per field. | S |
| A6 | If the model is unavailable (unsupported device, Apple Intelligence off, region restriction), the card opens empty for manual entry, with a one-line explanation. No crash, no dead end. A failure or guardrail refusal of a single call (seen on *gaslight*, *run*, *Tashkent*) degrades only that field: a refused definition keeps the WordNet gloss, a refused example is skipped; the card is still saved and shown. | M |
| A7 | Generated content is shown as editable draft. The small on-device model will sometimes be wrong, especially for rare words, idioms and translations; the UI should not present it as authoritative. | M |
| A8 | Pluggable model layer: the autofill code talks to a small internal protocol (`CardGenerator`), so the Private Cloud Compute tier (A10), a cloud model (Claude, OpenAI, …) or the iOS 27 third-party provider API can be plugged in later without rewriting the feature. | S |
| A9 | **Translations come from Apple's Translation framework, never from the model** (ADR 0001; the model's Russian contained non-words). Target shape (plan 2.10, #22): per sense, a 1–3-word equivalent in the native language (book → книга / бронировать) that the model proposes and the framework confirms by back-translation; a rejected proposal falls back to the framework's translation of the learner definition and is flagged as a fallback. Until #22 lands, the per-sense learner definition is translated by the framework. Synonyms and antonyms are not translated; there is no card-level headword translation (wrong for phrasal verbs and idioms). If the language pack is not installed, the field stays empty with a one-line note — the model is never the fallback. | M |
| A10 | **Private Cloud Compute tier** (`PrivateCloudComputeLanguageModel`, 32K context): used for the model calls of A1/A2/A9 when the build carries the `com.apple.developer.private-cloud-compute` entitlement, the device is online and the Settings toggle "Use Apple's server model when online" is on. Gated by the Swift compilation condition `WORDHOARD_PCC`, which only a build configuration whose provisioning profile carries the entitlement may define, never by `availability` alone — without the entitlement the first request crashes (ADR 0001, #15). The `#if WORDHOARD_PCC` branch lives in the one session factory (`FoundationModelCalls.swift`); no build defines the flag in v1, so the tier and its Settings toggle are compiled out until the entitlement is granted. Degradation order: PCC → on-device + WordNet → manual. | S |

### 4.3 Word card

| # | Requirement | Pri |
|---|---|---|
| W1 | Card shows: word, image, a play-pronunciation control (W5; no IPA text, see A3), and a list of senses. Each sense: part of speech, source badge (WordNet / model), definition, translation, synonyms, antonyms, examples (with grammar-topic badges). | M |
| W2 | Every field is editable inline. Senses and examples can be added, removed, reordered. | M |
| W3 | Delete word (with undo or confirmation). | M |
| W4 | User note and tags/collections (e.g. "IELTS", "work", "The Expanse"). | S |
| W5 | Text-to-speech pronunciation via `AVSpeechSynthesizer` (works offline, no extra assets). The only pronunciation feature in v1 (ADR 0001). | S |
| W6 | Word forms (book → books, booked, booking) shown on the card. | L |

### 4.4 Images

| # | Requirement | Pri |
|---|---|---|
| I1 | Generate an illustration on device with the Image Playground framework (`ImageCreator`). The prompt is a short visual description produced by the language model, not the raw word. On by default as a provisional choice; `ImageCreator` is deprecated in the iOS 27 SDK and confined to one type; the verdict (on by default / opt-in / dropped) waits for the #5 device table (ADR 0003, proposed). | M |
| I2 | Fallback / alternative: pick from photo library or take a photo. | M |
| I3 | Image generation runs in the background after the card is saved; the card shows a placeholder until ready. Applies to every newly created word, typed or added by Siri, while the S5 toggle is on; imported words and words whose picture the user removed are not queued (plan 4.4, 5.1). | M |
| I4 | If Image Playground is unavailable (device, region, or the model refuses the prompt), the card simply has no image and offers I2. | M |
| I5 | Abstract words ("however", "despite") may get no image by design. The language model may return "no suitable image" and the app respects that. | S |
| I6 | Images are stored as files in the app container, referenced from the database; thumbnails cached. | M |

### 4.5 Grammar topics

| # | Requirement | Pri |
|---|---|---|
| G1 | Fixed catalog of grammar topics shipped with the app (Appendix A). Not user-editable in v1. | M |
| G2 | User selects which topics they are currently learning (Settings). Default: a small beginner-friendly set. | M |
| G3 | Browse examples by topic: "show all my words used in Present Perfect". | S |
| G4 | Each example carries at most one topic tag. Examples with no tag are "neutral". | M |

### 4.6 Browsing and search

| # | Requirement | Pri |
|---|---|---|
| B1 | Word list sorted by date added (newest first) with search by headword. | M |
| B2 | Filter by tag/collection and by grammar topic. | S |
| B3 | Full-text search across definitions and examples. | L |

### 4.7 Settings

| # | Requirement | Pri |
|---|---|---|
| S1 | Native language for translations. Asked once on first launch, with the system language preselected when it is supported; otherwise "No translation" is preselected with a note that translation for that language is not available yet and can be typed manually. Changeable later in Settings. **Supported set = languages the Translation framework can translate to on device** (translations are produced by that framework, not by the model, so adding a language costs only QA). Display order puts the most common learner languages first: Russian, Spanish, Chinese (Simplified), Hindi, Arabic, Portuguese (Brazil), French, German, Japanese, Korean, Turkish, Italian, Vietnamese, Indonesian, Polish, Ukrainian, then the remaining supported languages alphabetically. Languages the framework does not support (e.g. Uzbek) are deferred — see §11. Changing the language does not retranslate existing cards automatically; it only affects new autofill (a "retranslate" action may come later). | M |
| S2 | Grammar topics currently being learned (see G2). | M |
| S3 | Export all data as JSON (and import). This is the user's safety net since there is no cloud. | M |
| S4 | "Support the developer" screen with tip-jar in-app purchases (consumables). | S |
| S5 | Toggle for automatic image generation. | S |
| S6 | About screen credits the bundled data: "Open English WordNet 2024, CC BY 4.0, derived from Princeton WordNet", with a link to the full license text shipped in the bundle. Required by the CC BY 4.0 license (ADR 0001, `NOTICE`, `CLAUDE.md` licensing rules). | M |

### 4.8 Learning (post-v1)

Captured here so the data model accounts for it; not built in v1.

| # | Requirement | Pri |
|---|---|---|
| L1 | Flashcard review: word → recall meaning; meaning → recall word. Unit of review is the **sense**. | L |
| L2 | Spaced repetition with FSRS. Scheduling state is derived from the append-only review log, never stored as the only copy. | L |
| L3 | Grammar drills: fill the verb form in an example for a chosen topic. | L |
| L4 | Daily reminder notification ("12 words due today"). | L |
| L5 | Simple stats: words added per week, review streak. | L |

---

## 5. Data model

Sketch only; final shape is decided in code. SwiftData, with the schema kept CloudKit-compatible (all properties optional or defaulted, no unique constraints enforced by the store, relationships with inverses) so iCloud sync can be switched on later without a migration.

```
Word
  id: UUID            (client-generated)
  learningLanguage: String  (BCP-47; always "en" in v1, see §11)
  headword: String    (as entered)
  normalized: String  (lowercase, trimmed; used for duplicate check)
  pronunciation: String?
  note: String?
  tags: [Tag]
  image: ImageAsset?
  senses: [Sense]     (ordered)
  createdAt, updatedAt: Date
  deletedAt: Date?    (soft delete; needed for sync later)
  autofillState: enum (pending, filling, ready, failed, unavailable)
                      (default pending; written by the autofill queue only, plan 2.3;
                       not exported — import derives ready/pending from the senses)
  imageStatus: enum? (pending, skipped, refused, failed, unavailable; nil = nothing
                      requested; setting or removing a picture clears it; written by
                      the picture queue, plan 4.4; not exported)

Sense
  id: UUID
  word: Word
  partOfSpeech: enum (noun, verb, adjective, adverb, preposition, conjunction,
                      phrase, other)   (preposition/conjunction added by #19, ADR 0001)
  senseSource: .wordnet | .model      (where the sense itself came from)
  gloss: String?                       (WordNet gloss the definition was written from)
  definition: String
  translation: String?
  translationIsFallback: Bool  (default false; true when translation is the framework's
                                translation of the definition because the proposed
                                equivalent failed back-translation, A9 / plan 2.10)
  synonyms: [String]
  antonyms: [String]
  examples: [Example] (ordered)
  fieldSources: [String: Source]   (field name → .auto | .user)
  order: Int

Example
  id: UUID
  sense: Sense
  text: String
  grammarTopic: GrammarTopicID?    (string key into the shipped catalog,
                                    namespaced by language: "en.present_perfect")
  source: .auto | .user
  order: Int

Tag
  id: UUID
  name: String
  words: [Word]

ImageAsset
  id: UUID
  fileName: String    (in app container)
  source: .generated | .library | .camera
  prompt: String?     (if generated)

ReviewEvent            (post-v1, append-only)
  id: UUID
  senseID: UUID
  reviewedAt: Date
  rating: Int         (FSRS: 1 again, 2 hard, 3 good, 4 easy)
  direction: enum (wordToMeaning, meaningToWord)

UserSettings           (single record)
  nativeLanguage: String?  (BCP-47, e.g. "ru", "es", "zh-Hans"; nil = no translation)
  learningLanguage: String (always "en" in v1)
  activeGrammarTopics: [GrammarTopicID]
  autoGenerateImages: Bool     (default true, S5)
  hasCompletedOnboarding: Bool (default false; set by the first-launch sheet, S1,
                                plan 5.2; nativeLanguage == nil cannot mean "not asked"
                                because "No translation" is also nil; not exported)
```

Design notes:

- **Senses, not flat cards.** Everything that depends on meaning hangs off `Sense`. This is the one decision that is painful to change later.
- **Field provenance** (`fieldSources`) exists so that regeneration never clobbers user edits.
- **Soft delete + client UUIDs** cost nothing now and make iCloud sync and future export/import trivial.
- **Grammar topics are a static catalog**, referenced by string key, so the catalog can grow with app updates without data migration. Keys are namespaced by learning language (`en.present_perfect`) because grammar catalogs are language-specific.
- **`learningLanguage` is stored but fixed to `"en"` in v1.** It costs nothing now and means that adding another learning language later is a content task (a new grammar catalog, prompts, a test word list), not a data migration.
- **Review events are a log**, so two devices reviewing offline merge cleanly once sync exists.
- **Sense provenance and gloss are kept** (`senseSource`, `gloss`) so the card can show the WordNet / model badge (W1), regeneration can rewrite a definition from the same gloss, and a refused writing call can fall back to the gloss (A6). Regeneration matches a WordNet sense by part of speech + gloss and a model sense by part of speech in order; a hand-entered sense (`senseSource == nil`) is never matched or modified (plan 2.4).
- **Autofill state lives on the word** (`autofillState`) so a kill mid-generation is recoverable: `filling` is written before the model is called and `ready` in the same commit as the generated senses, so a stored word is either untouched or complete; `filling` found at launch is re-queued (C5, A6, plan 2.3).
- **The picture goes with the word.** Soft-deleting a word hard-deletes its `ImageAsset` row and the file (#46, plan 4.1), the one exception to soft delete; files nothing references are removed by a launch-time orphan scan. `imageStatus` is persisted so a kill during generation resumes and the I5 "no suitable image" outcome is remembered (plan 4.4).

---

## 6. Non-functional requirements

| Area | Requirement |
|---|---|
| **Privacy** | No third-party network calls. The only network use is Apple's Private Cloud Compute for autofill (Apple-operated, requests not retained, no account data from the app), and only when the PCC entitlement is present; a Settings toggle ("Use Apple's server model when online", default on; present only in a `WORDHOARD_PCC` build, A10) lets the user keep everything on device. No analytics, no crash-reporting SDKs from third parties. Privacy policy can honestly say "we collect nothing". |
| **Offline** | Everything works offline, including autofill and image generation (both on device). |
| **Availability fallback** | Every AI feature checks availability at runtime (`SystemLanguageModel.default.availability`, Image Playground availability) and degrades to manual entry. The app must be fully usable on an iPhone without Apple Intelligence. |
| **Performance** | Saving a word is instant (< 100 ms perceived). Autofill target: **first card** (senses, definitions, translations, one neutral example per sense) median ≤ 10 s on supported devices; the measured median is 7.6–9.9 s on an iPhone 15 Pro Max (ADR 0001). Topic examples arrive afterwards in the background; a 4-sense word currently takes 35–43 s for the full card (≈ 20 model calls at 1.6–1.8 s each), target ≤ 25 s or documented as the device floor (plan 2.8). Image generation may take longer; it never blocks the UI. |
| **Data safety** | JSON export/import from day one. Data lives in the app container and is included in iCloud device backups by default. |
| **Accessibility** | Dynamic Type and VoiceOver labels on the card and list. |
| **Localization** | UI in English first; Russian UI later. The *content* language (translations) is independent of the UI language. |
| **Model drift** | Apple may update the on-device model with any iOS release; output can change. Prompts are kept in one place and every prompt change is measured with the on-device regression runner (`spike/WordhoardSpikeRegression`) over `docs/regression-words.md`: mechanical checks plus the 12 judged rows of issue #14. Baseline and thresholds are in ADR 0001 and plan Phase 2 exit criteria. |

---

## 7. Technology

| Layer | Choice | Why |
|---|---|---|
| UI | SwiftUI, iOS 27+ | Target platform; modern APIs. |
| Persistence | SwiftData | Native, simple, CloudKit-ready. No server, so no need for GRDB-level control. |
| Autofill | Foundation Models framework, guided generation, **one small call per field group per sense** (ADR 0001) | Two tiers behind one `CardGenerator`: **on-device** `SystemLanguageModel` (4K context, offline, always available — the floor) and **Private Cloud Compute** `PrivateCloudComputeLanguageModel` (32K context, reasoning, network, per-user daily quota, no developer cost; A10). A single call for the whole card overflowed the 4K context and mis-tagged grammar (#4), so each call is small and uses a fresh session; the caller assigns grammar topics. PCC requires the managed entitlement `com.apple.developer.private-cloud-compute`; without it the first request **crashes**, so the PCC backend is gated by the compilation condition `WORDHOARD_PCC` (A10), never by `availability` alone. Degradation order: PCC → on-device + WordNet → manual. |
| Sense inventory | Open English WordNet **2024** bundle (CC BY 4.0; JSON, 15 492 477 bytes; up to 2 senses per part of speech, 4 in all; one example per synset) + function-word stoplist (385 lemmas) | The on-device model invents or duplicates senses (spike, #4/#11); WordNet supplies senses, POS, synonyms, antonyms and one example per synset; the model only writes learner prose for a given sense. Model-only fallback with a verifier for stoplist words and lemmas WordNet lacks (A1). Converter: `spike/tools/convert_oewn.py`. Attribution: `NOTICE`, `OEWN-LICENSE.txt` in the bundle, About screen (S6). |
| Translation | Apple Translation framework (`TranslationSession`, on device); the model only *proposes* per-sense equivalents that the framework verifies (A9, #22) | Model translation produced non-words (spike, #11); bare-word framework translation of synonyms produced the wrong part of speech (#14), so synonyms are not translated. Covers the native languages in S1; no Uzbek. |
| Prompt QA | On-device regression runner in `spike/WordhoardSpikeRegression` over `docs/regression-words.md` | Spike code kept as a tool, not a product codebase (ADR 0001). Every prompt change ships with a run; thresholds in plan Phase 2 exit criteria. |
| Images | Image Playground framework (`ImageCreator`, deprecated in the iOS 27 SDK, confined to `ImagePlaygroundGenerator`) + PhotosPicker + camera | On device, free. The SDK's replacements are interactive only, so background generation (I3) depends on the deprecated API (ADR 0003). |
| Siri | App Intents / App Shortcuts | The only supported way to add Siri phrases. |
| Speech | AVSpeechSynthesizer | Offline pronunciation without audio assets. The model's IPA is not used (wrong on the spike, ADR 0001). |
| Payments | StoreKit 2, consumable tip products, `ProductView` | Tip jar. |
| Sync (later) | SwiftData + CloudKit | Free, no backend, same Apple ID across devices. |
| Spaced repetition (later) | FSRS (Swift port) | Modern algorithm, open source. |

Architecture: plain MVVM-ish SwiftUI with a thin service layer (`AutofillService`, `ImageGenerationQueue` over `ImageStore` and `ImageGenerator`, `WordStore`), created once in the app's `AppDependencies` and shared with the Siri intent (plan 5.1). The autofill service is behind a protocol (`CardGenerator`); v1 ships the on-device Foundation Models implementation (WordNet lookup + per-sense model calls + Translation framework); the PCC implementation is compiled in only with the entitlement (A10).

---

## 8. Roadmap

### v1 — "It fills itself in"

Capture (C1, C2, C4, C5) · Autofill (A1, A2, A4, A6, A7, A9; A5 card-level only, plan 2.5) · Card (W1–W3) · Images (I1–I6; still unvalidated on device — see §10 Q4, ADR 0003) · Grammar topics (G1–G4; G3 browse by topic, plan 3.3) · List & search (B1; B2 by grammar topic only, through topic browse, plan 3.3) · Settings (S1–S3, S5, S6; S5 toggle per plan 4.4 / 5.3).

Done when: the author uses it daily for a month and prefers it to a spreadsheet.

### v1.1 — Polish

Share sheet (C3, plan 5.4, #42), capture note (C6), tags (W4) and filter by tag (B2), TTS (W5), per-sense and per-field regenerate (A5), tip jar (S4), Private Cloud Compute tier (A10, once the entitlement is granted), App Store release, landing page.

### v2 — Learning

Flashcards (L1), FSRS (L2), reminders (L4), stats (L5), then grammar drills (L3). iCloud sync.

### Later / maybe

Widget (C7), word forms (W6), full-text search (B3), Russian UI, iOS 27 third-party model providers (A8), macOS.

---

## 9. Monetization and distribution

- **Free app, no feature gates.** Costs are limited to the Apple Developer Program fee (~$99/year), since AI runs on device.
- **Tip jar** via consumable in-app purchases (StoreKit). Tips may unlock cosmetic thanks (alternate app icons, a "Supporter" badge). Inside the app, donations go through Apple only; the landing page may link to other donation methods, but the app must not link to the landing page's donation section.
- **Open source** under the Apache License 2.0 (`LICENSE`, shown in full on the About screen, plan 6.3). The code is open; the name *Wordhoard*, the icon and other brand assets are not covered by the code license.
- **Landing page** on GitHub Pages: description, App Store badge, support/privacy pages (both required by App Store Connect), optional donation links.
- A paid "Pro" one-time purchase remains possible later if the app ever gains features that cost the developer money (cloud model, own sync server). Going from free to free+Pro is acceptable; the reverse is not.

---

## 10. Open questions and things to validate early

These decide whether the plan holds. Each was to be answered by the Phase 0 spike; the answers are in `docs/decisions/0001-spike-results.md`.

1. **Autofill quality.** Does the on-device model produce usable definitions, synonyms and grammar-tagged examples for common words? For idioms and rare words? Test with ~20 words of varying difficulty.
   → Answer: not for senses — it invents, duplicates and pads them; yes for prose once a sense is given. Senses come from bundled WordNet, the model writes definitions and examples per sense; 10 of 12 judged words pass, 86 % of mechanical checks (ADR 0001, A1).
2. **Translation quality.** Russian is not an officially supported Apple Intelligence language. If translations are poor, options are: skip translation in autofill (manual only), use Apple's Translation framework (on device, supports Russian), or a cloud model later.
   → Answer: the model produced non-words; Apple's Translation framework is the only translation path, with the model limited to proposing per-sense equivalents that the framework verifies (ADR 0001, A9, #22).
3. **Siri recognition.** Does Siri reliably capture an English word when the device/Siri language is Russian, and vice versa? Also: does the two-step "add a word → which word?" dialog feel acceptable?
   → Answer: not tested in Phase 0 (#6 was not run). The intent shipped in plan 5.1 (PR #63) with English phrases only; recognition with English and Russian Siri waits for the owner's #6 table (ADR 0004, proposed).
4. **Image Playground.** Is it available in the author's region and on the author's device? How often does it refuse prompts? Are the available styles acceptable for vocabulary cards?
   → Answer: not tested in Phase 0 (#5 was not run). Phase 4 (PR #63) shipped pictures on by default as a provisional choice; the simulator always reports Image Playground unavailable, so availability, refusals, styles and speed wait for the owner's #5 table, which may still end in "opt-in" or "dropped" (ADR 0003, proposed).
5. **Latency.** How long does a full card (multiple senses, several examples) take to generate on an iPhone 15 Pro vs 17 Pro? Does it need to be split into several smaller generations (senses first, then examples per sense) to show progress?
   → Answer: it must be split — one call overflowed the 4K context. On an iPhone 15 Pro Max the first card takes a median 7.6–9.9 s, the full card a median 12.5–14.3 s and 35–43 s for 3–4-sense words (≈ 1.6–1.8 s per call); topic examples therefore run in the background (ADR 0001, §6 Performance, #20). Not measured on a 17 Pro.
6. **IPA.** Can the model produce correct IPA, or should pronunciation be text-to-speech only?
   → Answer: text-to-speech only; the model's IPA was wrong (`/ˈhʌvər/`) (ADR 0001, A3, W5).
7. **Free vs paid developer account.** Confirm that Foundation Models, Image Playground and App Intents all work when the app is signed with a free personal team (no CloudKit, no push).
   → Answer: the on-device Foundation Models model works with a free personal team (every spike run); Private Cloud Compute does not — it needs a managed entitlement and therefore a paid account (ADR 0001, #15). Image Playground and App Intents were not tested; they are [device] steps of plan 4.2 (#5) and 5.1 (#7), still pending (ADR 0003, ADR 0004).

---

## 11. Deferred decisions and rejected options

Kept so that future-us remembers why.

| Option | Status | Reason |
|---|---|---|
| NestJS backend + PostgreSQL | Deferred | Not needed when AI runs on device. Adds hosting cost, auth, sync, and ops for a one-person project. Revisit only if a feature truly needs a server. |
| Web app (React/Vite, offline via IndexedDB) | Deferred | Browser storage is unreliable (Safari evicts data); a web client without a backend would be two unsynced dictionaries. |
| Telegram bot | Deferred | Requires a server. Could return as a paid feature if a backend ever exists. |
| Cloud LLM autofill (Claude/OpenAI) | Deferred | Costs money per word; would force a subscription. On-device model is free. Kept behind a protocol so it can be added. **Superseded for the common case by Apple's Private Cloud Compute** (§7): same API, no developer cost, user-side quota. Third-party clouds remain deferred. |
| Private Cloud Compute as the *only* autofill path | Rejected | Needs network, Apple Intelligence region support and a per-user daily quota; the on-device model + WordNet stays the floor so every card can be filled offline. |
| Subscription | Rejected for now | No recurring costs to justify it; users dislike subscriptions for simple tools. |
| Shared global lexicon vs personal words | Personal words | No server, so no sharing. Each user's cards are fully their own. |
| Own sync protocol (delta sync, cursors, LWW) | Replaced by CloudKit | Only Apple devices are targeted; CloudKit is free and needs no server. |
| GRDB instead of SwiftData | SwiftData | GRDB was suggested for custom sync with an own server. With CloudKit, SwiftData is the simpler fit. |
| Next.js | Not applicable | No web app. |
| GPL license | Rejected | Incompatible with App Store distribution in practice. |
| Other learning languages (German, Spanish, Japanese, …) | Deferred; schema is ready | The on-device model supports a dozen or so languages, but English is where it is strongest, and the author cannot judge output quality in languages they do not speak. The bigger cost is the grammar-topic catalog: it is language-specific (English tenses vs German cases vs Japanese particles) and must be written by someone who knows the language. `learningLanguage` and namespaced topic keys are stored from day one so this can be added later without migration. |
| Native languages outside the Translation framework (Uzbek, Kazakh, …) | Deferred | Translations come from Apple's on-device Translation framework, which does not support these. Options later: static EN→xx translations from Wiktionary (CC BY-SA) or an online service behind a consent screen. Until then such users pick "No translation" and type translations by hand. |
| One guided-generation call for the whole card | Rejected (ADR 0001) | Overflowed the on-device 4 096-token context on *however* and mis-tagged grammar topics (#4). Cards are built from small per-sense calls with the topic assigned by the caller. |
| Model-generated senses when WordNet knows the lemma | Rejected (ADR 0001) | Three prompt iterations never produced *book → reserve* and padded the list to the allowed count; the yes/no verifier falsely rejected real senses (#4, #11). Senses come only from WordNet for known lemmas; the model-only path with verifier is kept for stoplist words and unknown lemmas. |
| Model translation (direct or as fallback) | Rejected (ADR 0001) | Produced non-words ("ночальница") and wrong-POS translations (#11). Translation framework only; the model may propose a per-sense equivalent that the framework verifies (#22). |
| Translating synonyms/antonyms and the bare headword | Rejected (ADR 0001) | Context-free bare-word translation gives the wrong POS (*reserve → резервуйте*) and literal phrasal verbs (*look up → посмотреть вверх*) (#14). |
| Model-generated IPA | Rejected (ADR 0001) | Wrong on the first device run (`/ˈhʌvər/`). Pronunciation is text-to-speech (W5); IPA text could come from ipa-dict en_US later (`docs/resources.md` §2.3). |
| SemCor tag-count ranking of WordNet senses (cap 4 across parts of speech) | Rejected for now (ADR 0001) | Counts cover only 21 290 of 152 286 lemmas and demote *book → reserve* (count 1), drop *light*'s verb and *lead*'s nouns (#14 run 6, reverted in `0b16922`). Code and data kept at `d2dfc41`; model-assisted selection is tried instead (#18). |
| Gating Private Cloud Compute on `availability` | Rejected (ADR 0001) | `availability` reports `available` without the entitlement and the first request crashes the process (#15). PCC is compiled in only when the build carries the entitlement. |
| Princeton WordNet 3.1 / SQLite build | Not chosen (ADR 0001) | Open English WordNet 2024 is newer, maintained and CC BY 4.0; a plain JSON bundle loads in under a second, so SQLite was not needed (PR #13). Revisit if memory becomes a problem (`docs/resources.md` §4.2). |

---

## Appendix A — Grammar topic catalog (initial, English)

Keys are stable identifiers, prefixed with the learning language in storage (`en.present_perfect`); the prefix is omitted below. Display names may be localized later.

**Tenses**
- `present_simple`, `present_continuous`, `present_perfect`, `present_perfect_continuous`
- `past_simple`, `past_continuous`, `past_perfect`, `past_perfect_continuous`
- `future_simple`, `future_continuous`, `future_perfect`, `going_to`

**Conditionals**
- `zero_conditional`, `first_conditional`, `second_conditional`, `third_conditional`, `mixed_conditional`

**Voice and reporting**
- `passive_voice`, `reported_speech`

**Modals**
- `modals_ability` (can/could/be able to), `modals_obligation` (must/have to/should), `modals_possibility` (may/might/could), `modals_deduction` (must be/can't be)

**Verb patterns**
- `gerund_vs_infinitive`, `phrasal_verbs`, `used_to_would`

**Other**
- `comparatives_superlatives`, `relative_clauses`, `question_tags`, `wish_if_only`, `articles`, `countable_uncountable`

Default "currently learning" set for new users: `present_perfect`, `past_simple`, `first_conditional`, `second_conditional`, `passive_voice`.

---

## Appendix B — Example card (target output of autofill)

Word: **book** · native language: Russian · active topics: present_perfect, second_conditional, passive_voice

```
Sense 1 — noun
  definition:  a written or printed work consisting of pages bound together
  translation: книга
  synonyms:    volume, publication, title
  antonyms:    —
  examples:
    [neutral]            She left her book on the train.
    [present_perfect]    I have read this book three times.
    [second_conditional] If I had more time, I would write a book.
    [passive_voice]      The book was translated into forty languages.

Sense 2 — verb
  definition:  to reserve a seat, room, ticket, etc. in advance
  translation: бронировать, заказывать
  synonyms:    reserve, arrange, schedule
  antonyms:    cancel
  examples:
    [neutral]            We booked a table for eight o'clock.
    [present_perfect]    Have you booked the flights yet?
    [second_conditional] If it were cheaper, I would book the suite.
    [passive_voice]      All the rooms have already been booked.

Image prompt: "an open book on a wooden table by a window, warm light, illustration"
```
