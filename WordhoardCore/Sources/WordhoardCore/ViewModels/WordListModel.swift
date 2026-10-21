import Foundation
import Observation
import os

/// State for the word list screen (B1, C1, C4): the rows to show, the search query, the text in the add
/// field and the last failure the user needs to hear about. The only thing the list view talks to.
///
/// **Isolation: `@MainActor`**, like the `WordStore` it wraps; it republishes `Word` objects, which are not
/// `Sendable`, to SwiftUI views that already run on the main actor.
///
/// The model calls the store and republishes an array. It never holds a `ModelContext` or a
/// `FetchDescriptor`; the view calls `reload()` whenever it (re)appears so edits and deletes made on a
/// card show up after popping it. There is no debounce on `query` and no caching beyond `words`.
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

    private let store: WordStore
    private let logger = Logger(subsystem: "Wordhoard", category: "list")

    public init(store: WordStore) {
        self.store = store
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
    /// - `.created`: the draft and the query are cleared and `words` is re-read, so the new word is first.
    /// - `.existing`: the draft and the query are cleared; the view navigates to the returned word.
    /// - Blank draft: the draft is cleared, nothing is added, `failure` stays as it was; returns `nil`.
    /// - Any other error: logged, `failure = .saving`, the draft is kept for a retry; returns `nil`.
    @discardableResult
    public func addDraft() -> AddResult? {
        do {
            let result = try store.add(draft)
            draft = ""
            query = ""
            if case .created = result {
                reload()
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
}
