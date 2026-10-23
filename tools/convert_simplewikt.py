#!/usr/bin/env python3
"""Convert the Simple English Wiktionary extract into the compact JSON bundle the app reads.

Usage:
    python3 -I tools/convert_simplewikt.py <simple-extract.jsonl.gz> <simplewikt.json>
    python3 -I tools/convert_simplewikt.py --check <simplewikt.json> word [word ...]

Source: the wiktextract extract of the Simple English Wiktionary published by kaikki.org
(https://kaikki.org/dictionary/downloads/simple/simple-extract.jsonl.gz; Ylonen, "Wiktextract:
Wiktionary as Machine-Readable Structured Data", LREC 2022). Wiktionary text is CC BY-SA 4.0 (and
GFDL); the bundle is a modified extract and stays CC BY-SA 4.0 (CLAUDE.md licensing rules: data file
only, credited in NOTICE and on the About screen).

Why this source (Phase 7, owner feedback 2026-10-23): the owner wants a word's meanings in everyday
frequency order with rare ones left out, in learner-friendly words. WordNet's order is not frequency
order and the on-device model could not rank senses reliably on the iPhone (bank lost its money
sense, light its noun). Simple Wiktionary is written for learners, lists the common meanings first and
covers modern senses and phrases (gaslight, in respect of, despite).

What is kept, per lemma (lowercased, single spaces):
  - English entries only; proper names, abbreviations, affixes and symbols are dropped;
  - every sense in use, in page order (part-of-speech sections as the page lists them, senses in their
    order). Senses tagged "old, no longer used" or "rare" are dropped. Senses tagged with a specialised
    field (medicine, law, sports, ...) are dropped when the word has a general sense; a word with only
    specialised senses (a biology term) keeps them. No cap on the number of senses (owner, 2026-10-23:
    "take the meanings people actually use, not a fixed four");
  - per sense: part-of-speech code, the first gloss, the first example (or null), synonyms and
    antonyms (single words or short phrases).

Bundle shape (no whitespace):
    {"edition": "simplewikt-<date>", "lemmas": {"run": [["v", gloss, example|null, [syn], [ant]], ...]},
     "aliases": {"ran": "run", ...}}
    part-of-speech codes: n noun, v verb, a adjective, r adverb, p preposition, c conjunction,
    h phrase, o other
Standard library only; run with -I because the download is untrusted input.
"""

import gzip
import json
import re
import sys

POS_CODES = {
    "noun": "n",
    "verb": "v",
    "adj": "a",
    "adv": "r",
    "prep": "p",
    "conj": "c",
    "phrase": "h",
    "det": "o",
    "pron": "o",
    "intj": "o",
    "num": "o",
    "particle": "o",
    "article": "o",
    "contraction": "o",
}
DROPPED_TAGS = {"old, no longer used", "rare", "obsolete", "archaic"}
DEMOTED_TAGS = {
    "medicine", "chemistry", "law", "mathematics", "physics", "astronomy", "military", "sports",
    "music", "computing", "grammar", "biology", "geology", "linguistics", "religion", "finance",
    "economics", "botany", "zoology", "anatomy", "nautical", "baseball", "cricket",
    "football", "golf", "tennis", "chess", "card games", "poker", "biblical", "judaism",
}
NOISE = re.compile(r"\s*\[POS TABLE\]\s*")
# A gloss that only names a grammatical form ("The past tense of set.", "Plural of mouse.") is not a
# meaning; the base word's entry has the meaning.
FORM_OF = re.compile(
    r"^(an? |the )?(simple )?(past tense|past participle|present participle|simple past|past|plural|"
    r"singular|third[- ]person|comparative|superlative|gerund|alternative (spelling|form))\b[^.]*?"
    r"\bof\s+\"?([a-z][a-z' -]*?)\"?\s*[.;,(]",
    re.IGNORECASE,
)


def clean(text):
    return " ".join(NOISE.sub(" ", text).split())


def words(items):
    out = []
    for item in items or []:
        word = clean(item.get("word", ""))
        if word and len(word) <= 40 and word not in out:
            out.append(word)
    return out


def sense_tags(sense):
    return {tag.lower() for tag in sense.get("raw_tags", []) + sense.get("tags", [])}


def convert(source, target):
    lemmas = {}
    aliases = {}
    with gzip.open(source, "rt", encoding="utf-8") as stream:
        for line in stream:
            entry = json.loads(line)
            word, pos = entry.get("word"), entry.get("pos")
            if not word or entry.get("lang_code") != "en" or pos not in POS_CODES:
                continue
            key = " ".join(word.lower().split())
            general, special = [], []
            for sense in entry.get("senses", []):
                glosses = [clean(g) for g in sense.get("glosses", []) if clean(g)]
                if not glosses:
                    continue
                tags = sense_tags(sense)
                form = FORM_OF.match(glosses[-1] + ".")
                if form:
                    base = " ".join(form.group(5).lower().split())
                    if base and base != key:
                        aliases.setdefault(key, base)
                    continue
                if tags & DROPPED_TAGS or "no-gloss" in tags:
                    continue
                examples = [clean(e.get("text", "")) for e in sense.get("examples", [])]
                example = next((e for e in examples if e), None)
                row = [
                    POS_CODES[pos],
                    glosses[-1],
                    example,
                    words(sense.get("synonyms")),
                    words(sense.get("antonyms")),
                ]
                (special if tags & DEMOTED_TAGS else general).append(row)
            if not general and not special:
                continue
            # "may" before "May": the entry whose written form is already lowercase comes first.
            bucket = lemmas.setdefault(key, {"exact": [], "other": [], "special": []})
            bucket["exact" if word == key else "other"].extend(general)
            bucket["special"].extend(special)
    kept = {
        key: (bucket["exact"] + bucket["other"]) or bucket["special"]
        for key, bucket in sorted(lemmas.items())
    }
    # An inflected form with no meaning of its own points at its base word ("ran" -> "run").
    bundle = {
        "edition": "simplewikt-2026-10",
        "lemmas": kept,
        "aliases": {k: v for k, v in sorted(aliases.items()) if k not in kept and v in kept},
    }
    with open(target, "w", encoding="utf-8") as out:
        json.dump(bundle, out, ensure_ascii=False, separators=(",", ":"))
    senses = sum(len(v) for v in bundle["lemmas"].values())
    print(f"{len(bundle['lemmas'])} lemmas, {len(bundle['aliases'])} aliases, {senses} senses -> {target}")


def check(target, query):
    with open(target, encoding="utf-8") as stream:
        bundle = json.load(stream)
    for word in query:
        key = " ".join(word.lower().split())
        key = key if key in bundle["lemmas"] else bundle["aliases"].get(key, key)
        rows = bundle["lemmas"].get(key)
        print(f"== {word} ({key}): {'MISSING' if rows is None else len(rows)}")
        for row in rows or []:
            print(f"   {row[0]} {row[1][:90]} || {(row[2] or '')[:40]}")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--check":
        check(sys.argv[2], sys.argv[3:])
    elif len(sys.argv) == 3:
        convert(sys.argv[1], sys.argv[2])
    else:
        sys.exit(__doc__)
