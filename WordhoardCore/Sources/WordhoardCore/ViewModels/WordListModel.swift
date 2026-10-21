import Foundation
import Observation
import os

/// State for the word list screen (B1, C1, C4): the rows to show, the search query, the text in the add
/// field and the last failure the user needs to hear about. The only thing the list view talks to.
///
/// **Isolation: `@MainActor`**, like the `WordStore` it wraps; it republishes `Word` objects, which are not
/// `Sendable`, to SwiftUI views that already run on the main actor.
///
/// The model calls the store and republishes an array. It never holds a SwiftData context or a fetch
/// descriptor; the view calls `reload()` whenever it (re)appears so edits and deletes made on a card
/// show up after popping it. There is no debounce on `query` and no caching beyond `words`.
@MainActor
@Observable
public final class WordListModel {
    /// Something the store could not do. `nil` when everything is fine. The view shows an alert and
    /// sets this back to `nil` when the user dismisses it; the model never clears it on its own.
    public enum Failure: Equatable, Sendable {
        /// `reload()` could not read the words; `words` still holds the previous result.
        case loading
        /// `addDraft()` could not save; `draft` still holds the typed text so the user can retry.
        case saving
        /// `importWords(_:)` refused the file (the `ImportError`) or the store could not save it (`nil`).
        /// Nothing was written either way.
        case importing(ImportError?)
    }

    /// What the list shows: active words matching `query`, newest first.
    public private(set) var words: [Word] = []

    /// The search text (B1). Every change re-reads `words` through `WordStore.search(_:)`; an empty or
    /// blank query lists everything.
    public var query = "" {
        didSet {
            if query != oldValue {
                reload()
            }
        }
    }

    /// The text in the add field (C1).
    public var draft = ""

    public var failure: Failure?

    /// What the last `importWords(_:)` did. The view shows it and sets it back to `nil` when the user
    /// dismisses the alert, as for `failure`; a failed import clears it.
    public var importSummary: ImportSummary?

    private let store: WordStore
    private let autofill: AutofillService?
    private let logger = Logger(subsystem: "Wordhoard", category: "list")

    /// `autofill` is queued a word on every `.created` add (C5); `nil` means nothing is filled in.
    public init(store: WordStore, autofill: AutofillService? = nil) {
        self.store = store
        self.autofill = autofill
    }

    /// Re-reads `words` for the current `query`. On a store error `failure` becomes `.loading` and `words`
    /// is left as it was.
    public func reload() {
        do {
            words = try store.search(query)
        } catch {
            logger.error("Could not load words: \(error.localizedDescription, privacy: .public)")
            failure = .loading
        }
    }

    /// Submits `draft` to `WordStore.add(_:)` (C1, C4, C5).
    ///
    /// - `.created`: the draft and the query are cleared, `words` is re-read, so the new word is first, and
    ///   the word is handed to `autofill` (the save is already done; filling in happens afterwards, C5).
    /// - `.existing`: the draft and the query are cleared and `words` is re-read all the same, so the list
    ///   behind the pushed card is current; the view navigates to the returned word.
    /// - Blank draft: the draft is cleared, nothing is added, `failure` stays as it was; returns `nil`.
    /// - Any other error: logged, `failure = .saving`, the draft is kept for a retry; returns `nil`.
    @discardableResult
    public func addDraft() -> AddResult? {
        do {
            let result = try store.add(draft)
            draft = ""
            query = ""
            reload()
            if case let .created(word) = result {
                autofill?.enqueue(word)
            }
            return result
        } catch WordStoreError.emptyHeadword {
            draft = ""
            return nil
        } catch {
            logger.error("Could not save the word: \(error.localizedDescription, privacy: .public)")
            failure = .saving
            return nil
        }
    }

    /// Merges an export file into the store (S3) through `Importer`, then re-reads `words` whatever the
    /// outcome, so a partially matched file and a refused one both leave the list current.
    ///
    /// - Success: `importSummary` is set; `failure` is left as it was.
    /// - `ImportError`: `failure = .importing(error)`, `importSummary = nil`; the store is unchanged.
    /// - Any other error: logged, `failure = .importing(nil)`, `importSummary = nil`; the transaction was
    ///   rolled back.
    public func importWords(_ data: Data) {
        do {
            importSummary = try Importer.import(data, into: store)
        } catch let error as ImportError {
            importSummary = nil
            failure = .importing(error)
        } catch {
            logger.error("Could not import the file: \(error.localizedDescription, privacy: .public)")
            importSummary = nil
            failure = .importing(nil)
        }
        reload()
    }
}
