import SwiftUI
import WordhoardCore

extension PartOfSpeech {
    /// The picker's display name. Lives in the app target so the enum stays raw-valued for export (1.7).
    var displayName: LocalizedStringKey {
        switch self {
        case .noun:
            "Noun"
        case .verb:
            "Verb"
        case .adjective:
            "Adjective"
        case .adverb:
            "Adverb"
        case .preposition:
            "Preposition"
        case .conjunction:
            "Conjunction"
        case .phrase:
            "Phrase"
        case .other:
            "Other"
        }
    }
}
