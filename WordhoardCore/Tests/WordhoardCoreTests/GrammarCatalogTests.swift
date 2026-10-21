import Foundation
import Testing
import WordhoardCore

// The literals below are the second copy of `requirements.md` Appendix A; `en.json` is checked against
// them so the file cannot drift from the requirements unnoticed.

private let appendixAGroups: [(name: String, keys: [GrammarTopicID])] = [
    (
        "Tenses",
        [
            "en.present_simple", "en.present_continuous", "en.present_perfect", "en.present_perfect_continuous",
            "en.past_simple", "en.past_continuous", "en.past_perfect", "en.past_perfect_continuous",
            "en.future_simple", "en.future_continuous", "en.future_perfect", "en.going_to",
        ]
    ),
    (
        "Conditionals",
        [
            "en.zero_conditional", "en.first_conditional", "en.second_conditional", "en.third_conditional",
            "en.mixed_conditional",
        ]
    ),
    ("Voice and reporting", ["en.passive_voice", "en.reported_speech"]),
    ("Modals", ["en.modals_ability", "en.modals_obligation", "en.modals_possibility", "en.modals_deduction"]),
    ("Verb patterns", ["en.gerund_vs_infinitive", "en.phrasal_verbs", "en.used_to_would"]),
    (
        "Other",
        [
            "en.comparatives_superlatives", "en.relative_clauses", "en.question_tags", "en.wish_if_only",
            "en.articles", "en.countable_uncountable",
        ]
    ),
]

private let appendixAKeys: [GrammarTopicID] = appendixAGroups.flatMap(\.keys)

private let appendixADefaults: [GrammarTopicID] = [
    "en.present_perfect", "en.past_simple", "en.first_conditional", "en.second_conditional", "en.passive_voice",
]

// MARK: - Bundled catalog

@Test("the English catalog loads from the package bundle")
func englishCatalogLoadsFromTheBundle() {
    let catalog = GrammarCatalog.english
    #expect(catalog.language == "en")
    #expect(catalog.topics.count == 32)
    #expect(catalog.groups.count == 6)
}

@Test("load(language:) returns the same catalog as the english instance")
func loadingEnglishByLanguageCodeMatchesTheSharedInstance() throws {
    let loaded = try GrammarCatalog.load(language: "en")
    #expect(loaded.topics == GrammarCatalog.english.topics)
    #expect(loaded.groups == GrammarCatalog.english.groups)
    #expect(loaded.defaultActiveKeys == GrammarCatalog.english.defaultActiveKeys)
}

@Test("loading a language with no catalog file throws resourceNotFound")
func loadingAMissingLanguageThrows() {
    #expect(throws: GrammarCatalogError.resourceNotFound(language: "xx")) {
        try GrammarCatalog.load(language: "xx")
    }
}

@Test("catalog keys match Appendix A in order")
func catalogKeysMatchAppendixAInOrder() {
    #expect(GrammarCatalog.english.topics.map(\.key) == appendixAKeys)
}

@Test("catalog groups match Appendix A, including in-group order")
func catalogGroupsMatchAppendixA() throws {
    let groups = GrammarCatalog.english.groups
    #expect(groups.map(\.name) == appendixAGroups.map(\.name))
    try #require(groups.count == appendixAGroups.count)
    for (group, expected) in zip(groups, appendixAGroups) {
        #expect(group.topics.map(\.key) == expected.keys, "group \(expected.name)")
    }
}

@Test("every key is unique and namespaced with the language code")
func everyKeyIsUniqueAndNamespaced() {
    let keys = GrammarCatalog.english.topics.map(\.key)
    #expect(Set(keys).count == 32)
    for key in keys {
        #expect(key.hasPrefix("en."), "\(key)")
        #expect(key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, "\(key)")
    }
}

@Test("every topic has a one-line, trimmed name and a one-line description")
func everyTopicHasAOneLineNameAndDescription() {
    for topic in GrammarCatalog.english.topics {
        #expect(!topic.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(topic.key)")
        #expect(!topic.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(topic.key)")
        #expect(topic.name.rangeOfCharacter(from: .newlines) == nil, "\(topic.key)")
        #expect(topic.description.rangeOfCharacter(from: .newlines) == nil, "\(topic.key)")
        #expect(topic.name == topic.name.trimmingCharacters(in: .whitespaces), "\(topic.key)")
        #expect(topic.description == topic.description.trimmingCharacters(in: .whitespaces), "\(topic.key)")
        #expect(!topic.description.hasSuffix("."), "\(topic.key)")
    }
}

