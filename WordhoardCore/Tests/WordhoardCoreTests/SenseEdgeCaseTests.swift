import Foundation
import SwiftData
import Testing
import WordhoardCore

@Test("fieldSources keeps unknown keys and they do not affect the known fields")
func fieldSourcesKeepsUnknownKeysWithoutAffectingKnownFields() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let word = Word(headword: "cat")
    context.insert(word)
    word.senses = [Sense(partOfSpeech: .noun, fieldSources: ["pronunciation": .user, "definition": .user])]
    try context.save()

    let sense = try #require(try ModelContext(container).fetch(FetchDescriptor<Sense>()).first)
    #expect(sense.fieldSources == ["pronunciation": .user, "definition": .user])
    #expect(sense.fieldSource(for: .definition) == .user)
    #expect(sense.fieldSource(for: .translation) == .auto)
    #expect(sense.fieldSource(for: .synonyms) == .auto)
    #expect(sense.fieldSource(for: .antonyms) == .auto)
}
