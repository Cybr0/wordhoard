# Wordhoard — Requirements

*Status: draft, pre-development. Last updated: 2026-10-08.*

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
- Languages other than English as the learning language.

---

## 2. Users and platform

- **Primary user:** the author, learning English with Russian as the native language.
- **Secondary users:** anyone learning English who wants a private, offline word list with smart autofill. Native language is configurable.
- **Platform:** iPhone, iOS 26+, SwiftUI. iPad and Mac may work "for free" via SwiftUI but are not a target.
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
| A1 | Use the Foundation Models framework (on-device model) with guided generation (`@Generable`) to produce a structured card: senses, each with part of speech, definition, translation, synonyms, antonyms, examples. | M |
| A2 | Generate examples for the grammar topics the user has selected as "currently learning" (see 4.5). At least one example per selected topic per sense, plus one neutral example. | M |
| A3 | Pronunciation (IPA) if the model can produce it reliably; otherwise skip. To be validated in the prototype. | S |
| A4 | Every generated field is marked `source = auto`. When the user edits a field it becomes `source = user` and is never overwritten by a later re-generation. | M |
| A5 | "Regenerate" action per card and per field. | S |
| A6 | If the model is unavailable (unsupported device, Apple Intelligence off, region restriction), the card opens empty for manual entry, with a one-line explanation. No crash, no dead end. | M |
| A7 | Generated content is shown as editable draft. The small on-device model will sometimes be wrong, especially for rare words, idioms and translations; the UI should not present it as authoritative. | M |
| A8 | Pluggable model layer: the autofill code talks to a small internal protocol, so a cloud model (Claude, OpenAI, …) or the iOS 27 third-party provider API can be plugged in later without rewriting the feature. | S |

### 4.3 Word card

| # | Requirement | Pri |
|---|---|---|
| W1 | Card shows: word, image, pronunciation, and a list of senses. Each sense: part of speech, definition, translation, synonyms, antonyms, examples (with grammar-topic badges). | M |
| W2 | Every field is editable inline. Senses and examples can be added, removed, reordered. | M |
| W3 | Delete word (with undo or confirmation). | M |
| W4 | User note and tags/collections (e.g. "IELTS", "work", "The Expanse"). | S |
| W5 | Text-to-speech pronunciation via `AVSpeechSynthesizer` (works offline, no extra assets). | S |
| W6 | Word forms (book → books, booked, booking) shown on the card. | L |

### 4.4 Images

| # | Requirement | Pri |
|---|---|---|
| I1 | Generate an illustration on device with the Image Playground framework (`ImageCreator`). The prompt is a short visual description produced by the language model, not the raw word. | M |
| I2 | Fallback / alternative: pick from photo library or take a photo. | M |
| I3 | Image generation runs in the background after the card is saved; the card shows a placeholder until ready. | M |
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
| S1 | Native language for translations. Asked once on first launch, with the system language preselected when it is in the supported list (otherwise Russian). Changeable later in Settings. Initial list: Russian, Uzbek; others addable later. Changing the language does not retranslate existing cards automatically; it only affects new autofill (a "retranslate" action may come later). | M |
| S2 | Grammar topics currently being learned (see G2). | M |
| S3 | Export all data as JSON (and import). This is the user's safety net since there is no cloud. | M |
| S4 | "Support the developer" screen with tip-jar in-app purchases (consumables). | S |
| S5 | Toggle for automatic image generation. | S |

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

Sense
  id: UUID
  word: Word
  partOfSpeech: enum (noun, verb, adjective, adverb, phrase, other)
  definition: String
  translation: String?
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
  nativeLanguage: String   (BCP-47, e.g. "ru", "uz")
  learningLanguage: String (always "en" in v1)
  activeGrammarTopics: [GrammarTopicID]
  autoGenerateImages: Bool
