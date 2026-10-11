# Free resources survey

*Researched 2026-10-11. Scope: datasets, Apple frameworks, Swift libraries and online services that a free, offline-first, Apache-2.0-licensed iOS app can use without the developer paying per use. "Verdict" is about fit for Wordhoard, not general quality. Items marked **(verify)** were not confirmed against a primary source during this pass.*

## 1. Summary and recommendations

| Need | Use now (v1, offline) | Consider later |
|---|---|---|
| Sense inventory, POS, synonyms, antonyms, example sentences | **Open English WordNet 2025** (CC BY 4.0) — already in the spike | Wiktionary-derived data for modern senses and phrasal verbs (CC BY-SA, large) |
| Learner definitions, example sentences per grammar topic | **On-device Foundation Models** (free, offline) | **Private Cloud Compute model** on iOS 27 — free to the developer, stronger, 32K context (§3.2) |
| Translation EN→RU | **Apple Translation framework** (on-device, Russian supported; Uzbek **not** supported) | Wiktionary translations as a static fallback; cloud translation for Uzbek |
| Pronunciation | `AVSpeechSynthesizer` (offline voices); **ipa-dict** for IPA text (MIT; en_UK part is GPL-derived — use en_US only or verify) | — |
| Frequency / level | **NGSL 1.2** (CC BY-SA 4.0, 2,809 words) for "common word" ranking; **FrequencyWords** (CC BY-SA 4.0) | CEFR lists are mostly proprietary — skip |
| Spaced repetition | Implement **FSRS** from the public algorithm spec; existing Swift ports are small and stale (§4.1) | — |
| Images | Image Playground on device; user photos | Unsplash / Pexels / Openverse with attribution (online tier) |
| Cloud LLM without developer cost | — (v1 is offline) | PCC entitlement (best); Gemini free tier via iOS 27 adapters; BYOK has App Store risk (§6) |

Three things that change earlier assumptions:

