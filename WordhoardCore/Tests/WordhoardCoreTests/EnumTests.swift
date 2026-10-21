import Foundation
import Testing
import WordhoardCore

@Test("part of speech has the eight schema cases")
func partOfSpeechHasTheEightSchemaCases() {
    #expect(PartOfSpeech.allCases.count == 8)
    #expect(PartOfSpeech.allCases == [
        .noun, .verb, .adjective, .adverb, .preposition, .conjunction, .phrase, .other,
    ])
    #expect(PartOfSpeech(rawValue: "preposition") != nil)
    #expect(PartOfSpeech(rawValue: "conjunction") != nil)
    #expect(PartOfSpeech(rawValue: "determiner") == nil)
    #expect(PartOfSpeech(rawValue: "pronoun") == nil)
}

@Test("the other enums have exactly the cases the requirements list")
func otherEnumsHaveTheRequiredCases() {
    #expect(SenseSource.allCases == [.wordnet, .model])
    #expect(FieldSource.allCases == [.auto, .user])
    #expect(ImageSource.allCases == [.generated, .library, .camera])
    #expect(ReviewDirection.allCases == [.wordToMeaning, .meaningToWord])
    #expect(SenseField.allCases == [.definition, .translation, .synonyms, .antonyms])
}

@Test("enums encode as their case names")
func enumsEncodeAsTheirCaseNames() throws {
    func json(_ value: some Encodable) throws -> String? {
        try String(data: JSONEncoder().encode(value), encoding: .utf8)
    }
    for pos in PartOfSpeech.allCases {
        #expect(try json(pos) == "\"\(pos)\"")
    }
    for source in SenseSource.allCases {
        #expect(try json(source) == "\"\(source)\"")
    }
    for source in FieldSource.allCases {
        #expect(try json(source) == "\"\(source)\"")
    }
    for source in ImageSource.allCases {
        #expect(try json(source) == "\"\(source)\"")
    }
    for direction in ReviewDirection.allCases {
        #expect(try json(direction) == "\"\(direction)\"")
    }
    #expect(try json(ReviewDirection.wordToMeaning) == "\"wordToMeaning\"")
}

@Test("decoding an unknown enum raw value throws instead of falling back to a case")
func decodingAnUnknownEnumRawValueThrows() {
    let decoder = JSONDecoder()
    #expect(throws: DecodingError.self) {
        try decoder.decode(PartOfSpeech.self, from: Data("\"determiner\"".utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(FieldSource.self, from: Data("\"generated\"".utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(SenseSource.self, from: Data("\"manual\"".utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(ImageSource.self, from: Data("\"url\"".utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(ReviewDirection.self, from: Data("\"both\"".utf8))
    }
}
