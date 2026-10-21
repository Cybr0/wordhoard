import Foundation

/// Deterministic cards for `StubCardGenerator`, keyed by normalized headword. English and Russian
/// text is copied from `requirements.md` Appendix B where it exists; the WordNet glosses are the
/// bundle's. Fixtures are data: qa may add more.
public enum StubFixtures {
    /// The token `generic` carries in place of a headword; the stub replaces it with the request's.
    public static let headwordPlaceholder = "<headword>"

    public static let cards: [String: GeneratedCard] = [
        "book": book,
        "however": however,
        "asdfgh": asdfgh,
        "gaslight": gaslight,
        "despite": despite,
    ]

    /// The default fallback for a headword with no fixture: one WordNet noun sense built around
    /// `headwordPlaceholder`, so "zebra" gets the definition "a zebra".
    public static let generic = GeneratedCard(
        headword: headwordPlaceholder,
        path: .wordnet,
        senses: [
            GeneratedSense(
                partOfSpeech: .noun,
                senseSource: .wordnet,
                gloss: headwordPlaceholder,
                definition: "a \(headwordPlaceholder)",
                translation: nil,
                synonyms: [],
                antonyms: [],
                neutralExample: GeneratedExample(text: "This is a \(headwordPlaceholder).", grammarTopic: nil)
            ),
        ]
    )

    /// Appendix B: a noun and the verb *reserve*, both from WordNet.
    public static let book = GeneratedCard(
        headword: "book",
        path: .wordnet,
        senses: [
            GeneratedSense(
                partOfSpeech: .noun,
                senseSource: .wordnet,
                gloss: "a written work or composition that has been published",
                definition: "a written or printed work consisting of pages bound together",
                translation: "книга",
                synonyms: ["volume", "publication"],
                antonyms: [],
                neutralExample: GeneratedExample(text: "She left her book on the train.", grammarTopic: nil)
            ),
            GeneratedSense(
                partOfSpeech: .verb,
                senseSource: .wordnet,
                gloss: "arrange for and reserve (something for someone else) in advance",
                definition: "to reserve a seat, room, ticket, etc. in advance",
                translation: "бронировать",
                synonyms: ["reserve"],
                antonyms: ["cancel"],
                neutralExample: GeneratedExample(text: "We booked a table for eight o'clock.", grammarTopic: nil)
            ),
        ]
    )

    /// A stoplist word: one model sense, no gloss.
    public static let however = GeneratedCard(
        headword: "however",
        path: .stoplist,
        senses: [
            GeneratedSense(
                partOfSpeech: .adverb,
                senseSource: .model,
                gloss: nil,
                definition: "in spite of what has just been said",
                translation: "тем не менее",
                synonyms: ["nevertheless", "nonetheless"],
                antonyms: [],
                neutralExample: GeneratedExample(
                    text: "The hotel was expensive; however, the service was excellent.",
                    grammarTopic: nil
                )
            ),
        ]
    )

    /// Not found: a success with no senses (A1).
    public static let asdfgh = GeneratedCard(headword: "asdfgh", path: .notFound, senses: [])

    /// The definition call was refused, so the gloss stands in and a note records it (A6).
    public static let gaslight = GeneratedCard(
        headword: "gaslight",
        path: .wordnet,
        senses: [
            GeneratedSense(
                partOfSpeech: .noun,
                senseSource: .wordnet,
                gloss: "light yielded by the combustion of illuminating gas",
                definition: "light yielded by the combustion of illuminating gas",
                translation: "газовый свет",
                synonyms: [],
                antonyms: [],
                neutralExample: GeneratedExample(text: "The street was lit by gaslight.", grammarTopic: nil)
            ),
        ],
        notes: [.definitionRefused(senseIndex: 0)]
    )

    /// A stoplist preposition (ADR 0001: WordNet only has an archaic noun).
    public static let despite = GeneratedCard(
        headword: "despite",
        path: .stoplist,
        senses: [
            GeneratedSense(
                partOfSpeech: .preposition,
                senseSource: .model,
                gloss: nil,
                definition: "in spite of",
                translation: "несмотря на",
                synonyms: ["notwithstanding"],
                antonyms: [],
                neutralExample: GeneratedExample(text: "Despite the rain, we went for a walk.", grammarTopic: nil)
            ),
        ]
    )
}
