import SwiftUI
import WordhoardCore

/// One grammar topic's examples (G3; plan 3.3): a section per word, newest first, headed by the
/// headword; every example opens its card on the same stack, so Back returns here. Reloads on every
/// appear, so an example edited or deleted on the card is reflected. A key the catalog does not know
/// (only a stale route) shows the key as the title and an empty list.
struct TopicExamplesView: View {
    @State private var model: TopicBrowseModel
    private let key: GrammarTopicID

    init(key: GrammarTopicID, store: WordStore) {
        _model = State(initialValue: TopicBrowseModel(store: store))
        self.key = key
    }

    private var name: String {
        model.catalog.topic(for: key)?.name ?? key
    }

    var body: some View {
        let groups = model.groups(for: key)
        List {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                Section {
                    ForEach(Array(group.examples.enumerated()), id: \.element.id) { position, example in
                        NavigationLink(value: Route.word(group.word)) {
                            Text(verbatim: example.text)
                        }
                        .accessibilityIdentifier("topic.example.\(index).\(position)")
                    }
                } header: {
                    Text(verbatim: group.word.headword)
                        .textCase(nil)
                        .accessibilityIdentifier("topic.word.\(index)")
                }
            }
            if groups.isEmpty {
                emptyState
            }
        }
        .navigationTitle(Text(verbatim: name))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't load your words", isPresented: isFailurePresented) {
            Button("OK", role: .cancel) {}
        }
        .onAppear(perform: model.load)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No examples for \(name) yet",
            systemImage: "tag",
            description: Text("Examples tagged with this topic will appear here.")
        )
        .accessibilityIdentifier("topic.emptyState")
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var isFailurePresented: Binding<Bool> {
        Binding(
            get: { model.failure != nil },
            set: { isPresented in
                if !isPresented {
                    model.failure = nil
                }
            }
        )
    }
}
