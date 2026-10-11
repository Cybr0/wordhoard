import SwiftUI

/// The word list. In 1.1 it is only the empty state; search, capture and data arrive in 1.4–1.5.
struct WordListView: View {
    var body: some View {
        NavigationStack {
            List {
                // Rows come from `WordStore` in 1.4/1.5; the `List` is kept so the screen shape is final.
            }
            .overlay {
                ContentUnavailableView(
                    "No words yet",
                    systemImage: "text.book.closed",
                    description: Text("Words you add will appear here.")
                )
            }
            .navigationTitle("Wordhoard")
        }
    }
}

#Preview {
    WordListView()
}
