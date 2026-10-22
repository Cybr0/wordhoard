import Foundation
import SwiftData

/// Read-only grammar-topic queries for browse (plan 3.4, #61). Both count the same examples: the key
/// matches, any `source`, attached to a sense whose word exists and is not soft-deleted. An orphan
/// (no sense, or a sense without a word) never counts: `sense?.word?.deletedAt == nil` alone is true
/// for one, so the predicate also requires the word.
public extension WordStore {
    /// One counted fetch per key. Every requested key has an entry (`0` when nothing matches, including
    /// a key the catalog does not know); nothing else is returned.
    func exampleCounts(for keys: [GrammarTopicID]) throws -> [GrammarTopicID: Int] {
        var counts: [GrammarTopicID: Int] = [:]
        for key in keys where counts[key] == nil {
            counts[key] = try context.fetchCount(Self.topicExamples(key))
        }
        return counts
    }

    /// The matching examples in no particular order; callers sort them.
    func examples(forTopic key: GrammarTopicID) throws -> [Example] {
        try context.fetch(Self.topicExamples(key))
    }

    private static func topicExamples(_ key: GrammarTopicID) -> FetchDescriptor<Example> {
        FetchDescriptor<Example>(
            predicate: #Predicate { example in
                example.grammarTopic == key
                    && example.sense?.word?.id != nil
                    && example.sense?.word?.deletedAt == nil
            }
        )
    }
}
