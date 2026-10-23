import Foundation
import Testing
import WordhoardCore

/// Shared fixtures and helpers for the `FoundationModelsCardGenerator` suites.
enum GeneratorFixtures {
    static let reserveGloss = "arrange for and reserve (something for someone else) in advance"
    static let presentPerfect = GrammarCatalog.english.topic(for: "en.present_perfect")!
    static let passiveVoice = GrammarCatalog.english.topic(for: "en.passive_voice")!
    static let twoTopics = [presentPerfect, passiveVoice]
    static let howeverSense = ProposedSense(
        partOfSpeech: .adverb, definition: "in spite of what has just been said", synonyms: ["nevertheless"]
    )
    static let nonsenseSenses = [
        ProposedSense(partOfSpeech: .noun, definition: "a keyboard row typed at random"),
        ProposedSense(partOfSpeech: .verb, definition: "to type without meaning"),
    ]
}

func makeRequest(_ headword: String, topics: [GrammarTopic] = []) -> CardRequest {
    CardRequest(headword: headword, topics: topics)
}

func makeGenerator(
    _ calls: ScriptedModelCalls,
    lookup: WordNetLookup = .shared,
    // Empty by default, so the WordNet and model-only paths stay under test; Wiktionary tests pass one.
    wiktionary: WiktionaryLookup = WiktionaryLookup(entries: [:]),
    maxConcurrentExampleCalls: Int = FoundationModelsCardGenerator.defaultMaxConcurrentExampleCalls,
    // Unlimited by default: the routing and concurrency suites cover every sense of four-sense *book*;
    // the cap itself has its own test.
    maxTopicExampleSenses: Int = .max
) -> FoundationModelsCardGenerator {
    FoundationModelsCardGenerator(
        calls: calls,
        lookup: lookup,
        wiktionary: wiktionary,
        maxConcurrentExampleCalls: maxConcurrentExampleCalls,
        maxTopicExampleSenses: maxTopicExampleSenses
    )
}

func collectExamples(
    _ stream: AsyncThrowingStream<GeneratedTopicExample, any Error>
) async throws -> [GeneratedTopicExample] {
    var examples: [GeneratedTopicExample] = []
    for try await example in stream {
        examples.append(example)
    }
    return examples
}

/// A throwaway `Bundle` whose `WordNet/` directory holds `files`.
func temporaryWordNetBundle(files: [String: String]) throws -> Bundle {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("GeneratorTests-\(UUID().uuidString)", isDirectory: true)
    let wordNet = directory.appendingPathComponent("WordNet", isDirectory: true)
    try FileManager.default.createDirectory(at: wordNet, withIntermediateDirectories: true)
    for (name, contents) in files {
        try contents.write(to: wordNet.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    return try #require(Bundle(url: directory))
}
