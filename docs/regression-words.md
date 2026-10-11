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

## What to record per run

For each word: number of senses, whether each requested topic got an example, obvious errors (wrong tense, wrong meaning, wrong translation), latency. A short table is enough; verbatim output only for words that misbehaved.

## Known results

| Date | iOS | Device | Prompt version | Summary | Where |
|---|---|---|---|---|---|
| — | — | — | — | not run yet | — |