1. **Apple's server model is available to third-party apps on iOS 27** (`PrivateCloudComputeLanguageModel`), with no API key and no cloud cost to an eligible developer; users get a daily quota and can buy more via iCloud+. Eligibility: App Store Small Business Program, < 2M first-time downloads, a managed entitlement granted on request. This supersedes the earlier note in the conversation that "the server model is not exposed". It needs a paid developer account, iOS 27, Apple Intelligence and a network connection, so it is an *upgrade path*, not a replacement for the WordNet + on-device design.
2. **Translation framework does not support Uzbek.** Native-language = Uzbek will need manual translation or an online service.
3. **BYOK (user's own API key) has been rejected by App Review under 3.1.1** in at least one documented case. Not a safe plan for the App Store version.

## 2. Lexical datasets (offline, bundleable)

### 2.1 Open English WordNet (OEWN)
- **What:** ~152k lemmas, ~115k synsets; POS, glosses, synonyms, antonyms, hypernyms; example sentences on many synsets (one per synset is what the spike bundles). Multi-word entries exist (`look up`, `give up`); idioms are sparse (`by the book` is absent).
- **Editions:** 2024 (used in spike), **2025** (dated 2025-12-31) and **2025+** (adds curated proper nouns from Open English Namenet). Formats: WN-LMF XML, RDF/Turtle, WNDB, and a JSON export for 2025 editions. No official SQLite build. [en-word.net/downloads](https://en-word.net/downloads), [github.com/globalwordnet/english-wordnet](https://github.com/globalwordnet/english-wordnet)
- **License:** CC BY 4.0 → bundleable; attribution required in-app ("Open English WordNet, CC BY 4.0").
- **Weaknesses seen in the spike:** terse glosses; no frequency counts in LMF (sense order is the only rank); missing recent senses (*gaslight* v.); function words covered only as nouns (*despite*) — hence the stoplist.
- **Verdict:** keep. Consider moving to the 2025 edition and the JSON export before Phase 1.

### 2.2 Wiktionary via wiktextract / kaikki.org
- **What:** machine-readable English Wiktionary: senses with glosses and examples, forms, IPA, audio links, translations (Russian and Uzbek present for common words), synonyms/antonyms. Far broader than WordNet on phrasal verbs, idioms, slang and new senses. [github.com/tatuylonen/wiktextract](https://github.com/tatuylonen/wiktextract), [kaikki.org English](https://kaikki.org/dictionary/English/index.html)
- **Size:** English JSONL is **3.1 GB** raw (1.39M word forms). A trimmed build (top ~30–50k lemmas, glosses + examples + ru/uz translations only) would plausibly land at 20–60 MB; needs a conversion script and a size budget decision.
- **License:** Wiktionary text is **CC BY-SA 4.0 (+ GFDL)**. Bundling is allowed; the bundled data stays CC BY-SA and must be attributed; app code stays Apache 2.0. The kaikki page itself states no license and asks for a citation of Ylonen (LREC 2022). The main download is marked deprecated in favour of processing raw data yourself.
- **Verdict:** best candidate for (a) EN→RU/UZ static translations and (b) filling WordNet gaps. Not for v1 — the conversion and size work is a task of its own. Open an issue when WordNet gaps start to hurt.

### 2.3 Pronunciation
- **ipa-dict** ([open-dict-data/ipa-dict](https://github.com/open-dict-data/ipa-dict)): tab-separated word→IPA; en_US (from cmudict-ipa + syllabify) and en_UK (RP). Repo is MIT, but **en_UK derives from ipacards (GPL 3.0)** — treat en_UK as GPL-tainted unless verified otherwise; en_US is safe.
- **CMUdict** (BSD-style): ARPAbet, not IPA; convertible. [cmusphinx/cmudict](https://github.com/cmusphinx/cmudict)
- **Model IPA:** unreliable (spike: `/ˈhʌvər/`). Do not use.
- **Verdict:** TTS via `AVSpeechSynthesizer` for v1; add ipa-dict en_US text later if users ask for IPA.

### 2.4 Example sentences
- **Tatoeba:** weekly exports; sentences **CC BY 2.0 FR**, a subset CC0; EN–RU link pairs available via custom export. Quality varies (user-contributed); filter by native-speaker flag and length. [tatoeba.org/downloads](https://tatoeba.org/en/downloads)
- **OEWN synset examples:** already bundled; one per synset.
- **Verdict:** Tatoeba is useful as (a) a regression corpus for grammar-tagging heuristics and (b) a fallback "real sentence" when the model refuses. Not needed for v1.

### 2.5 Frequency and level lists
- **NGSL 1.2** — 2,809 core words with frequency stats, CSV/TXT/XLSX, **CC BY-SA 4.0**. Also NAWL (academic), NGSL-S (spoken). No CEFR levels. [newgeneralservicelist.com](https://www.newgeneralservicelist.com/new-general-service-list)
- **FrequencyWords** (OpenSubtitles 2018, en_50k) — code MIT, **data CC BY-SA 4.0**. [github.com/hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords)
- **Oxford 3000/5000, English Vocabulary Profile, CEFR-J** — proprietary or restricted **(verify)**; skip.
- **Verdict:** NGSL for "is this a common word" badges and sense ranking tie-breaks; small, cheap, attributable.

### 2.6 Not recommended
- **FreeDict eng-rus / Apertium bilingual dictionaries** — GPL **(verify per package)**; GPL data in an Apache app is legally awkward and the quality is dated.
- **Free Dictionary API's data** — see §5; GPL-3.0 code, unclear data provenance.

## 3. Apple frameworks

### 3.1 Foundation Models, on-device (`SystemLanguageModel`)
- iOS 26+, Apple Intelligence devices (iPhone 15 Pro and later). 4K context, no reasoning, unlimited use, offline. `@Generable` guided generation, tools, streaming. Guardrails can refuse ordinary words (spike: *gaslight*).
- iOS 27 adds the `LanguageModel` / `LanguageModelExecutor` protocols so sessions can target other models with the same API (WWDC26 session 339). [Session 339](https://developer.apple.com/videos/play/wwdc2026/339)
- **Verdict:** the baseline; everything must work on it.

### 3.2 Foundation Models, Private Cloud Compute (`PrivateCloudComputeLanguageModel`) — iOS 27
- **Capabilities:** 32K context, reasoning levels (light / moderate / deep), same session API; one-line switch. Requires network and Apple Intelligence; falls back to on-device by `#available` and on network failure. [Apple: Adding server-side intelligence with PCC](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute.md)
- **Cost:** **no cloud API cost to the developer.** Users have a **daily request limit** (numbers unpublished; vary by feature and demand) and can raise it via **iCloud+**. The framework exposes `quotaUsage` and a system upgrade sheet.
- **Eligibility:** App Store Small Business Program + fewer than 2M first-time downloads + a **managed entitlement** requested via a form; must migrate within 6 months if you outgrow it. Apple says broader access "will be available for a fee in the future." [developer.apple.com/private-cloud-compute](https://developer.apple.com/private-cloud-compute/)
- **Implications for Wordhoard:** a "better cards when online" mode for iOS 27 users at zero developer cost: sense selection and learner definitions from the 32K model could replace much of the prompt engineering the 4K model needs. Still requires a paid developer account (entitlement is per account) and the WordNet + on-device path for iOS 26 and offline. Candidate for v1.1; record as an ADR when the entitlement is granted.

### 3.3 Third-party cloud models through Foundation Models (iOS 27)
- Google ships Gemini as a Firebase AI Logic package (`FirebaseAILogic`, iOS 27+): structured output, tools, streaming; needs a Firebase project and App Check; the **Gemini Developer API free tier** applies, paid beyond it — **the developer's project pays**, not the user. [firebase.blog](https://firebase.blog/posts/2026/06/apple-foundation-models-gemini)
- Anthropic is said to be building a Claude package; no public details on credentials found. Apple's guidance to package authors: avoid raw API-key initializers, use token providers / sign-in, Keychain, App Attest.
- **Verdict:** only viable free path here is Gemini's free tier on the developer's own project, which (a) is rate-limited per project, not per user, so it will not scale, and (b) uses prompts "to improve Google products" on the free tier. Not for a privacy-first app; PCC is the better zero-cost option.

### 3.4 Translation framework
- `TranslationSession`: iOS 18+; **`init(installedSource:target:)` (no UI needed) — the spike uses it**; batch APIs; `prepareTranslation()` to trigger language downloads; `isReady`, `canRequestDownloads`; `preferredStrategy`. All processing on device. Does **not** run in the Simulator. [Apple docs](https://developer.apple.com/documentation/translation/translationsession.md)
- **Languages (offline):** Russian ✅ (since 2020). **Uzbek ✗.** Ukrainian, Turkish, Polish, Hindi and others ✅. [Wikipedia: Translate (Apple)](https://en.wikipedia.org/wiki/Translate_(Apple))
- **Verdict:** primary translation path for Russian. For Uzbek: manual entry in v1; later Wiktionary static translations or an online service with consent.

### 3.5 Other
- **Image Playground** (`ImageCreator`): on device; styles are illustrative only; refusals possible. Per spike task #5.
- **NaturalLanguage:** `NLTagger` POS/lemma, `NLEmbedding` similarity — useful for grammar-heuristic checks in the regression runner and for duplicate detection.
- **AVSpeechSynthesizer:** offline English voices; sufficient for pronunciation in v1.
- **System dictionary:** `UIReferenceLibraryViewController` shows the sheet and `dictionaryHasDefinition(forTerm:)` answers yes/no; **no programmatic access to definitions on iOS.** Add a "Look up in Dictionary" button; cannot autofill from it.
- **Shortcuts "Use Model"** (iOS 26): on-device / PCC / ChatGPT from a Shortcut. A user could build a personal shortcut, but an app cannot invoke it to fill cards; not a product path.

## 4. Swift libraries

### 4.1 Spaced repetition
- **4rays/swift-fsrs** — MIT, v0.9.2, last activity ~2 years ago, 34 stars, FSRS version unstated. [Swift Package Index](https://swiftpackageindex.com/4rays/swift-fsrs)
- **bootuz/SwiftFSRS** — exists; status not checked **(verify)**.
- **tosbaha/SMLib** — SM-2, 7 years old.
- Algorithm reference and parameters: [open-spaced-repetition](https://github.com/open-spaced-repetition) (FSRS-6 spec, awesome-fsrs list).
- **Verdict:** write our own ~300-line FSRS-6 scheduler in `WordhoardCore` from the spec, with tests against the reference implementation's published test vectors. Safer than depending on an unmaintained port; keeps the review log model (`ReviewEvent`) ours.

### 4.2 Storage
- **SwiftData** (planned) for user data. For the read-only WordNet bundle the spike loads JSON in 0.4 s — fine for now; if memory becomes a concern, **GRDB.swift** (MIT) with a prebuilt SQLite + FTS5 is the standard choice. SQLite.swift (MIT) is the lighter alternative.

### 4.3 Tooling (all permissive)
- XcodeGen (MIT), SwiftFormat (MIT), SwiftLint (MIT), swift-snapshot-testing (MIT) if UI snapshots are ever wanted.
- Device CLI: `xcodebuild test -destination 'platform=iOS,name=…'`, `xcrun devicectl`, `xcrun xcresulttool` — used by task #14.

### 4.4 On-device open models (fallback consideration only)
- MLX Swift (MIT) and llama.cpp bindings (MIT) can run Qwen/Gemma/SmolLM-class models; smallest useful ones are 0.5–2 GB. Doubles app size, drains battery, and the App Store cellular-download limit makes it an on-demand download. **Not worth it** while Apple's model + WordNet works; revisit only if Apple Intelligence availability in target regions turns out to be a blocker.

## 5. Online APIs (for an optional online tier; none for v1)

| Service | Gives | Free terms | Verdict |
|---|---|---|---|
| **Free Dictionary API** (dictionaryapi.dev) | senses by POS, examples, IPA, audio URLs | no key; no stated limits; GPL-3.0 code; data provenance not stated (appears scraped); maintainer reports server-cost strain, no SLA | **avoid** as a dependency; unclear data license |
| **Wiktionary REST / MediaWiki API** | definitions, translations | free; needs a descriptive User-Agent; CC BY-SA content; be gentle with rate | usable with attribution, for lookups not bulk |
| **Merriam-Webster Learner's / Collegiate API** | learner definitions, audio | key; ~1,000 req/day; non-commercial; caching restricted **(verify current terms)** | usable for a personal build; terms likely block a public app |
| **Datamuse** | related words, rhymes, "means like" | no key; ~100k req/day **(verify)** | usable for synonym suggestions |
| **Tatoeba API** | example sentences | CC BY 2.0 FR | usable with attribution |
| **LibreTranslate** (public instances) | translation incl. some low-resource languages | public instances rate-limited; self-host possible | fallback for Uzbek if a trustworthy instance exists |
| **DeepL API Free / Microsoft Translator free** | high-quality translation | keys; monthly character quotas; may need a card **(verify)** | keys cannot ship in an open-source app → only via developer backend |
| **Unsplash** | photos | attribution + link with UTM, must hotlink `photo.urls`, call `download_location` on save; no unofficial-client use; no stated caching rules | usable with care; caching on device is a grey area |
| **Pexels / Pixabay / Openverse** | photos | attribution rules vary; Openverse returns CC works with per-image attribution | usable; Openverse best for license clarity |

Any online feature that sends user text to a third party now needs an explicit, provider-named, revocable consent screen **before the first request** (App Store Review Guideline 5.1.2(i), in force since 2025-11-13). [Summary](https://stora.sh/blog/2026-05-06-apple-ai-consent-rule-5-1-2-i-implementation-guide)

## 6. Cloud LLMs without the developer paying

| Path | How it works | Who pays | Risks | Verdict |
|---|---|---|---|---|
| **Apple PCC (iOS 27)** | `PrivateCloudComputeLanguageModel()`, same API | nobody; user quota, iCloud+ for more | entitlement eligibility; iOS 27 only; network | **best option** — pursue once a paid developer account exists |
| **BYOK** (user pastes own Anthropic / OpenAI / Google / OpenRouter / Groq key) | app stores key in Keychain, calls the API | the user | **App Review has rejected BYOK under 3.1.1** ("unlocks functionality outside IAP") in a documented case ([forum thread](https://developer.apple.com/forums/thread/763884)); outcome depends on the reviewer; 5.1.2(i) consent needed | high risk for the App Store build; fine for a TestFlight/personal build |
| **Free tiers on the developer's own account** (Gemini API, Groq, OpenRouter `:free`, Mistral, Cloudflare Workers AI) | developer's key behind a backend | developer (free until limits) | Gemini free tier: Flash models free, limits unpublished, **prompts used for training**; OpenRouter free: 20 req/min, **50 req/day** (1,000 after a $10 top-up); Groq: ~14,400 req/day on small models; all are per-key, so they do not scale past a handful of users; needs a backend to hide the key | only for the author's own use or a closed beta |
| **"Sign in with ChatGPT/Claude"** | OAuth into the user's consumer subscription | the user's subscription | no public programme found that permits third-party apps to spend consumer-subscription quota; token reuse outside official clients is against ToS | not available |
| **Shortcuts "Use Model"** | user-made shortcut calls ChatGPT/PCC | user | cannot be invoked by the app to fill a card | not a product path |

Free-tier limit sources: [costbench comparison (2026-08)](https://costbench.com/best/best-llm-api-with-free-tier/), [Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing), [OpenRouter limits](https://openrouter.ai/docs/api-reference/limits).

## 7. License compatibility cheat sheet (Apache 2.0 app)

| Data/code license | Bundle? | Obligation |
|---|---|---|
| MIT / BSD / Apache 2.0 | yes | keep notices |
| CC0 / public domain | yes | none (credit anyway) |
| CC BY 4.0 (OEWN, Tatoeba) | yes | attribution in-app (About screen) and in repo |
| CC BY-SA 4.0 (Wiktionary, NGSL, FrequencyWords) | yes | attribution; **the bundled data file stays CC BY-SA**, any modified data you ship must be CC BY-SA too; code unaffected |
| CC BY-NC | no for a public app | — |
| GPL / AGPL data or libraries | avoid | would force the app's license |

Attribution screen (Phase 5/6) must list: Open English WordNet (CC BY 4.0), plus NGSL / FrequencyWords / Wiktionary if adopted.

## 8. Open questions to verify before relying on them
1. PCC entitlement: turnaround time and whether a free personal team can even apply (almost certainly no — paid account needed).
2. Actual daily PCC quota per user for a small structured-output workload.
3. OEWN 2025 JSON export: does it carry more synset examples than 2024? Size?
4. Merriam-Webster Learner's API current terms on caching and commercial use.
5. ipa-dict en_UK provenance (GPL?) — or use en_US only.
6. Whether Translation framework `preferredStrategy` on iOS 26 offers an LLM-backed strategy and how it affects quality for single-sentence learner definitions.