@Test("a known key resolves to its topic with the issue's name and description")
func knownKeyResolvesToItsTopic() {
    let catalog = GrammarCatalog.english
    let presentPerfect = catalog.topic(for: "en.present_perfect")
    #expect(presentPerfect?.name == "Present Perfect")
    #expect(
        presentPerfect?.description == "have/has + past participle, for actions with a result or relevance now"
    )
    #expect(presentPerfect?.id == "en.present_perfect")
    #expect(catalog.topic(for: "en.modals_ability")?.name == "Modals of Ability")
    #expect(catalog.topic(for: "en.countable_uncountable")?.name == "Countable and Uncountable Nouns")
}

@Test("the default active set matches Appendix A and every default key is in the catalog")
func defaultActiveSetMatchesAppendixA() {
    let catalog = GrammarCatalog.english
    #expect(catalog.defaultActiveKeys == appendixADefaults)
    for key in catalog.defaultActiveKeys {
        #expect(catalog.topic(for: key) != nil, "\(key)")
    }
}

@Test("an unknown key looks up to nil without crashing")
func unknownKeyLookupReturnsNil() {
    let catalog = GrammarCatalog.english
    for key in ["en.subjunctive", "present_perfect", "de.present_perfect", "", "EN.PRESENT_PERFECT", "en."] {
        #expect(catalog.topic(for: key) == nil, "\(key)")
    }
}

// MARK: - Validation

private func catalogJSON(
    language: String = "xx",
    defaultActive: [String] = ["xx.alpha"],
    groups: [[String: Any]] = [
        [
            "name": "Group",
            "topics": [
                ["key": "xx.alpha", "name": "Alpha", "description": "first"],
                ["key": "xx.beta", "name": "Beta", "description": "second"],
            ],
        ],
    ]
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "language": language,
        "defaultActive": defaultActive,
        "groups": groups,
    ] as [String: Any])
}

private func group(_ name: String = "Group", topics: [[String: String]]) -> [String: Any] {
    ["name": name, "topics": topics]
}

@Test("a well-formed two-topic catalog decodes and lists both topics")
func wellFormedCatalogDecodes() throws {
    let catalog = try GrammarCatalog(decoding: catalogJSON())
    #expect(catalog.language == "xx")
    #expect(catalog.groups.map(\.name) == ["Group"])
    #expect(catalog.topics.map(\.key) == ["xx.alpha", "xx.beta"])
    #expect(catalog.topics.map(\.name) == ["Alpha", "Beta"])
    #expect(catalog.topics.map(\.description) == ["first", "second"])
    #expect(catalog.defaultActiveKeys == ["xx.alpha"])
    #expect(catalog.topic(for: "xx.beta")?.name == "Beta")
    #expect(catalog.topic(for: "xx.gamma") == nil)
}

@Test("topics flatten across groups in file order")
func topicsFlattenAcrossGroupsInFileOrder() throws {
    let data = try catalogJSON(defaultActive: [], groups: [
        group("One", topics: [["key": "xx.a", "name": "A", "description": "a"]]),
        group("Two", topics: [
            ["key": "xx.b", "name": "B", "description": "b"],
            ["key": "xx.c", "name": "C", "description": "c"],
        ]),
    ])
    let catalog = try GrammarCatalog(decoding: data)
    #expect(catalog.groups.map(\.name) == ["One", "Two"])
    #expect(catalog.topics.map(\.key) == ["xx.a", "xx.b", "xx.c"])
    #expect(catalog.defaultActiveKeys.isEmpty)
}

@Test("a catalog with two topics sharing a key fails to load")
func catalogWithDuplicateKeysFailsToLoad() throws {
    let data = try catalogJSON(groups: [
        group(topics: [
            ["key": "xx.alpha", "name": "Alpha", "description": "first"],
            ["key": "xx.alpha", "name": "Alpha again", "description": "second"],
        ]),
    ])
    #expect(throws: GrammarCatalogError.duplicateKey("xx.alpha")) { try GrammarCatalog(decoding: data) }
}

@Test("a duplicate key in a different group is still rejected")
func catalogWithDuplicateKeyAcrossGroupsFailsToLoad() throws {
    let data = try catalogJSON(groups: [
        group("One", topics: [["key": "xx.alpha", "name": "Alpha", "description": "first"]]),
        group("Two", topics: [["key": "xx.alpha", "name": "Alpha", "description": "second"]]),
    ])
    #expect(throws: GrammarCatalogError.duplicateKey("xx.alpha")) { try GrammarCatalog(decoding: data) }
}

