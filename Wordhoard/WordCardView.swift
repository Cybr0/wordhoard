import SwiftUI
import WordhoardCore

/// Placeholder card (W1): the headword and an empty state. 1.6 replaces the body and keeps this
/// signature and the two accessibility identifiers.
struct WordCardView: View {
    let word: Word

    var body: some View {
        VStack {
            Text(word.headword)
                .font(.title)
                .accessibilityIdentifier("wordCard.headword")
            ContentUnavailableView("No senses yet", systemImage: "text.book.closed")
                .accessibilityIdentifier("wordCard.emptyState")
        }
        .navigationTitle(word.headword)
    }
}

#Preview {
    NavigationStack {
        WordCardView(word: Word(headword: "book"))
    }
}
