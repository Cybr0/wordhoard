import Foundation
import Testing
import WordhoardCore

/// `HeadwordMatcher` (plan 2.9, issue #21): the pure check every example passes before it is kept.
@Suite("HeadwordMatcher")
struct HeadwordMatcherTests {
    private func matches(_ headword: String, _ sentence: String) -> Bool {
        HeadwordMatcher.contains(headword: headword, in: sentence)
    }

    @Test("accepts the headword, its inflections and listed irregular forms; rejects synonyms")
    func headwordMatcherAcceptsInflectionsAndRejectsSynonyms() {
        #expect(matches("book", "She booked a table"))
        #expect(matches("book", "The books are on the shelf."))
        #expect(matches("run", "He ran home"), "irregular past")
        #expect(matches("run", "She is running late"))
        #expect(matches("look up", "I looked it up yesterday"), "particle anywhere")
        #expect(matches("give up", "Never give up, they said."))
        #expect(matches("lead", "The pipe was made of led"), "accepted by the table, not judged")
        #expect(matches("bookkeeper", "The bookkeepers were busy"))
        #expect(matches("read", "I have read that book twice."))
        #expect(matches("break the ice", "A joke broke the ice at once."))
        #expect(matches("try", "He tried hard and tries again."), "y → i")
        #expect(matches("make", "She made a cake and is making tea."))
        #expect(matches("child", "The children were loud."), "irregular plural")
        #expect(matches("go", "She went home early."))

        #expect(!matches("book", "She reserved a table"))
        #expect(!matches("look up", "I looked at her"), "every word of the headword must match")
        #expect(!matches("despite", "In spite of the rain, we went."))
        #expect(!matches("set", ""))
        #expect(!matches("", "Anything at all."))
        #expect(!matches("   ", "Anything at all."))
    }

    @Test("matching ignores case, punctuation and Unicode composition")
    func headwordMatcherIgnoresCasePunctuationAndComposition() {
        #expect(matches("Book", "BOOKS, books; \"Booked\"!"))
        #expect(matches("look up", "Look it up!"))
        #expect(matches("café", "We met at the CAFÉ yesterday."))
        #expect(matches("cafe\u{0301}", "The cafés were full"), "decomposed headword, composed sentence")
        #expect(matches("naïve", "Their naïveté showed"), "prefix rule across the accent")
        #expect(matches("don't", "I don’t know."), "curly apostrophe reads as straight")
        #expect(!matches("resume", "Her résumé was short."), "no diacritic folding, as in `Word.normalize`")
    }

    @Test("the lemma tagger finds a form the stem rule and the table do not list")
    func headwordMatcherUsesLemmasForUnlistedForms() {
        #expect(matches("forbid", "Smoking was forbidden here."))
    }
}