```

Design notes:

- **Senses, not flat cards.** Everything that depends on meaning hangs off `Sense`. This is the one decision that is painful to change later.
- **Field provenance** (`fieldSources`) exists so that regeneration never clobbers user edits.
- **Soft delete + client UUIDs** cost nothing now and make iCloud sync and future export/import trivial.
- **Grammar topics are a static catalog**, referenced by string key, so the catalog can grow with app updates without data migration. Keys are namespaced by learning language (`en.present_perfect`) because grammar catalogs are language-specific.
- **`learningLanguage` is stored but fixed to `"en"` in v1.** It costs nothing now and means that adding another learning language later is a content task (a new grammar catalog, prompts, a test word list), not a data migration.
- **Review events are a log**, so two devices reviewing offline merge cleanly once sync exists.

---

## 6. Non-functional requirements

| Area | Requirement |
|---|---|
| **Privacy** | No network calls in v1. No analytics, no crash reporting SDKs from third parties. Privacy policy can honestly say "we collect nothing". |
| **Offline** | Everything works offline, including autofill and image generation (both on device). |
| **Availability fallback** | Every AI feature checks availability at runtime (`SystemLanguageModel.default.availability`, Image Playground availability) and degrades to manual entry. The app must be fully usable on an iPhone without Apple Intelligence. |
| **Performance** | Saving a word is instant (< 100 ms perceived). Autofill target: under ~10 s on supported devices, run as a background task with visible progress. Image generation may take longer; it never blocks the UI. |
| **Data safety** | JSON export/import from day one. Data lives in the app container and is included in iCloud device backups by default. |
| **Accessibility** | Dynamic Type and VoiceOver labels on the card and list. |
| **Localization** | UI in English first; Russian UI later. The *content* language (translations) is independent of the UI language. |
| **Model drift** | Apple may update the on-device model with any iOS release; output can change. Prompts are kept in one place and covered by a small set of manual regression checks (a list of ~20 words with expected shape of output). |

---

## 7. Technology

| Layer | Choice | Why |
|---|---|---|
| UI | SwiftUI, iOS 26+ | Target platform; modern APIs. |
| Persistence | SwiftData | Native, simple, CloudKit-ready. No server, so no need for GRDB-level control. |
| Autofill | Foundation Models framework, guided generation | On device, free, offline, structured output. |
| Images | Image Playground framework (`ImageCreator`) + PhotosPicker + camera | On device, free. |
| Siri | App Intents / App Shortcuts | The only supported way to add Siri phrases. |
| Speech | AVSpeechSynthesizer | Offline pronunciation without audio assets. |
| Payments | StoreKit 2, consumable tip products, `ProductView` | Tip jar. |
| Sync (later) | SwiftData + CloudKit | Free, no backend, same Apple ID across devices. |
| Spaced repetition (later) | FSRS (Swift port) | Modern algorithm, open source. |

Architecture: plain MVVM-ish SwiftUI with a thin service layer (`AutofillService`, `ImageService`, `WordStore`). The autofill service is behind a protocol (`CardGenerator`) with the Foundation Models implementation as the first and only one in v1.

---

## 8. Roadmap

### v1 — "It fills itself in"

Capture (C1, C2, C4, C5) · Autofill (A1, A2, A4, A6, A7) · Card (W1–W3) · Images (I1–I4, I6) · Grammar topics (G1, G2, G4) · List & search (B1) · Settings (S1–S3).

Done when: the author uses it daily for a month and prefers it to a spreadsheet.

### v1.1 — Polish

Share sheet (C3), capture note (C6), tags (W4), TTS (W5), regenerate (A5), browse by topic (G3, B2), tip jar (S4), image toggle (S5), App Store release, landing page.

### v2 — Learning

Flashcards (L1), FSRS (L2), reminders (L4), stats (L5), then grammar drills (L3). iCloud sync.

### Later / maybe

Widget (C7), word forms (W6), full-text search (B3), Russian UI, iOS 27 third-party model providers (A8), macOS.

---

## 9. Monetization and distribution

- **Free app, no feature gates.** Costs are limited to the Apple Developer Program fee (~$99/year), since AI runs on device.
- **Tip jar** via consumable in-app purchases (StoreKit). Tips may unlock cosmetic thanks (alternate app icons, a "Supporter" badge). Inside the app, donations go through Apple only; the landing page may link to other donation methods, but the app must not link to the landing page's donation section.
- **Open source** under a permissive license, decided at first release. The code is open; the name *Wordhoard*, the icon and other brand assets are not covered by the code license.
- **Landing page** on GitHub Pages: description, App Store badge, support/privacy pages (both required by App Store Connect), optional donation links.
- A paid "Pro" one-time purchase remains possible later if the app ever gains features that cost the developer money (cloud model, own sync server). Going from free to free+Pro is acceptable; the reverse is not.

---

## 10. Open questions and things to validate early

These decide whether the plan holds. Each should be answered by a throwaway prototype before building the real app.

1. **Autofill quality.** Does the on-device model produce usable definitions, synonyms and grammar-tagged examples for common words? For idioms and rare words? Test with ~20 words of varying difficulty.
2. **Translation quality.** Russian is not an officially supported Apple Intelligence language. If translations are poor, options are: skip translation in autofill (manual only), use Apple's Translation framework (on device, supports Russian), or a cloud model later.
3. **Siri recognition.** Does Siri reliably capture an English word when the device/Siri language is Russian, and vice versa? Also: does the two-step "add a word → which word?" dialog feel acceptable?
4. **Image Playground.** Is it available in the author's region and on the author's device? How often does it refuse prompts? Are the available styles acceptable for vocabulary cards?
5. **Latency.** How long does a full card (multiple senses, several examples) take to generate on an iPhone 15 Pro vs 17 Pro? Does it need to be split into several smaller generations (senses first, then examples per sense) to show progress?
6. **IPA.** Can the model produce correct IPA, or should pronunciation be text-to-speech only?
7. **Free vs paid developer account.** Confirm that Foundation Models, Image Playground and App Intents all work when the app is signed with a free personal team (no CloudKit, no push).

---

## 11. Deferred decisions and rejected options

Kept so that future-us remembers why.

| Option | Status | Reason |
|---|---|---|
| NestJS backend + PostgreSQL | Deferred | Not needed when AI runs on device. Adds hosting cost, auth, sync, and ops for a one-person project. Revisit only if a feature truly needs a server. |
| Web app (React/Vite, offline via IndexedDB) | Deferred | Browser storage is unreliable (Safari evicts data); a web client without a backend would be two unsynced dictionaries. |
| Telegram bot | Deferred | Requires a server. Could return as a paid feature if a backend ever exists. |
| Cloud LLM autofill (Claude/OpenAI) | Deferred | Costs money per word; would force a subscription. On-device model is free. Kept behind a protocol so it can be added. |
| Subscription | Rejected for now | No recurring costs to justify it; users dislike subscriptions for simple tools. |
| Shared global lexicon vs personal words | Personal words | No server, so no sharing. Each user's cards are fully their own. |
| Own sync protocol (delta sync, cursors, LWW) | Replaced by CloudKit | Only Apple devices are targeted; CloudKit is free and needs no server. |
| GRDB instead of SwiftData | SwiftData | GRDB was suggested for custom sync with an own server. With CloudKit, SwiftData is the simpler fit. |
| Next.js | Not applicable | No web app. |
| GPL license | Rejected | Incompatible with App Store distribution in practice. |

---

## Appendix A — Grammar topic catalog (initial)

Keys are stable identifiers; display names may be localized later.

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
