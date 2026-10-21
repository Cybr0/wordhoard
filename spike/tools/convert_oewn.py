#!/usr/bin/env python3
"""Convert an Open English WordNet WN-LMF release into the compact JSON bundle the app reads.

Usage:
    python3 -I spike/tools/convert_oewn.py <english-wordnet-2024.xml.gz> <oewn-2024.json>
    python3 -I spike/tools/convert_oewn.py --check <oewn-2024.json>

The bundle lives at WordhoardCore/Sources/WordhoardCore/Resources/WordNet/oewn-2024.json (read by
WordNetLookup in the product package and copied into the spike's app bundle); this script stays in
spike/tools because it is not needed at build time.

The first form reads the gzipped WN-LMF XML from the GitHub release
(https://github.com/globalwordnet/english-wordnet, tag `2024-edition`, asset
`english-wordnet-2024.xml.gz`, CC BY 4.0) and writes the bundle. The second form
loads a bundle and prints, for every word in `docs/regression-words.md`, whether the
lemma is found and the senses the app would show. If a `function-words.txt` sits next
to the bundle (it does in Resources/WordNet) the check applies the same
stoplist as the app: those words never reach WordNet and go to the model-only path.

Standard library only (system python3 is 3.9). Run with `-I` because the release is
untrusted input; the script never executes anything from it.

What is kept, per lemma (lowercased, multi-word lemmas with single spaces):
  - senses grouped by part of speech, in WordNet sense order, at most TOP per part
    of speech (the app shows every kept sense: up to TOP per part of speech)
  - per sense: synset index and the antonym lemmas (SenseRelation relType="antonym")
Per synset (deduplicated, stored once): the Definition text, the member lemmas when
there is more than one, and up to EXAMPLES_PER_SYNSET of its Example sentences (they
go into the model's writing prompt so a terse gloss is not misread). Everything else in
the release (ILI, pronunciations, subcats, all other relations, synsets no kept sense
points to) is dropped.

Sense rank: the 2024 release carries no <Count> elements on senses (checked with
grep: zero hits), so the order of <Sense> elements inside each <LexicalEntry> is used
as the rank. That order is WordNet's sense order, which is by SemCor tag count where
counts exist and lexicographer order otherwise. When several entries fold into one
lemma key and part of speech, the entry whose written form is exactly the key comes
first ("book" before "Book" = the Koran/Bible senses); entries with the same written
form (OEWN splits heteronyms by pronunciation, e.g. the two noun entries for "lead")
keep file order, and their senses are concatenated.

Part of speech: n -> noun, v -> verb, a -> adjective, s (satellite adjective) ->
adjective, r -> adverb. Other values are dropped.

Bundle shape (no whitespace; array indices are the synset ids):
    {
      "edition": "oewn-2024",
      "synsets": [[gloss] | [gloss, [member lemma, ...]] | [gloss, [members], [example, ...]], ...],
      "lemmas": {"book": {"n": [sense, ...], "v": [...]}, ...}
    }
    sense = synset index | [synset index, [antonym lemma, ...]]
    part of speech keys: n noun, v verb, a adjective, r adverb
    The members list may be empty when a synset has examples but a single member.
Synonyms on a card are the synset members minus the headword; the app does that.
"""

import gzip
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

POS_KEYS = {"n": "n", "v": "v", "a": "a", "s": "a", "r": "r"}
POS_NAMES = {"n": "noun", "v": "verb", "a": "adjective", "r": "adverb"}
# Display order of the parts of speech; learner's dictionaries list nouns before verbs.
POS_ORDER = ["n", "v", "a", "r"]
# Senses kept and shown per part of speech (issue #11, decision 1: missing a real sense
# costs more than showing a spare one). For "book": noun, noun, verb engage, verb reserve.
TOP = 2
# Example sentences kept per synset (the first in the release is the canonical one). Two per
# synset pushed the bundle to 15.1 MB, over the 15 MB target; one keeps it at 14.8 MB.
EXAMPLES_PER_SYNSET = 1
# Stoplist shipped next to the bundle; words on it are always model-only in the app.
FUNCTION_WORDS_FILE = "function-words.txt"

REGRESSION_WORDS = [
    "book", "run", "light", "set", "apple", "however", "despite", "achieve", "look up",
    "give up", "by the book", "break the ice", "ubiquitous", "serendipity", "gaslight",
    "lead", "read", "affect", "bookkeeper", "xylophone", "asdfgh", "Tashkent",
]


def normalise(lemma):
    """Lowercase, underscores to spaces, single spaces, trimmed."""
    return re.sub(r"\s+", " ", lemma.replace("_", " ")).strip().lower()


