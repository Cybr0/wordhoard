import OSLog
import SwiftUI
import WordhoardCore

/// The word list (B1) with the add field (C1, C4, C5) as its first row, the Topics button (3.3) and the
/// Settings gear (5.3), which presents Settings as a sheet with its own stack. The one `NavigationStack`
/// of the list lives here; its path is a typed `Route`, so every pushed screen shares it (ADR 0002). Talks
/// only to `WordListModel`.
struct WordListView: View {
    @State private var model: WordListModel
    @State private var path: [Route] = []
    @State private var isSettingsPresented = false
    @FocusState private var isAddFieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    private let store: WordStore
    private let imageStore: ImageStore
    private let imageQueue: ImageGenerationQueue
    private let autofill: AutofillService
    private let translator: any Translator
    private let isStorageUnavailable: Bool
    private let hooks: UITestingHooks
    private let logger = Logger(subsystem: "Wordhoard", category: "list")

    init(
        store: WordStore,
        imageStore: ImageStore,
        imageQueue: ImageGenerationQueue,
        autofill: AutofillService,
        translator: any Translator,
        isStorageUnavailable: Bool,
        hooks: UITestingHooks = .none
    ) {
        _model = State(initialValue: WordListModel(store: store, autofill: autofill, imageQueue: imageQueue))
        self.store = store
        self.imageStore = imageStore
        self.imageQueue = imageQueue
        self.autofill = autofill
        self.translator = translator
        self.isStorageUnavailable = isStorageUnavailable
        self.hooks = hooks
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
                    NavigationLink(value: Route.word(word)) {
                        row(word)
                    }
                }
                if model.words.isEmpty {
                    emptyState
                }
            }
            .searchable(text: $model.query)
            // 6.2 (#32): a drag dismisses the keyboard, so the search field behind it can be reached.
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Wordhoard")
            .navigationDestination(for: Route.self, destination: destination)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Topics", systemImage: "tag") {
                        path.append(.topics)
                    }
                    .accessibilityIdentifier("wordList.topics")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        isSettingsPresented = true
                    }
                    .accessibilityIdentifier("wordList.settings")
                }
            }
            // An import in Settings may have changed the list.
            .sheet(isPresented: $isSettingsPresented, onDismiss: model.reload) {
                SettingsView(store: store, autofill: autofill, imageQueue: imageQueue, hooks: hooks)
            }
            .alert(failureTitle, isPresented: isFailurePresented) {
                Button("OK", role: .cancel) {}
            }
            .onAppear(perform: model.reload)
            .onChange(of: scenePhase) { _, phase in
                // The intent (5.1) can save while the app sits in the background in this process.
                if phase == .active {
                    model.reload()
                }
            }
            .task(runAddWordHook)
            .onChange(of: path) { _, path in
                // Back from a card: re-read, so a delete or rename made there shows at once.
                if path.isEmpty {
                    model.reload()
                }
            }
        }
    }

    /// The headword, with its thumbnail when it has a picture (I6) and a small progress indicator while the
    /// word is waiting for or receiving its card.
    private func row(_ word: Word) -> some View {
        HStack {
            if let fileName = word.image?.fileName {
                RowThumbnail(imageStore: imageStore, fileName: fileName)
            }
            Text(word.headword)
                .accessibilityIdentifier("wordList.rowHeadword")
            if word.autofillState == .pending || word.autofillState == .filling {
                Spacer()
                ProgressView {
                    Text("Filling in…")
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("wordList.rowProgress")
            }
        }
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

    private func submitDraft() {
        switch model.addDraft() {
        case let .existing(word):
            // The push is the duplicate feedback (C4); no toast, no message.
            isAddFieldFocused = false
            path.append(.word(word))
        case .created, nil:
            // Capture is instant (C5): stay on the list and keep the keyboard up for the next word.
            isAddFieldFocused = true
        }
    }
}

// MARK: - Destinations

extension WordListView {
    /// Every screen the stack can push; cards reached from a topic screen are the same card.
    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case let .word(word):
            WordCardView(
                word: word,
                store: store,
                imageStore: imageStore,
                imageQueue: imageQueue,
                autofill: autofill,
                translator: translator
            )
        case .topicSettings:
            GrammarTopicsView(store: store)
        case .topics:
            TopicsView(store: store)
        case let .topic(key):
            TopicExamplesView(key: key, store: store)
        }
    }
}

// MARK: - Storage notice

extension WordListView {
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
}

// MARK: - UI-test hooks

extension WordListView {
    /// `--ui-testing-add-word`: the real intent, then a reload, as when Siri saves while the app is open.
    private func runAddWordHook() async {
        guard !hooks.addWords.isEmpty else {
            return
        }
        for word in hooks.addWords {
            do {
                _ = try await AddWordIntent(word: word).perform()
            } catch {
                logger.notice("The add-word hook's intent threw: \(error.localizedDescription, privacy: .public)")
            }
        }
        model.reload()
    }
}

// MARK: - Failures

extension WordListView {
    private var failureTitle: Text {
        switch model.failure {
        case .saving:
            Text("Couldn't save the word")
        case .loading:
            Text("Couldn't load your words")
        case .importing:
            Text("Couldn't import")
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
}
