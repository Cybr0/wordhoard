# 0001 — Spike results: adjust the autofill architecture

Date: 2026-10-11 · Status: accepted

## Context

Phase 0 (plan 0.1–0.11; issues #1–#7, #11, #14, #15; PRs #9, #12, #13, #16, #17) had to answer `requirements.md` §10 Q1–Q7 before Phase 1: can the on-device Foundation Models model fill a usable card, how should Russian be translated, how long does a card take and must it be split, can IPA come from the model, and — added mid-spike — whether Apple's Private Cloud Compute (PCC) is usable. Evidence: device runs on the author's iPhone 15 Pro Max (iPhone16,2), iOS 26 then 27.0.1; six full 22-word regression runs (#14); one WordNet device table (#11); one PCC probe (#15). Not run in Phase 0: images (#5), Siri (#6); free-team signing (#7) was only observed for the on-device model.

## Decision

Verdict: **adjust.** The product stands (requirements §1, §8), but the autofill design behind the original A1 — one guided-generation call that produces the whole card, with the model supplying senses, translations and IPA — is replaced. Why, one line each: a single call overflowed the 4 096-token context (*however*: 4 097 tokens) and mis-tagged grammar (#4); three prompt iterations never produced *book → reserve* and padded sense lists to the allowed count (#4); the model's Russian contained non-words ("ночальница") (#11); its IPA was wrong (`/ˈhʌvər/` for *however*) (#4); PCC crashes on the first request without the entitlement although `availability` reports `available` (#15). The adopted architecture, stated so the code can be checked against it:

1. **Sense inventory from bundled Open English WordNet 2024** (CC BY 4.0; JSON, 15 492 477 bytes = 14.8 MiB ≈ 15.5 MB; synsets deduplicated; up to 2 senses per part of speech and 4 in all, in WordNet order, nouns → verbs → adjectives → adverbs; one example sentence per synset). A stoplist of 385 function words (`function-words.txt`) bypasses WordNet and goes to the model-only senses call. A lemma WordNet lacks also goes to the model-only senses call, each sense checked by a yes/no verifier call; if every sense is rejected the card shows "Not found. Add senses manually." and nothing invented. When WordNet knows the lemma, its senses are the only senses: the model never adds one (#11 decision 2). Gaps are closed by manual sense editing (W2).
2. **On-device Foundation Models (4K context) write prose only**, one fresh `LanguageModelSession` per call: a per-sense learner definition from gloss + synonyms + the WordNet example; one neutral example per sense (required, defines "first card"); one example per sense × active grammar topic, the topic assigned by the caller and never classified by the model, optional per topic. No single-call cards. No model IPA: pronunciation comes from `AVSpeechSynthesizer` (W5). A guardrail refusal on one call keeps the WordNet gloss as the definition or drops that example; it never fails the card (A6).
3. **Translations come from Apple's Translation framework, never from the model.** Current (commit `665d06d`): the headword and every learner definition in one `translations(from:)` call. #22 replaces this with a 1–3-word equivalent per sense proposed by the model and accepted only when back-translation through the framework confirms it; a rejected proposal falls back to the translated definition, flagged. Synonyms and antonyms are not translated. Language pack missing → no translation and a note; the model is not a fallback.
4. **PCC is an entitlement-gated tier**, compiled in only when the build carries `com.apple.developer.private-cloud-compute`; `availability` alone is not a safe gate. Degradation order: PCC → on-device + WordNet → manual.
5. **iOS 27 minimum** (requirements §2): the PCC API and `LanguageModel` protocol, the `LanguageModelError` refusal cases the runner records, and the author's only test device runs iOS 27.
6. **The on-device regression runner** (`spike/WordhoardSpikeRegression`, #14) is the acceptance tool for every prompt change. Baseline at `665d06d`: judged 10/12, mechanical 86.0 %, first card median 7.6–9.9 s across runs, full card median 14.3 s.

## Consequences

**Easier.** Senses are deterministic for the ~152k lemmas WordNet knows — no invented senses where the lemma was found (#11, #14: 6/6 runs). Grammar is correct by construction because the caller assigns the topic. Each call is small, so the 4K context is never hit. Translation quality is the framework's, not the model's, and new native languages cost QA only (S1). Prompt changes are measured, not eyeballed.

**Harder or given up.** Known gaps: WordNet lacks recent senses (*gaslight* verb), prepositions and most idioms (*by the book*, *break the ice* → model-only); function words are model-only and *despite* comes back as `adverb` in 6/6 runs (#19); ≥ 3-sense words take 35–43 s for the full card (≈ 20 model calls at 1.6–1.8 s) (#20); guardrails refuse ordinary words (*run*, *gaslight*, *Tashkent*); the model substitutes a synonym for the headword in ~5 words per run and never uses the empty-string escape hatch (#21); the headword translation is wrong for phrasal verbs, idioms and heteronyms (*look up* → посмотреть вверх, *lead* → беспроводной) (#22); neither WordNet order nor SemCor counts give a good top-4 for *run* / *book* / *light* / *lead* at once (#18). The app bundle grows by ≈ 15.5 MB. Licensing: CC BY 4.0 requires attribution to Open English WordNet 2024 and Princeton WordNet in `NOTICE` (done) and on the About screen (S6, plan 5.3). PCC needs a paid account and a managed entitlement; until then the tier is compiled out. Not answered by the spike: §10 Q3 (Siri), Q4 (images), Q7 for Image Playground and App Intents — these move to the phases that build them (plan 4.2, 5.1).

**Revisit.** When the PCC entitlement is granted → re-run the PR #16 probe on device and write the server-tier ADR. When #18–#22 land → re-run the regression list; Phase 2 exit requires judged ≥ 10/12, mechanical ≥ 90 %, first card ≤ 10 s median. When WordNet gaps start to hurt → Wiktionary data (`docs/resources.md` §2.2) or the OEWN 2025 edition. Sense ranking under a cap of 4 is a product rule, not a prompt; the count-based code and data stay at `d2dfc41` for that decision.

---

## Appendix — raw tables

### A. Regression loop (#14, PR #17) — iPhone 15 Pro Max (iPhone16,2), iOS 27.0.1, 22 words, 3 topics

| run | commit | iteration | mechanical | judged | first card median (max) | full card median / max | over 30 s |
|---|---|---|---|---|---|---|---|
| 1 | `b6ed26e` | 0 — unchanged prompts, 2 per POS | 152/170 = 89.4 % | 10/12 | 7.6 s (34.6) | 12.5 / 70.5 s | 6 |
| 2 | `e73a52e` | 1 — definition-style writing prompt, POS rules, total cap 4 | 132/164 = 80.5 % | 9/12 | 9.5 s (20.3) | 12.8 / 41.5 s | 7 |
| 3 | `e73a52e` | 1 — same commit, noise re-run | 133/170 = 78.2 % | 9/12 | 8.3 s (21.5) | 13.5 / 42.4 s | 7 |
| 4 | `968acdb` | 2 — no literal "Empty", neutral worked examples, POS guide | 141/164 = 86.0 % | 10/12 | 9.9 s (21.3) | 13.5 / 42.7 s | 7 |
| 5 | `665d06d` | 3 = decision A: translate headword + definitions only, one call | 141/164 = 86.0 % | 10/12 | not reported separately | 14.3 / 41.9 s | 7 |
| 6 | `d2dfc41` | 4 = decision B: SemCor-ranked senses, cap 4 — **reverted** in `0b16922` | 141/164 = 86.0 % | 8/12 | 9.5 s (20.6) | 13.2 / 42.7 s | 8 |

Per model call ≈ 1.6–1.8 s; 4 senses × 5 calls ≈ 20 calls. Translation step on 4-sense words: 4.7–7.0 s (one batch per sense, iterations 0–2) → 2.7 s (one call, decision A). Loop stopped after five iterations (stop rule); merged state `ebddf71` = `665d06d` behaviour. Iteration 1's drop was self-inflicted: the words "empty string" in the example prompt made the model write the literal word "Empty" in 16–20 examples per run.

### B. Judged rows at the best commit `665d06d` (run 5; identical to run 4)

| word | expected (#14) | actual | verdict |
|---|---|---|---|
| book | noun; verb *reserve* | noun, noun, verb *engage for a performance*, verb "to set aside something for later use" | pass |
| run | verb *move fast*; verb *manage* | noun (score), noun (test), verb *move fast*, verb *flee* | **fail** — *manage* is WordNet verb 4, outside the 2-per-POS cut |
| light | noun; adjective; verb | noun, verb, adjective "easy to lift or carry", adverb | pass |
| look up | one verb, *search for information* | 1 verb "to search for facts or knowledge from a source" | pass |
| give up | one phrasal entry, *stop trying / surrender* | verb *forfeit*; verb "to stop trying to keep something you own" | pass |
| by the book | one `phrase`, idiomatic, via fallback | model-only: phrase "following rules or instructions exactly" — по правилам, точно | pass |
| however | stoplist; one adverb | stoplist: adverb "in spite of what has just been said" — несмотря на это | pass |
| despite | stoplist; one preposition sense | senses call returned `adverb` (6/6 runs, never `other`), verifier rejected it → not-found | **fail** — needs a `preposition` case (#19) |
| lead | ≥ 1 noun, ≥ 1 verb | noun, noun, verb "to show the way", verb (*produce as a result*, written badly) | pass |
| gaslight | noun *lamp*; verb absent, flagged | 1 noun, gloss kept (writing call refused by guardrail, 6/6 runs) | pass, WordNet gap |
| asdfgh | not found, nothing invented | not-found | pass |
| Tashkent | not found or refusal, nothing invented | WordNet noun "a city that is the main town of a country in Central Asia" | pass (vaguer than iteration 0) |

Headword translation at `665d06d`: correct for book → книга, run → бежать, light → свет, however → но, Tashkent → Ташкент; wrong for look up → посмотреть вверх, by the book → по книге, give up → отдать отчаян, lead → беспроводной.

Decision B facts (`d2dfc41`): the WNDB `index.sense` has 0 in every tag-count column; `cntlist.rev` is the only count source — 35 223 of 37 387 keys join a release sense, 21 290 of 152 286 lemmas get any counted sense. Under counts: *run* gains *direct or control* (20) but *book → reserve* (count 1, behind *engage* 3) drops out, *light* loses its verb (12, fifth), *lead* shows four verbs and no noun. Reverted.

### C. WordNet mode, first device run (#11, PR #13 as originally built — before the 2-per-POS cap, the stoplist, the WordNet example in the writing prompt and the Translation framework)

| word | WordNet | write step (gloss → definition + model translation) | examples | first / full |
|---|---|---|---|---|
| book | 3n + 3v in bundle, kept 3; *reserve* cut by the cap | *engage for a performance* → "rehearse" (wrong); translation "книга, текст, сценарий" for a verb | nonsense for the verb | 11.0 / 22.5 s |
| look up | 1 verb | ok | ok | 3.2 / 7.0 s |
| however | 3 adverb senses | translations "ночаль", "ночальница ×3" — not Russian | fine | 8.6 / 20.2 s |
| despite | 2 archaic nouns | "нечаростно" — not a word | "Despite were ignored…" | 5.9 / 13.7 s |
| gaslight | 1 noun (lamp) | write call refused by guardrails → gloss kept | passable | 1.7 / 6.7 s |
| by the book | not in OEWN → model-only | sense ok, translation half-right | ok | 7.7 / 11.6 s |
| asdfgh | not found → model-only | invented sense shown despite verifier "no" | garbage | 5.7 / 9.5 s |

Conclusions recorded there: sense inventory solved by WordNet; the write step misreads terse glosses (fixed by passing the WordNet example); model translation unusable (settled #3); guardrail fallback must stay.

### D. Pre-WordNet runs (#4) — iOS 26, iPhone 15 Pro Max

| build | word | result |
|---|---|---|
| single call (PR #9) | book | 26.8 s; 4 noun senses, 3 paraphrases, no verb; 3 of 3 grammar tags wrong; IPA `/bʊk/` fine |
| single call (PR #9) | however | failed: 4 097 tokens > 4 096 context |
| split calls (PR #10/#12) | book | first card 11.4 s / full 23.4 s (13 calls); grammar correct; verb sense "to write text" (wrong) |
| split calls | look up | 8.1 / 16.6 s; both senses; one forced passive |
| split calls | however | 9.9 / 22.1 s; sense 1 correct, 2 paraphrase, 3 invented noun; IPA `/ˈhʌvər/` wrong |
| iteration 2 + verifier (PR #12) | however / book / look up | 5.9/10.0 s · 9.9/14.0 s · 8.6/12.7 s; padding fixed; *reserve* never produced in 3 iterations; verifier 3/5 correct, 2 false negatives on *look up* |

### E. WordNet bundle sizes (PR #13; converter `spike/tools/convert_oewn.py`)

| variant | size |
|---|---|
| source: OEWN 2024 WN-LMF (`english-wordnet-2024.xml.gz`) | 12.9 MB gzipped / 102.6 MB XML; 161 705 entries, 212 478 senses, 120 630 synsets |
| 3 senses per POS, no examples | 13.8 MB |
| 2 per POS, no examples | 13.5 MB |
| 2 per POS + 2 examples per synset | 15.1 MB (over the 15 MB target) |
| **2 per POS + 1 example per synset (shipped)** | **15 492 477 bytes = 14.8 MiB ≈ 15.5 MB**; 152 286 lemmas, 187 520 senses, 110 623 synsets, 28 080 examples |
| decision B bundle (counts attached) — reverted | 15 059 124 bytes; 181k senses, 108k synsets |

Load: 0.4–0.8 s on the iPhone 17 simulator, Debug, `JSONDecoder`. Stoplist: 385 lemmas. Regression words not in the bundle: *by the book*, *break the ice*, *asdfgh*; *gaslight* noun only; *look up* one sense; *despite* only as an archaic noun.

### F. Private Cloud Compute probe (#15, PR #16, not merged) — iPhone 15 Pro Max, iOS 27, free personal team, no entitlement

| fact | value |
|---|---|
| `availability` | `available` — misleading |
| first request | process crash: `Fatal error: Missing entitlement: com.apple.developer.private-cloud-compute` (not a thrown error) |
| `quotaUsage` refresh | fails with `com.apple.tokengeneration error 24` while `availability` stays `available` |
| `contextSize` | 32 768 |
| capabilities | guidedGeneration, reasoning, toolCalling, vision |
| `supportedLanguages` | 24 (da, de, en, en-AU, en-GB, en-IN, es, es-419, …) |
| quota API | `quotaUsage.status`, `resetDate`, `limitIncreaseSuggestion.show()` present |
| entitlement | `com.apple.developer.private-cloud-compute`, managed, granted by Apple; no public key in the iOS 27.0 SDK |
| simulator | iOS 27.0 on macOS 26: `assetsUnavailable: Host is not running macOS 27`; on macOS 27.0.1: `unavailable(systemNotReady)`; `fm` CLI offers no `pcc` model |

Quality of PCC output: not measured — needs the entitlement.