def open_input(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rb")
    return open(path, "rb")


def parse(input_path):
    """One pass over the release. Returns entries in file order, id -> written form maps
    and the synsets. LexicalEntry elements precede Synset elements in the release, but
    nothing here relies on that: everything is resolved afterwards."""
    entries = []  # (lemma_key, written_form, pos_key, [(synset_id, [antonym sense ids])])
    entry_form_by_id = {}  # LexicalEntry id -> writtenForm (for synset members)
    entry_form_by_sense = {}  # Sense id -> writtenForm (for antonym targets)
    synsets = {}  # synset id -> (gloss, [member entry ids], [example sentences])

    with open_input(input_path) as stream:
        for _event, element in ET.iterparse(stream, events=("end",)):
            tag = element.tag
            if tag == "LexicalEntry":
                lemma = element.find("Lemma")
                if lemma is None:
                    element.clear()
                    continue
                form = lemma.get("writtenForm", "")
                pos = POS_KEYS.get(lemma.get("partOfSpeech", ""))
                entry_form_by_id[element.get("id", "")] = form
                senses = []
                for sense in element.findall("Sense"):
                    entry_form_by_sense[sense.get("id", "")] = form
                    antonyms = [
                        relation.get("target", "")
                        for relation in sense.findall("SenseRelation")
                        if relation.get("relType") == "antonym"
                    ]
                    senses.append((sense.get("synset", ""), antonyms))
                if pos is not None and form and senses:
                    entries.append((normalise(form), form, pos, senses))
                element.clear()
            elif tag == "Synset":
                definition = element.find("Definition")
                gloss = (definition.text or "").strip() if definition is not None else ""
                examples = []
                for example in element.findall("Example"):
                    text = re.sub(r"\s+", " ", example.text or "").strip()
                    if text and text not in examples:
                        examples.append(text)
                    if len(examples) == EXAMPLES_PER_SYNSET:
                        break
                synsets[element.get("id", "")] = (gloss, element.get("members", "").split(), examples)
                element.clear()
            elif tag == "Lexicon":
                element.clear()
    return entries, entry_form_by_id, entry_form_by_sense, synsets


def convert(input_path, output_path):
    entries, entry_form_by_id, entry_form_by_sense, synsets = parse(input_path)

    # Fold entries into (lemma key, pos) groups: exact-case entries first, then file order.
    grouped = {}
    for order, (key, form, pos, senses) in enumerate(entries):
        grouped.setdefault(key, {}).setdefault(pos, []).append((form != key, order, senses))

    # Keep the top TOP senses per part of speech; collect the synsets they point to.
    kept = {}  # key -> pos -> [(synset_id, [antonym forms])]
    seen = set()
    dropped_unknown = 0
    for key, groups in grouped.items():
        kept_groups = {}
        for pos, parts in groups.items():
            rows = []
            for _capitalised, _order, senses in sorted(parts, key=lambda part: part[:2]):
                for synset_id, antonym_ids in senses:
                    if synset_id not in synsets:
                        dropped_unknown += 1
                        continue
                    antonyms = []
                    for antonym_id in antonym_ids:
                        form = entry_form_by_sense.get(antonym_id)
                        if form and form not in antonyms:
                            antonyms.append(form)
                    rows.append((synset_id, antonyms))
            rows = rows[:TOP]
            seen.update(synset_id for synset_id, _antonyms in rows)
            if rows:
                kept_groups[pos] = rows
        if kept_groups:
            kept[key] = kept_groups

    # Dense synset indices, file order of the referenced synsets.
    synset_index = {}
    synset_rows = []
    example_count = 0
    for synset_id in synsets:  # file order
        if synset_id not in seen:
            continue
        gloss, member_ids, examples = synsets[synset_id]
        members = []
        for member_id in member_ids:
            form = entry_form_by_id.get(member_id)
            if form and form not in members:
                members.append(form)
        synset_index[synset_id] = len(synset_rows)
        if examples:
            row = [gloss, members if len(members) > 1 else [], examples]
            example_count += len(examples)
        elif len(members) > 1:
            row = [gloss, members]
        else:
            row = [gloss]
        synset_rows.append(row)

    lemmas = {}
    for key, groups in kept.items():
        lemmas[key] = {
            pos: [
                synset_index[synset_id] if not antonyms else [synset_index[synset_id], antonyms]
                for synset_id, antonyms in rows
            ]
            for pos, rows in groups.items()
        }

    bundle = {"edition": "oewn-2024", "synsets": synset_rows, "lemmas": lemmas}
    with open(output_path, "w", encoding="utf-8") as output:
        json.dump(bundle, output, ensure_ascii=False, separators=(",", ":"))

    size = os.path.getsize(output_path)
    total_senses = sum(len(senses) for _key, _form, _pos, senses in entries)
    kept_senses = sum(len(rows) for groups in lemmas.values() for rows in groups.values())
    print(f"release: {len(entries)} entries, {total_senses} senses, {len(synsets)} synsets")
    print(f"bundle:  {len(lemmas)} lemmas, {kept_senses} senses (top {TOP} per part of speech), "
          f"{len(synset_rows)} synsets, {example_count} examples (up to {EXAMPLES_PER_SYNSET} per synset); "
          f"{dropped_unknown} senses pointed to unknown synsets")
    print(f"wrote {output_path}: {size} bytes ({size / 1_048_576:.1f} MB)")


def sense_parts(sense):
    """A sense is an int or [int, [antonyms]]."""
    if isinstance(sense, list):
        return sense[0], sense[1]
    return sense, []


def synset_parts(row):
    """A synset row is [gloss], [gloss, members] or [gloss, members, examples]."""
    gloss = row[0]
    members = row[1] if len(row) > 1 else []
    examples = row[2] if len(row) > 2 else []
    return gloss, members, examples


TOP_TOTAL = 4  # WordNetLookup.maxSensesTotal


def top_senses(groups, limit=TOP, total=TOP_TOTAL):
    """Same policy as WordNetLookup.swift: up to `limit` senses per part of speech and `total`
    in all — rank 1 of every part of speech (in POS_ORDER) before any rank 2 — shown grouped
    by part of speech in POS_ORDER, each part's senses in WordNet rank order."""
    kept = []
    for rank in range(limit):
        for pos in POS_ORDER:
            if len(kept) >= total:
                break
            senses = groups.get(pos, [])
            if rank < len(senses):
                kept.append((POS_ORDER.index(pos), rank, pos, senses[rank]))
    kept.sort(key=lambda item: (item[0], item[1]))
    return [(pos, sense) for _, _, pos, sense in kept]


def load_function_words(path):
    """One lemma per line, lowercase; blank lines and `#` comments are skipped.
    Same parsing as FunctionWords in WordNetLookup.swift."""
    words = set()
    with open(path, "r", encoding="utf-8") as stream:
        for line in stream:
            text = line.split("#", 1)[0]
            key = normalise(text)
            if key:
                words.add(key)
    return words


def check(bundle_path):
    with open(bundle_path, "r", encoding="utf-8") as stream:
        bundle = json.load(stream)
    synsets = bundle["synsets"]
    lemmas = bundle["lemmas"]
    stoplist_path = os.path.join(os.path.dirname(os.path.abspath(bundle_path)), FUNCTION_WORDS_FILE)
    function_words = load_function_words(stoplist_path) if os.path.exists(stoplist_path) else set()
    if function_words:
        print(f"stoplist: {len(function_words)} function words from {stoplist_path}")
    else:
        print(f"stoplist: no {FUNCTION_WORDS_FILE} next to the bundle, not applied")
    for word in REGRESSION_WORDS:
        key = normalise(word)
        if key in function_words:
            print(f"{word}: function word -> model-only senses call")
            continue
        groups = lemmas.get(key)
        if groups is None:
            print(f"{word}: NOT FOUND -> model-only fallback")
            continue
        total = sum(len(rows) for rows in groups.values())
        by_pos = ", ".join(f"{len(groups[pos])} {POS_NAMES[pos]}" for pos in POS_ORDER if groups.get(pos))
        shown = top_senses(groups)
        print(f"{word}: found, {total} sense{'s' if total != 1 else ''} in bundle ({by_pos}); "
              f"card shows {len(shown)} (up to {TOP} per part of speech, {TOP_TOTAL} in all):")
        for rank, (pos, sense) in enumerate(shown, start=1):
            index, antonyms = sense_parts(sense)
            gloss, members, examples = synset_parts(synsets[index])
            synonyms = [member for member in members if normalise(member) != key]
            line = f"  {rank}. {POS_NAMES[pos]}: {gloss}"
            if synonyms:
                line += f"  [syn: {', '.join(synonyms)}]"
            if antonyms:
                line += f"  [ant: {', '.join(antonyms)}]"
            print(line)
            for example in examples:
                print(f"       e.g. {example}")


def main(argv):
    if len(argv) == 3 and argv[1] == "--check":
        check(argv[2])
        return 0
    if len(argv) == 3:
        convert(argv[1], argv[2])
        return 0
    print(__doc__.strip().split("\n\n")[1])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
