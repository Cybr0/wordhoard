#!/usr/bin/env python3
"""Convert an Open English WordNet WN-LMF release into the compact JSON bundle the spike reads.

Usage:
    python3 -I spike/tools/convert_oewn.py <english-wordnet-2024.xml.gz> <oewn-2024.json> [--counts <cntlist.rev>]
    python3 -I spike/tools/convert_oewn.py --check <oewn-2024.json>

The first form reads the gzipped WN-LMF XML from the GitHub release
(https://github.com/globalwordnet/english-wordnet, tag `2024-edition`, asset
`english-wordnet-2024.xml.gz`, CC BY 4.0) and writes the bundle. `--counts` points at the
`cntlist.rev` of the WNDB export in the same release (`english-wordnet-2024.zip`,
`oewn2024/cntlist.rev`): SemCor sense tag counts keyed by sense key (`book%1:10:00:: 1 46`).
The `index.sense` of that export has a tag-count column too, but it is 0 on every line, so
`cntlist.rev` is the only source of counts. Without `--counts` every sense has count 0 and
the WordNet-order fallback below applies to every lemma. The second form
loads a bundle and prints, for every word in `docs/regression-words.md`, whether the
lemma is found and the senses the app would show. If a `function-words.txt` sits next
to the bundle (it does in the app's Resources folder) the check applies the same
stoplist as the app: those words never reach WordNet and go to the model-only path.

Standard library only (system python3 is 3.9). Run with `-I` because the release is
untrusted input; the script never executes anything from it.

What is kept, per lemma (lowercased, multi-word lemmas with single spaces) — issue #14,
decision B, ranking by frequency across parts of speech:
  - every sense gets its SemCor tag count (0 when cntlist.rev has none; the sense key is
    rebuilt from the Sense id: `oewn-book__1.10.00..` -> `book%1:10:00::`, lemma lowercased
    with underscores). About 94 % of cntlist.rev keys join (35 188 of 37 387).
  - senses with a count > 0 are ranked by count (ties: noun, verb, adjective, adverb, then
    WordNet order); a count-0 sense is appended only when it is the sole sense of its part
    of speech; the first TOP_TOTAL of that list are kept, in rank order.
  - a lemma with no counted sense at all falls back to WordNet order: parts of speech in the
    order their entries appear in the release (so a verb-first lemma shows verbs first), the
    first sense of every part of speech before any second one, at most TOP per part of
    speech and TOP_TOTAL in all.
  - per sense: synset index, part of speech, count and the antonym lemmas
    (SenseRelation relType="antonym")
Per synset (deduplicated, stored once): the Definition text, the member lemmas when
there is more than one, and up to EXAMPLES_PER_SYNSET of its Example sentences (they
go into the model's writing prompt so a terse gloss is not misread). Everything else in
the release (ILI, pronunciations, subcats, all other relations, synsets no kept sense
points to) is dropped.

WordNet order: the 2024 LMF release carries no <Count> elements on senses (checked with
grep: zero hits), so the order of <Sense> elements inside each <LexicalEntry> is the
WordNet order used for ties and for the fallback. When several entries fold into one
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
      "lemmas": {"book": [sense, ...], ...}          (rank order; the app shows the list as is)
    }
    sense = [synset index, pos] | [synset index, pos, count] | [synset index, pos, count, [antonym, ...]]
    pos: 0 noun, 1 verb, 2 adjective, 3 adverb; count: SemCor tag count, omitted when 0 and no antonyms
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
# Fallback only (lemmas without any SemCor count): senses kept per part of speech.
TOP = 2
# Senses kept and shown per lemma (WordNetLookup.maxSensesTotal).
TOP_TOTAL = 4
POS_CODES = {"n": 0, "v": 1, "a": 2, "r": 3}
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
                    senses.append((sense.get("synset", ""), antonyms, sense.get("id", "")))
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


def convert(input_path, output_path, counts_path=None):
    entries, entry_form_by_id, entry_form_by_sense, synsets = parse(input_path)
    counts = load_counts(counts_path) if counts_path else {}

    # Fold entries into lemma groups: exact-case entries first, then file order.
    grouped = {}
    for order, (key, form, pos, senses) in enumerate(entries):
        grouped.setdefault(key, []).append((form != key, order, form, pos, senses))

    # Rank every lemma's senses (decision B) and keep the top TOP_TOTAL; collect their synsets.
    kept = {}  # key -> [(pos, count, (synset_id, [antonym forms]))]
    seen = set()
    dropped_unknown = 0
    joined_keys = 0
    lemmas_with_counts = 0
    for key, parts in grouped.items():
        candidates = []
        for entry_order, (_capitalised, _order, form, pos, senses) in enumerate(sorted(parts, key=lambda part: part[:2])):
            for sense_order, (synset_id, antonym_ids, sense_id) in enumerate(senses):
                if synset_id not in synsets:
                    dropped_unknown += 1
                    continue
                antonyms = []
                for antonym_id in antonym_ids:
                    antonym_form = entry_form_by_sense.get(antonym_id)
                    if antonym_form and antonym_form not in antonyms:
                        antonyms.append(antonym_form)
                count = counts.get(sense_key(form, sense_id), 0)
                if count:
                    joined_keys += 1
                candidates.append((pos, entry_order, sense_order, count, (synset_id, antonyms)))
        rows = rank_senses(candidates)
        if rows:
            kept[key] = rows
            if any(count for _pos, count, _payload in rows):
                lemmas_with_counts += 1
            seen.update(synset_id for _pos, _count, (synset_id, _antonyms) in rows)

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
    for key, rows in kept.items():
        encoded = []
        for pos, count, (synset_id, antonyms) in rows:
            row = [synset_index[synset_id], POS_CODES[pos]]
            if count or antonyms:
                row.append(count)
            if antonyms:
                row.append(antonyms)
            encoded.append(row)
        lemmas[key] = encoded

    bundle = {"edition": "oewn-2024", "synsets": synset_rows, "lemmas": lemmas}
    with open(output_path, "w", encoding="utf-8") as output:
        json.dump(bundle, output, ensure_ascii=False, separators=(",", ":"))

    size = os.path.getsize(output_path)
    total_senses = sum(len(senses) for _key, _form, _pos, senses in entries)
    kept_senses = sum(len(rows) for rows in lemmas.values())
    print(f"release: {len(entries)} entries, {total_senses} senses, {len(synsets)} synsets")
    print(f"counts:  {len(counts)} sense keys in cntlist.rev, {joined_keys} joined to a release sense, "
          f"{lemmas_with_counts} of {len(lemmas)} lemmas ranked by count (the rest: WordNet-order fallback)")
    print(f"bundle:  {len(lemmas)} lemmas, {kept_senses} senses (top {TOP_TOTAL} per lemma), "
          f"{len(synset_rows)} synsets, {example_count} examples (up to {EXAMPLES_PER_SYNSET} per synset); "
          f"{dropped_unknown} senses pointed to unknown synsets")
    print(f"wrote {output_path}: {size} bytes ({size / 1_048_576:.1f} MB)")


def sense_parts(sense):
    """A sense row is [synset, pos], [synset, pos, count] or [synset, pos, count, [antonyms]]."""
    pos = POS_ORDER[sense[1]]
    count = sense[2] if len(sense) > 2 else 0
    antonyms = sense[3] if len(sense) > 3 else []
    return sense[0], pos, count, antonyms


def synset_parts(row):
    """A synset row is [gloss], [gloss, members] or [gloss, members, examples]."""
    gloss = row[0]
    members = row[1] if len(row) > 1 else []
    examples = row[2] if len(row) > 2 else []
    return gloss, members, examples


def load_counts(path):
    """cntlist.rev: `sense_key sense_number tag_cnt` per line -> {sense_key: tag_cnt}."""
    counts = {}
    with open(path, "r", encoding="utf-8") as stream:
        for line in stream:
            parts = line.split()
            if len(parts) == 3 and parts[2].isdigit():
                counts[parts[0]] = int(parts[2])
    return counts


def sense_key(form, sense_id):
    """`oewn-book__1.10.00..` + written form -> `book%1:10:00::` (cntlist.rev / index.sense key)."""
    _lemma, _sep, tail = sense_id[len("oewn-"):].partition("__")
    return normalise(form).replace(" ", "_") + "%" + tail.replace(".", ":")


def rank_senses(candidates, limit=TOP, total=TOP_TOTAL):
    """`candidates`: (pos, entry_order, sense_order, count, payload) for one lemma, every part
    of speech. Returns the kept (pos, count, payload) rows in display order — see the module
    docstring (decision B)."""
    counted = [row for row in candidates if row[3] > 0]
    if counted:
        counted.sort(key=lambda row: (-row[3], POS_ORDER.index(row[0]), row[1], row[2]))
        per_pos = {}
        for row in candidates:
            per_pos[row[0]] = per_pos.get(row[0], 0) + 1
        sole_zero = [row for row in candidates if row[3] == 0 and per_pos[row[0]] == 1]
        sole_zero.sort(key=lambda row: (POS_ORDER.index(row[0]), row[1], row[2]))
        ranked = counted + sole_zero
        return [(pos, count, payload) for pos, _entry, _sense, count, payload in ranked[:total]]
    # No frequency information for this lemma: WordNet order, parts of speech as their entries
    # appear in the release, first sense of each part before any second one.
    pos_first = {}
    for pos, entry_order, _sense, _count, _payload in candidates:
        pos_first[pos] = min(pos_first.get(pos, entry_order), entry_order)
    pos_sequence = sorted(pos_first, key=lambda pos: pos_first[pos])
    by_pos = {pos: sorted((row for row in candidates if row[0] == pos), key=lambda row: (row[1], row[2])) for pos in pos_sequence}
    kept = []
    for rank in range(limit):
        for pos in pos_sequence:
            if len(kept) >= total:
                break
            rows = by_pos[pos]
            if rank < len(rows):
                kept.append((pos_sequence.index(pos), rank, rows[rank]))
    kept.sort()
    return [(row[0], row[3], row[4]) for _pos_index, _rank, row in kept]


def top_senses(rows, total=TOP_TOTAL):
    """The bundle already holds the ranked list; the app shows its first `total` rows."""
    return rows[:total]


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
        rows = lemmas.get(key)
        if rows is None:
            print(f"{word}: NOT FOUND -> model-only fallback")
            continue
        shown = top_senses(rows)
        parsed = [sense_parts(sense) for sense in shown]
        by_pos = ", ".join(f"{sum(1 for p in parsed if p[1] == pos)} {POS_NAMES[pos]}" for pos in POS_ORDER if any(p[1] == pos for p in parsed))
        ranking = "by SemCor count" if any(p[2] for p in parsed) else "WordNet order (no counts)"
        print(f"{word}: found, card shows {len(shown)} sense{'s' if len(shown) != 1 else ''} ({by_pos}), {ranking}, up to {TOP_TOTAL}:")
        for rank, (index, pos, count, antonyms) in enumerate(parsed, start=1):
            gloss, members, examples = synset_parts(synsets[index])
            synonyms = [member for member in members if normalise(member) != key]
            line = f"  {rank}. {POS_NAMES[pos]} [{count}]: {gloss}"
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
    if len(argv) == 5 and argv[3] == "--counts":
        convert(argv[1], argv[2], argv[4])
        return 0
    print(__doc__.strip().split("\n\n")[1])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
