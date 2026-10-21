import SwiftUI
import WordhoardCore

/// The word list (B1) with the add field (C1, C4, C5) as its first row. Talks only to `WordListModel`.
struct WordListView: View {
    @State private var model: WordListModel
    @State private var path: [Word] = []
    @FocusState private var isAddFieldFocused: Bool
    private let store: WordStore
    private let isStorageUnavailable: Bool

    init(store: WordStore, isStorageUnavailable: Bool) {
        _model = State(initialValue: WordListModel(store: store))
        self.store = store
        self.isStorageUnavailable = isStorageUnavailable
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if isStorageUnavailable {
                    storageNotice
                }
                TextField("Add a word", text: $model.draft)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .focused($isAddFieldFocused)
                    .onSubmit(submitDraft)
                    .accessibilityIdentifier("wordList.addField")
                ForEach(model.words) { word in
                    NavigationLink(value: word) {
                        Text(word.headword)
                            .accessibilityIdentifier("wordList.rowHeadword")
                    }
                }
                if model.words.isEmpty {
                    emptyState
                }
            }
            .searchable(text: $model.query)
            .navigationTitle("Wordhoard")
            .navigationDestination(for: Word.self) { word in
                WordCardView(word: word, store: store)
            }
            .alert(failureTitle, isPresented: isFailurePresented) {
                Button("OK", role: .cancel) {}
            }
            .onAppear(perform: model.reload)
            .onChange(of: path) { _, path in
                // Back from a card: re-read, so a delete or rename made there shows at once.
                if path.isEmpty {
                    model.reload()
                }
            }
        }
    }

    private static let storageNoticeBody: LocalizedStringKey =
        "Your words can't be stored on this device right now. Anything you add will be lost when the app closes."

    private var storageNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Storage unavailable")
                .font(.headline)
            Text(Self.storageNoticeBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wordList.storageNotice")
    }

    /// Either the no-words state (nothing stored, nothing searched) or the system no-results state.
    private var emptyState: some View {
        Group {
            if isFiltering {
                ContentUnavailableView.search(text: model.query)
                    .accessibilityIdentifier("wordList.noResults")
            } else {
                ContentUnavailableView(
                    "No words yet",
                    systemImage: "text.book.closed",
                    description: Text("Words you add will appear here.")
                )
                .accessibilityIdentifier("wordList.emptyState")
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// Mirrors `WordStore.search`: a query that normalizes to nothing lists every word, so it is not a search.
    private var isFiltering: Bool {
        !Word.normalize(model.query).isEmpty
    }

    private var failureTitle: Text {
        switch model.failure {
        case .saving:
            Text("Couldn't save the word")
        case .loading:
            Text("Couldn't load your words")
        case nil:
            Text(verbatim: "")
        }
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

    private func submitDraft() {
        switch model.addDraft() {
        case let .existing(word):
            // The push is the duplicate feedback (C4); no toast, no message.
            isAddFieldFocused = false
            path.append(word)
        case .created, nil:
            // Capture is instant (C5): stay on the list and keep the keyboard up for the next word.
            isAddFieldFocused = true
        }
    }
}
