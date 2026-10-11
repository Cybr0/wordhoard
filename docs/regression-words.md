# Regression word list

Run the card generator over these words whenever a prompt changes, and in the Phase 0 spike. Paste a summary of the results into the PR (or, for the spike, into ADR 0001). Native language for the run: Russian (the author's test language only — not a product default; the app never preselects a language other than the system one). Add two or three words in Spanish and Chinese (Simplified) runs once the runner exists, to catch crashes rather than to judge quality. Active topics: `present_perfect`, `second_conditional`, `passive_voice`.

The list is chosen to probe specific weaknesses, not to be representative. Each word has a note on what to look at.

| # | Word | Why it is here | What to check |
|---|---|---|---|
| 1 | book | polysemous, common | two senses (noun, verb); examples actually in the requested tenses |
| 2 | run | highly polysemous | does the model cap senses sensibly (≤ 4) rather than listing twelve? |
| 3 | light | noun / adjective / verb | part-of-speech labels correct per sense |
| 4 | set | the classic dictionary monster | model does not hang or produce a wall of senses |
| 5 | apple | concrete noun | image prompt is sensible; translation trivially correct |
| 6 | however | abstract, function word | one sense; `imagePrompt` should be `nil`; examples still tagged |
| 7 | despite | abstract preposition | same as above; passive-voice example is hard here — does it force one or skip? |
| 8 | achieve | abstract verb | translation quality (достигать / добиваться); synonyms not circular |
| 9 | look up | phrasal verb, two meanings | treated as one headword; senses: search for info / raise eyes |
| 10 | give up | phrasal verb | not split into "give" + "up" |
| 11 | by the book | idiom | one sense, idiom marked as `phrase`; no literal "book" definition |
| 12 | break the ice | idiom | same; translation is the idiomatic equivalent, not literal |
| 13 | ubiquitous | rare-ish adjective | definition accuracy; synonyms plausible (omnipresent, pervasive) |
| 14 | serendipity | rare noun, no exact Russian equivalent | how the model handles an untranslatable word |
| 15 | gaslight | recent sense (verb) | does it know the modern meaning or only the lamp? |
| 16 | lead | heteronym (verb /liːd/, noun /lɛd/) | pronunciation per sense if IPA is produced; senses not merged |
| 17 | read | irregular, same spelling past/present | present_perfect example uses "have read" correctly |
| 18 | affect | commonly confused with "effect" | definition doesn't drift into "effect" |
| 19 | bookkeeper | compound, three double letters | spelled correctly in examples |
| 20 | xylophone | rare, concrete | image prompt works; translation ксилофон |
| 21 | asdfgh | not a word | model says so (empty senses / error) rather than inventing a meaning |
| 22 | Tashkent | proper noun | handled gracefully — either refused as not a vocabulary word or one sense, no invented etymology |

Expected results changed by decision (ADR 0001; the "What to check" column above is kept as written so the runner's table parsing is untouched):

- **look up** — one sense, *seek information from*, is the correct result. "Raise one's eyes" is compositional, not a WordNet entry, and the model never adds senses to a lemma WordNet knows (#11 decision 2).
- **gaslight** — WordNet has the noun (lamp) only; the verb is an accepted WordNet gap in v1, shown as a flagged pass. The writing call for this word is also refused by the guardrail in every run; the gloss is kept (A6).
- **despite** — expected one `preposition` sense, *in spite of*, once plan 2.7 (#19) adds the case; until then it fails (`adverb` in 6/6 runs).
- **however**, **despite** — reach the model via the function-word stoplist, never WordNet; the path must say so.
- **by the book**, **break the ice**, **asdfgh** — not in the bundle; model-only fallback with verifier. **asdfgh** must end in "Not found", not an invented sense.
- **Tashkent** — WordNet has it as a proper noun ("the capital of Uzbekistan"); one sense, nothing invented, counts as a pass.
- Judged target per run: the 12 key words of issue #14 (book, run, light, look up, give up, by the book, however, despite, lead, gaslight, asdfgh, Tashkent).

## What to record per run

For each word: number of senses, whether each requested topic got an example, obvious errors (wrong tense, wrong meaning, wrong translation), latency. A short table is enough; verbatim output only for words that misbehaved.

## Known results

| Date | iOS | Device | Prompt version | Summary | Where |
|---|---|---|---|---|---|
| 2026-10-11 | 27.0.1 | iPhone 15 Pro Max (iPhone16,2) | `665d06d` (= merged state after PR #17; WordNet + model, 2 senses per POS, 4 total, decision A) | mechanical 141/164 = 86.0 %; judged 10/12 — failing: run (→ *manage* not in the top-4), despite (→ `adverb`); first card median ≈ 8–10 s (7.6–9.9 s across the six runs); full card median ≈ 14 s, max ≈ 42 s, 7 words over 30 s; guardrail refusals on run, gaslight, Tashkent | issue #14 final scorecard (run 5) · ADR 0001 appendix A/B |
