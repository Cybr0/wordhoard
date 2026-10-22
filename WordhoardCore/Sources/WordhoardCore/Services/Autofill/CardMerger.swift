import Foundation

/// Applies a `GeneratedCard` to a stored `Word` with field provenance (requirements A4, A7, W2; issue #40).
///
/// **Isolation: `@MainActor`**, like the `WordStore` whose objects it mutates. Pure in-memory mutation
/// of model objects: no store access and no save. The caller (`AutofillService`, plan 2.3) wraps a call
/// in `WordStore.transaction` so the merged card and the `ready` state land in one commit.
///
/// Rules, in one place:
/// - **Sense matching.** A `wordnet` sense matches an existing `.wordnet` sense with the same part of
///   speech and gloss; a `model` sense matches the first not-yet-matched existing `.model` sense with the
///   same part of speech, in `order`. Hand-entered senses (`senseSource == nil`) are never matched or
///   modified. Unmatched generated senses are appended after the last existing one; unmatched existing
///   senses are kept (regeneration never deletes). A matched sense's part of speech is never changed.
/// - **Fields.** A `.user` field is untouched. An `.auto` field is overwritten only by a non-empty
///   generated value: regeneration fills, it never empties. `translationIsFallback` travels with
///   `translation` under the same guard (plan 2.10). No provenance mark is ever written here
///   (absence means `.auto`).
/// - **Examples.** An `.auto` example in the same topic slot (`grammarTopic`; `nil` is neutral) has its
///   text replaced in place, so applying twice never doubles the examples. Otherwise the generated
///   example is appended as `.auto`, unless its normalised text duplicates an example the sense already
///   has. A `.user` example is never modified or removed.
/// - **Word level.** Nothing on the `Word` itself is touched; the spelling the card carries is ignored
///   (the stored word is the truth; the generator never writes it).
@MainActor
public enum CardMerger {
    /// Merges the first card into `word`. Returns the ids of the senses that now hold `card.senses[i]`,
    /// index-aligned with the card, so topic examples can be routed to them later. A card with no
    /// senses (`notFound`) changes nothing and returns `[]`.
    @discardableResult
    public static func apply(_ card: GeneratedCard, to word: Word) -> [UUID] {
        guard !card.senses.isEmpty else {
            return []
        }
        let existing = word.sortedSenses
        var matched = Set<UUID>()
        var nextOrder = (existing.map(\.order).max() ?? -1) + 1
        var ids: [UUID] = []

        for generated in card.senses {
            if let sense = match(generated, in: existing, excluding: matched) {
                matched.insert(sense.id)
                update(sense, from: generated)
                ids.append(sense.id)
            } else {
                let sense = insert(generated, into: word, order: nextOrder)
                nextOrder += 1
                matched.insert(sense.id)
                ids.append(sense.id)
            }
        }
        return ids
    }

    /// Merges one example into `sense`: the slot rule for a single example, used for the neutral
    /// example of a first card and for every topic example that arrives afterwards.
    public static func apply(_ example: GeneratedExample, to sense: Sense) {
        let key = normalize(example.text)
        guard !key.isEmpty else {
            return
        }
        let examples = sense.sortedExamples
        let slot = examples.first { $0.source == .auto && $0.grammarTopic == example.grammarTopic }
        let duplicate = examples.first { $0.id != slot?.id && normalize($0.text) == key }
        if duplicate != nil {
            return
        }
        if let slot {
            if slot.text != example.text {
                slot.text = example.text
            }
            return
        }
        let order = (examples.map(\.order).max() ?? -1) + 1
        sense.examples.append(
            Example(text: example.text, source: .auto, grammarTopic: example.grammarTopic, order: order)
        )
    }

    // MARK: - Senses

    private static func match(_ generated: GeneratedSense, in senses: [Sense], excluding matched: Set<UUID>) -> Sense? {
        senses.first { sense in
            guard !matched.contains(sense.id),
                  sense.senseSource == generated.senseSource,
                  sense.partOfSpeech == generated.partOfSpeech
            else {
                return false
            }
            switch generated.senseSource {
            case .wordnet:
                return sense.gloss == generated.gloss
            case .model:
                return true
            }
        }
    }

    private static func insert(_ generated: GeneratedSense, into word: Word, order: Int) -> Sense {
        let sense = Sense(
            partOfSpeech: generated.partOfSpeech,
            definition: generated.definition,
            order: order,
            senseSource: generated.senseSource,
            gloss: generated.gloss,
            translation: generated.translation,
            translationIsFallback: generated.translation != nil && generated.translationIsFallback,
            synonyms: generated.synonyms,
            antonyms: generated.antonyms
        )
        word.senses.append(sense)
        if let neutral = generated.neutralExample {
            apply(neutral, to: sense)
        }
        return sense
    }

    private static func update(_ sense: Sense, from generated: GeneratedSense) {
        if isFillable(sense, .definition), !isBlank(generated.definition) {
            assign(sense, \.definition, generated.definition)
        }
        if isFillable(sense, .translation), let translation = generated.translation, !isBlank(translation) {
            assign(sense, \.translation, translation)
            assign(sense, \.translationIsFallback, generated.translationIsFallback)
        }
        if isFillable(sense, .synonyms), !generated.synonyms.isEmpty {
            assign(sense, \.synonyms, generated.synonyms)
        }
        if isFillable(sense, .antonyms), !generated.antonyms.isEmpty {
            assign(sense, \.antonyms, generated.antonyms)
        }
        if let gloss = generated.gloss {
            assign(sense, \.gloss, gloss)
        }
        if let neutral = generated.neutralExample {
            apply(neutral, to: sense)
        }
    }

    /// `.user` fields are the user's (A4); everything else may be refreshed.
    private static func isFillable(_ sense: Sense, _ field: SenseField) -> Bool {
        sense.fieldSource(for: field) == .auto
    }

    /// Compares before assigning, so an unchanged value does not dirty the object.
    private static func assign<Value: Equatable>(
        _ sense: Sense,
        _ keyPath: ReferenceWritableKeyPath<Sense, Value>,
        _ value: Value
    ) {
        if sense[keyPath: keyPath] != value {
            sense[keyPath: keyPath] = value
        }
    }

    // MARK: - Text

    private static func isBlank(_ text: String) -> Bool {
        !text.contains { !$0.isWhitespace }
    }

    /// Trimmed, whitespace-collapsed, case-folded: the duplicate key for example text.
    private static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
