import SwiftUI

/// "+ Add …" for the card's add rows: the symbol is decorative and scales with the text (6.1), so the
/// row reads only its title and grows at every Dynamic Type size.
struct AddRowLabel: View {
    let title: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "plus")
                .accessibilityHidden(true)
            title
        }
    }
}
