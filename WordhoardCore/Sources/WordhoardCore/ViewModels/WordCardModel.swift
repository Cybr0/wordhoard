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
/// The model never holds a SwiftData context; removing a sense or example goes through the store's two
/// hard-delete helpers, and `senses` is re-read from the word after every structural change. A sense or
/// example the model has removed is remembered, and any later call for it is dropped: the view commits
/// a field on focus loss and on disappearing, so a commit can land after "Remove sense" or a
/// swipe-delete, and touching a hard-deleted object's attributes is a SwiftData fatal error.
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
        /// `setImage(data:source:)` could not decode, write or save the picture; nothing changed.
        case savingImage
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

    /// Whether the word is soft-deleted, here or by another card for the same word. Observable through
    /// `word`. While it is `true` every mutation is a no-op except `deleteWord()`, which stays idempotent.
    public var isWordDeleted: Bool {
        word.deletedAt != nil
    }

    /// Internal for the model's extensions (pictures); nothing outside the module sees it.
    let store: WordStore
    /// `nil` in tests and previews that have no picture directory; picture actions then do nothing.
    let imageStore: ImageStore?
    /// The picture queue (4.4): "Generate picture" goes to it; a chosen or removed picture and a deleted
    /// word cancel its job. `nil` means no generation.
    public let imageQueue: ImageGenerationQueue?
    let logger = Logger(subsystem: "Wordhoard", category: "card")

    /// Senses and examples this model hard-deleted, keyed by identity. The objects are retained so a
    /// new object can never reuse a removed one's `ObjectIdentifier`; reading their attributes traps.
    @ObservationIgnored
    private var removed: [ObjectIdentifier: AnyObject] = [:]

    public init(
        word: Word,
        store: WordStore,
        imageStore: ImageStore? = nil,
        imageQueue: ImageGenerationQueue? = nil
    ) {
        self.word = word
        self.store = store
        self.imageStore = imageStore
        self.imageQueue = imageQueue
        senses = word.sortedSenses
    }

    // MARK: - Headword

    /// Renames the word (C4). The text is trimmed as the store trims it.
    ///
    /// - Unchanged after trimming: nothing happens; a previous rejection is cleared; returns `nil`.
    /// - Another active word has the same `Word.normalize` key: returns `.collision`, nothing is
    ///   assigned or saved, so a duplicate key is never even pending.
    /// - Blank: the store rejects the save and has already restored the saved headword; returns `.empty`.
    /// - Otherwise the headword is assigned and saved; returns `nil`. On a deleted word nothing is
    ///   assigned or saved: blank and collision are still reported, anything else returns `nil`.
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
        // A late commit on a deleted word (here or on another card) assigns and saves nothing.
        guard !isWordDeleted else {
            return trimmed.isEmpty ? reject(.empty) : nil
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
        guard isLive(sense), sense.partOfSpeech != partOfSpeech else {
            return
        }
        sense.partOfSpeech = partOfSpeech
        save()
    }

    public func setDefinition(_ text: String, for sense: Sense) {
        guard isLive(sense), sense.definition != text else {
            return
        }
        sense.definition = text
        mark(.definition, on: sense)
        save()
    }

    /// Stores `splitList(text)`.
    public func setSynonyms(_ text: String, for sense: Sense) {
        let synonyms = Self.splitList(text)
        guard isLive(sense), sense.synonyms != synonyms else {
            return
        }
        sense.synonyms = synonyms
        mark(.synonyms, on: sense)
        save()
    }

    /// Stores `splitList(text)`.
    public func setAntonyms(_ text: String, for sense: Sense) {
        let antonyms = Self.splitList(text)
        guard isLive(sense), sense.antonyms != antonyms else {
            return
        }
        sense.antonyms = antonyms
        mark(.antonyms, on: sense)
        save()
    }

    // MARK: - Senses

    /// Appends a hand-entered sense: `.other`, no source, empty fields and no provenance keys, so an
    /// untouched new sense is `.auto` everywhere and the generator may fill it (2.4); each field the user
    /// types into becomes `.user` as it is committed. For a deleted word the sense is created but not
    /// attached or saved.
    @discardableResult
    public func addSense() -> Sense {
        guard !isWordDeleted else {
            return Sense(partOfSpeech: .other, order: 0)
        }
        let sense = Sense(partOfSpeech: .other, order: word.senses.count)
        word.senses.append(sense)
        save()
        reloadSenses()
        return sense
    }

    /// Renumbers the remaining senses `0…n-1` in display order, then hard-deletes `sense` and its
    /// examples through the store, whose save commits both in one transaction: the store never holds a
    /// gap in `order`. A second call for the same sense does nothing.
    public func removeSense(_ sense: Sense) {
        guard isLive(sense) else {
            return
        }
        let remaining = word.sortedSenses.filter { $0.id != sense.id }
        removed[ObjectIdentifier(sense)] = sense
        sense.examples.forEach { removed[ObjectIdentifier($0)] = $0 }
        _ = renumber(remaining)
        do {
            try store.delete(sense)
        } catch {
            logger.error("Could not remove the sense: \(error.localizedDescription, privacy: .public)")
            failure = .saving
            return
        }
        reloadSenses()
    }

    /// Reorders `senses` with the semantics of SwiftUI's `onMove` (`destination` is a position in the
    /// list before the move) and renumbers every sense. Out-of-range offsets are ignored.
    public func moveSenses(fromOffsets source: IndexSet, toOffset destination: Int) {
        // Offsets into a list that still holds a sense another card removed are stale: reload, drop the move.
        guard senses.allSatisfy(isLive) else {
            reloadSenses()
            return
        }
        guard renumber(Self.moved(senses, fromOffsets: source, toOffset: destination)) else {
            return
        }
        save()
        reloadSenses()
    }

    // MARK: - Examples

    /// Appends a hand-entered example: `.user` from the start, no topic, empty text.
    /// Returns the example; for a removed sense the example is created but not attached or saved.
    @discardableResult
    public func addExample(to sense: Sense) -> Example {
        guard isLive(sense) else {
            return Example(text: "", source: .user, grammarTopic: nil, order: 0)
        }
        let example = Example(text: "", source: .user, grammarTopic: nil, order: sense.examples.count)
        sense.examples.append(example)
        save()
        return example
    }

    public func setExampleText(_ text: String, for example: Example) {
        guard isLive(example), example.text != text else {
            return
        }
        example.text = text
        example.source = .user
        save()
    }

    /// Renumbers its sense's remaining examples, then hard-deletes `example` through the store in the
    /// same save, as `removeSense(_:)` does. A second call for the same example does nothing.
    public func removeExample(_ example: Example) {
        guard isLive(example) else {
            return
        }
        let remaining = example.sense?.sortedExamples.filter { $0.id != example.id } ?? []
        removed[ObjectIdentifier(example)] = example
        _ = renumber(remaining)
        do {
            try store.delete(example)
        } catch {
            logger.error("Could not remove the example: \(error.localizedDescription, privacy: .public)")
            failure = .saving
        }
    }

    /// Reorders `sense`'s examples with the semantics of `moveSenses(fromOffsets:toOffset:)`.
    public func moveExamples(in sense: Sense, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard isLive(sense),
              renumber(Self.moved(sense.sortedExamples, fromOffsets: source, toOffset: destination))
        else {
            return
        }
        save()
    }

    // MARK: - Word

    /// Soft-deletes the word (W3) and, after the save, deletes its picture file (the asset row went in
    /// the same save, plan 4.1). Returns `true` when it was saved, so the view may pop; on an error
    /// `failure = .deleting` and the word stays.
    public func deleteWord() -> Bool {
        imageQueue?.cancel(word.id)
        do {
            let fileName = try store.delete(word)
            if let fileName {
                deleteImageFile(fileName)
            }
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

    /// Re-reads `senses` from the word. The model calls it after its own structural changes; the card view
    /// calls it when `AutofillService` has merged a card into this word (plan 2.3), which adds senses
    /// behind the model's back, and when the card appears again, since another card for the same word
    /// may have changed them meanwhile.
    public func reloadSenses() {
        senses = word.sortedSenses
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

// MARK: - Liveness

extension WordCardModel {
    private func isRemoved(_ object: AnyObject) -> Bool {
        removed[ObjectIdentifier(object)] != nil
    }

    /// Whether `sense` is still one of the word's senses. A second card on the same word can hard-delete
    /// it behind this model's back, which `removed` does not see and `isDeleted` does not report; only
    /// the word's live relationship is read, never the sense's own attributes. Nothing on a deleted word
    /// is live, so every sense and example edit is a no-op once the word is deleted.
    private func isLive(_ sense: Sense) -> Bool {
        !isWordDeleted && !isRemoved(sense) && word.senses.contains { $0 === sense }
    }

    /// Whether `example` still belongs to one of the word's senses; see `isLive(_:)` for a sense.
    private func isLive(_ example: Example) -> Bool {
        !isWordDeleted && !isRemoved(example) && word.senses.contains { $0.examples.contains { $0 === example } }
    }
}
