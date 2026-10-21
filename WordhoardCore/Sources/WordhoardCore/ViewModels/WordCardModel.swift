import Foundation
import Observation
import os

/// State and the **only** mutation path for the word card (W1, W2, W3, A4, C4). The card view keeps
/// in-progress text in its own local state and calls one setter here when an edit ends; nothing else
/// writes to a `Word`, `Sense` or `Example`.
///
/// **Isolation: `@MainActor`**, like the `WordStore` it wraps and the `WordListModel` beside it; it
/// republishes `@Model` objects, which are not `Sendable`, to views that already run on the main actor.
///
/// Every setter follows one rule: an unchanged value is a no-op (no mark, no save, no `updatedAt`
/// bump, so tabbing through a generated card leaves it `.auto`); otherwise the change is applied, the
/// provenance mark is set where §5 has one, and `WordStore.save(_:)` is called once. Provenance (A4):
/// the four `SenseField` keys become `.user` on edit, including when the field is cleared, and an
/// example's `source` becomes `.user` on edit. Part of speech, headword, adding, removing and moving
/// carry no mark: the generator never writes the headword, and part of speech is part of a sense's
/// identity, not a regenerable field.
///
/// The model never holds a `ModelContext`; removing a sense or example goes through the store's two
/// hard-delete helpers, and `senses` is re-read from the word after every structural change.
@MainActor
@Observable
public final class WordCardModel {
    /// Something the store could not do. `nil` when everything is fine. The view shows an alert and
    /// sets this back to `nil` when the user dismisses it; the model never clears it on its own.
    public enum Failure: Equatable, Sendable {
        /// A setter, add, remove or move could not save; the change may still be pending in memory.
        case saving
        /// `deleteWord()` could not save; the word is still active.
        case deleting
    }

    /// Why the last headword commit was not applied. Not a `Failure`: the word is intact.
    public enum HeadwordRejection: Equatable, Sendable {
        /// The text was blank; the store kept the previous headword.
        case empty
        /// Another active word already has this key (C4); nothing was assigned.
        case collision(existingHeadword: String)
    }

    public let word: Word

    /// `word.sortedSenses`, re-read after every add, remove and move.
    public private(set) var senses: [Sense]

    public var failure: Failure?

    /// `nil` after an accepted or unchanged headword commit.
    public private(set) var headwordRejection: HeadwordRejection?

    private let store: WordStore
    private let logger = Logger(subsystem: "Wordhoard", category: "card")

    public init(word: Word, store: WordStore) {
        self.word = word
        self.store = store
        senses = word.sortedSenses
    }

    // MARK: - Headword

    /// Renames the word (C4). The text is trimmed as the store trims it.
    ///
    /// - Unchanged after trimming: nothing happens; a previous rejection is cleared; returns `nil`.
    /// - Another active word has the same `Word.normalize` key: returns `.collision`, nothing is
    ///   assigned or saved, so a duplicate key is never even pending.
    /// - Blank: the store rejects the save and has already restored the saved headword; returns `.empty`.
    /// - Otherwise the headword is assigned and saved; returns `nil`.
    ///
    /// The result is also published as `headwordRejection`. A save or lookup error becomes
    /// `failure = .saving` and returns `nil`.
    @discardableResult
    public func setHeadword(_ text: String) -> HeadwordRejection? {
        let trimmed = Self.trimmed(text)
        guard trimmed != word.headword else {
            headwordRejection = nil
            return nil
        }
        let key = Word.normalize(trimmed)
        if !key.isEmpty {
            do {
                if let existing = try store.activeWord(normalized: key), existing.id != word.id {
                    return reject(.collision(existingHeadword: existing.headword))
                }
            } catch {
                logger
                    .error(
                        "Could not check the headword for duplicates: \(error.localizedDescription, privacy: .public)"
                    )
                failure = .saving
                return nil
            }
        }
        word.headword = trimmed
        do {
            try store.save(word)
            headwordRejection = nil
            return nil
        } catch WordStoreError.emptyHeadword {
            return reject(.empty)
        } catch {
            logger.error("Could not save the headword: \(error.localizedDescription, privacy: .public)")
            failure = .saving
            return nil
        }
    }

    // MARK: - Sense fields

    /// No provenance mark: part of speech is part of the sense's identity, not a regenerable field.
    public func setPartOfSpeech(_ partOfSpeech: PartOfSpeech, for sense: Sense) {
        guard sense.partOfSpeech != partOfSpeech else {
            return
        }
        sense.partOfSpeech = partOfSpeech
        save()
    }

    public func setDefinition(_ text: String, for sense: Sense) {
        guard sense.definition != text else {
            return
        }
        sense.definition = text
        mark(.definition, on: sense)
        save()
    }

    /// Blank text stores `nil`; clearing is an edit and marks the field `.user` like any other.
    public func setTranslation(_ text: String, for sense: Sense) {
        let translation = Self.trimmed(text).isEmpty ? nil : text
        guard sense.translation != translation else {
            return
        }
        sense.translation = translation
        mark(.translation, on: sense)
        save()
    }

    /// Stores `splitList(text)`.
    public func setSynonyms(_ text: String, for sense: Sense) {
        let synonyms = Self.splitList(text)
        guard sense.synonyms != synonyms else {
            return
        }
        sense.synonyms = synonyms
        mark(.synonyms, on: sense)
        save()
    }

