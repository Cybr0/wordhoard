import SwiftUI
import WordhoardCore

/// Topics (G3, B2; plan 3.3): the topics the user is learning with how many examples each has, then any
/// inactive topic that still has examples. A row opens that topic's examples; "Choose topics" opens the
/// 3.1 settings screen. Both are pushed onto the list's stack. Reloads on every appear, so returning
/// from a card, the picker or an import shows current counts.
struct TopicsView: View {
    @State private var model: TopicBrowseModel

    init(store: WordStore) {
        _model = State(initialValue: TopicBrowseModel(store: store))
    }

    var body: some View {
        List {
            if !model.active.isEmpty {
                Section("Topics I'm learning") {
                    ForEach(model.active, content: row)
                }
            }
            if !model.other.isEmpty {
                Section("Other topics") {
                    ForEach(model.other, content: row)
                }
            }
            if model.active.isEmpty, model.other.isEmpty {
                emptyState
            }
        }
        .navigationTitle("Topics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.topicSettings) {
                    Label("Choose topics", systemImage: "checklist")
                }
                .accessibilityIdentifier("topics.choose")
            }
        }
        .alert("Couldn't load your words", isPresented: isFailurePresented) {
            Button("OK", role: .cancel) {}
        }
        .onAppear(perform: model.load)
    }

    /// Name and count side by side; at accessibility sizes, where that no longer fits, stacked.
    private func row(_ row: TopicRow) -> some View {
        NavigationLink(value: Route.topic(row.id)) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(verbatim: row.topic.name)
                    Spacer()
                    count(row)
                }
                VStack(alignment: .leading) {
                    Text(verbatim: row.topic.name)
                    count(row)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("topics.row.\(row.id)")
    }

    private func count(_ row: TopicRow) -> some View {
        Text("\(row.exampleCount) examples")
            .foregroundStyle(.secondary)
    }

    private static let emptyDescription: LocalizedStringKey =
        "Choose the grammar topics you're learning. Autofill writes one example per topic for every new word."

    private var emptyState: some View {
        ContentUnavailableView("No topics yet", systemImage: "tag", description: Text(Self.emptyDescription))
            .accessibilityIdentifier("topics.emptyState")
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