@Test("a catalog with a key missing the language prefix fails to load")
func catalogWithUnprefixedKeyFailsToLoad() throws {
    let data = try catalogJSON(
        defaultActive: [],
        groups: [group(topics: [["key": "present_perfect", "name": "Present Perfect", "description": "d"]])]
    )
    #expect(throws: GrammarCatalogError.keyNotNamespaced("present_perfect", language: "xx")) {
        try GrammarCatalog(decoding: data)
    }
}

@Test("a key prefixed with a different language fails to load")
func catalogWithForeignPrefixedKeyFailsToLoad() throws {
    let data = try catalogJSON(
        defaultActive: [],
        groups: [group(topics: [["key": "yy.alpha", "name": "Alpha", "description": "d"]])]
    )
    #expect(throws: GrammarCatalogError.keyNotNamespaced("yy.alpha", language: "xx")) {
        try GrammarCatalog(decoding: data)
    }
}

@Test("a key that is only the language prefix fails to load")
func catalogWithBarePrefixKeyFailsToLoad() throws {
    let data = try catalogJSON(
        defaultActive: [],
        groups: [group(topics: [["key": "xx.", "name": "Alpha", "description": "d"]])]
    )
    #expect(throws: GrammarCatalogError.keyNotNamespaced("xx.", language: "xx")) {
        try GrammarCatalog(decoding: data)
    }
}

@Test("a catalog whose defaultActive names a key not in any group fails to load")
func catalogWithUnknownDefaultKeyFailsToLoad() throws {
    let data = try catalogJSON(defaultActive: ["xx.alpha", "xx.gamma"])
    #expect(throws: GrammarCatalogError.unknownDefaultKey("xx.gamma")) { try GrammarCatalog(decoding: data) }
}

@Test("a catalog whose defaultActive lists the same key twice fails to load")
func catalogWithDuplicateDefaultKeyFailsToLoad() throws {
    let data = try catalogJSON(defaultActive: ["xx.alpha", "xx.beta", "xx.alpha"])
    #expect(throws: GrammarCatalogError.duplicateDefaultKey("xx.alpha")) { try GrammarCatalog(decoding: data) }
}

@Test("a catalog with an empty topic name fails to load")
func catalogWithEmptyNameFailsToLoad() throws {
    let data = try catalogJSON(
        defaultActive: [],
        groups: [group(topics: [["key": "xx.alpha", "name": "", "description": "d"]])]
    )
    #expect(throws: GrammarCatalogError.invalidName(key: "xx.alpha")) { try GrammarCatalog(decoding: data) }
}

@Test("a catalog with a whitespace-only topic name fails to load")
func catalogWithBlankNameFailsToLoad() throws {
    let data = try catalogJSON(
        defaultActive: [],
        groups: [group(topics: [["key": "xx.alpha", "name": "   ", "description": "d"]])]
    )
    #expect(throws: GrammarCatalogError.invalidName(key: "xx.alpha")) { try GrammarCatalog(decoding: data) }
}

@Test("a catalog with a multi-line description fails to load")
func catalogWithMultiLineDescriptionFailsToLoad() throws {
    let data = try catalogJSON(
        defaultActive: [],
        groups: [group(topics: [["key": "xx.alpha", "name": "Alpha", "description": "first\nsecond"]])]
    )
    #expect(throws: GrammarCatalogError.invalidDescription(key: "xx.alpha")) {
        try GrammarCatalog(decoding: data)
    }
}

@Test("a catalog with an empty description fails to load")
func catalogWithEmptyDescriptionFailsToLoad() throws {
    let data = try catalogJSON(
        defaultActive: [],
        groups: [group(topics: [["key": "xx.alpha", "name": "Alpha", "description": ""]])]
    )
    #expect(throws: GrammarCatalogError.invalidDescription(key: "xx.alpha")) {
        try GrammarCatalog(decoding: data)
    }
}

@Test("a catalog with no groups fails to load")
func catalogWithNoGroupsFailsToLoad() throws {
    let data = try catalogJSON(defaultActive: [], groups: [])
    #expect(throws: GrammarCatalogError.noGroups) { try GrammarCatalog(decoding: data) }
}

@Test("a topic missing its description does not decode")
func catalogWithMissingDescriptionFailsToDecode() throws {
    let data = try catalogJSON(
        defaultActive: [],
        groups: [group(topics: [["key": "xx.alpha", "name": "Alpha"]])]
    )
    #expect(throws: DecodingError.self) { try GrammarCatalog(decoding: data) }
}

@Test("data that is not JSON does not decode")
func nonJSONDataFailsToDecode() {
    #expect(throws: DecodingError.self) { try GrammarCatalog(decoding: Data("not json".utf8)) }
}