    /// Stores `splitList(text)`.
    public func setAntonyms(_ text: String, for sense: Sense) {
        let antonyms = Self.splitList(text)
        guard sense.antonyms != antonyms else {
            return
        }
        sense.antonyms = antonyms
        mark(.antonyms, on: sense)
        save()
    }

    // MARK: - Senses

    /// Appends a hand-entered sense: `.other`, no source, empty fields and no provenance keys, so an
    /// untouched new sense is `.auto` everywhere and the generator may fill it (2.4); each field the user
    /// types into becomes `.user` as it is committed.
    @discardableResult
    public func addSense() -> Sense {
        let sense = Sense(partOfSpeech: .other, order: senses.count)
        word.senses.append(sense)
        save()
        reloadSenses()
        return sense
    }

    /// Hard-deletes `sense` and its examples through the store, then renumbers the remaining senses
    /// `0…n-1` in display order.
    public func removeSense(_ sense: Sense) {
        let remaining = senses.filter { $0.id != sense.id }
        do {
            try store.delete(sense)
        } catch {
            logger.error("Could not remove the sense: \(error.localizedDescription, privacy: .public)")
            failure = .saving
            return
        }
        if renumber(remaining) {
            save()
        }
        reloadSenses()
    }

    /// Reorders `senses` with the semantics of SwiftUI's `onMove` (`destination` is a position in the
    /// list before the move) and renumbers every sense. Out-of-range offsets are ignored.
    public func moveSenses(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard renumber(Self.moved(senses, fromOffsets: source, toOffset: destination)) else {
            return
        }
        save()
        reloadSenses()
    }

    // MARK: - Examples

    /// Appends a hand-entered example: `.user` from the start, no topic, empty text.
    @discardableResult
    public func addExample(to sense: Sense) -> Example {
        let example = Example(text: "", source: .user, grammarTopic: nil, order: sense.examples.count)
        sense.examples.append(example)
        save()
        return example
    }

    public func setExampleText(_ text: String, for example: Example) {
        guard example.text != text else {
            return
        }
        example.text = text
        example.source = .user
        save()
    }

    /// Hard-deletes `example` through the store, then renumbers its sense's remaining examples.
    public func removeExample(_ example: Example) {
        let remaining = example.sense?.sortedExamples.filter { $0.id != example.id } ?? []
        do {
            try store.delete(example)
        } catch {
            logger.error("Could not remove the example: \(error.localizedDescription, privacy: .public)")
            failure = .saving
            return
        }
        if renumber(remaining) {
            save()
        }
    }

    /// Reorders `sense`'s examples with the semantics of `moveSenses(fromOffsets:toOffset:)`.
    public func moveExamples(in sense: Sense, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard renumber(Self.moved(sense.sortedExamples, fromOffsets: source, toOffset: destination)) else {
            return
        }
        save()
    }

    // MARK: - Word

    /// Soft-deletes the word (W3). Returns `true` when it was saved, so the view may pop; on an error
    /// `failure = .deleting` and the word stays.
    public func deleteWord() -> Bool {
        do {
            try store.delete(word)
            return true
        } catch {
            logger.error("Could not delete the word: \(error.localizedDescription, privacy: .public)")
            failure = .deleting
            return false
        }
    }

    // MARK: - List fields

    /// The comma rule for synonyms and antonyms: split on `,`, trim each part of whitespace, drop empty
    /// parts, drop exact duplicates keeping the first. `"big,  large,,big "` → `["big", "large"]`.
    public static func splitList(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { trimmed(String($0)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - Helpers

    private func reject(_ rejection: HeadwordRejection) -> HeadwordRejection {
        headwordRejection = rejection
        return rejection
    }

    private func mark(_ field: SenseField, on sense: Sense) {
        sense.fieldSources[field.rawValue] = .user
    }

    private func reloadSenses() {
        senses = word.sortedSenses
    }

    /// Sets `order` to the position in `items` where it differs. Returns whether anything changed.
    private func renumber(_ items: [Sense]) -> Bool {
        var changed = false
        for (position, sense) in items.enumerated() where sense.order != position {
            sense.order = position
            changed = true
        }
        return changed
    }

    private func renumber(_ items: [Example]) -> Bool {
        var changed = false
        for (position, example) in items.enumerated() where example.order != position {
            example.order = position
            changed = true
        }
        return changed
    }

    /// `items` with the elements at `source` moved so the first of them lands where `destination`
    /// pointed before the move: SwiftUI's `onMove` contract. Offsets outside `items` are dropped and
    /// `destination` is clamped, so a stale index from the view can never trap.
    private static func moved<Element>(
        _ items: [Element],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [Element] {
        let offsets = source.filter(items.indices.contains)
        let target = min(max(destination, 0), items.count)
        let moving = offsets.map { items[$0] }
        var remaining = items
        for offset in offsets.reversed() {
            remaining.remove(at: offset)
        }
        let insertAt = target - offsets.filter { $0 < target }.count
        remaining.insert(contentsOf: moving, at: insertAt)
        return remaining
    }

    private func save() {
        do {
            try store.save(word)
        } catch {
            logger.error("Could not save the card: \(error.localizedDescription, privacy: .public)")
            failure = .saving
        }
    }

    /// Leading and trailing whitespace and newlines dropped, with the same `Character.isWhitespace` test
    /// the store and `Word.normalize(_:)` use, so the model and the store agree on what is blank.
    private static func trimmed(_ text: String) -> String {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace })
        else {
            return ""
        }
        return String(text[first ... last])
    }
}
