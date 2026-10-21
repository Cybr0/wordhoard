import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WordhoardCore

/// The word list (B1) with the add field (C1, C4, C5) as its first row and, until 5.3 adds Settings, the
/// "More" menu with Export… and Import… (S3). Talks only to `WordListModel`; the export runs `Exporter`
/// over the store on demand and the import hands the picked file's bytes to the model, so Core never
/// sees a URL.
struct WordListView: View {
    @State private var model: WordListModel
    @State private var path: [Word] = []
    @State private var isImporterPresented = false
    @State private var isReadFailurePresented = false
    @FocusState private var isAddFieldFocused: Bool
    private let store: WordStore
    private let autofill: AutofillService
    private let isStorageUnavailable: Bool
    private let hooks: UITestingHooks
    private let logger = Logger(subsystem: "Wordhoard", category: "transfer")

    init(store: WordStore, autofill: AutofillService, isStorageUnavailable: Bool, hooks: UITestingHooks = .none) {
        _model = State(initialValue: WordListModel(store: store, autofill: autofill))
        self.store = store
        self.autofill = autofill
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
                    NavigationLink(value: word) {
                        row(word)
                    }
                }
                if model.words.isEmpty {
                    emptyState
                }
            }
            .searchable(text: $model.query)
            .navigationTitle("Wordhoard")
            .navigationDestination(for: Word.self) { word in
                WordCardView(word: word, store: store, autofill: autofill)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    moreMenu
                }
            }
            .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.json], onCompletion: importPicked)
            .alert(failureTitle, isPresented: isFailurePresented) {
                Button("OK", role: .cancel) {}
            } message: {
                if case let .importing(error?) = model.failure, let description = error.errorDescription {
                    Text(verbatim: description)
                }
            }
            .alert("Import finished", isPresented: isImportSummaryPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                if let summary = model.importSummary {
                    importMessage(summary)
                }
            }
            .alert("Couldn't import", isPresented: $isReadFailurePresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The file couldn't be read.")
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

    /// The headword, with a small progress indicator while the word is waiting for or receiving its card.
    private func row(_ word: Word) -> some View {
        HStack {
            Text(word.headword)
                .accessibilityIdentifier("wordList.rowHeadword")
            if word.autofillState == .pending || word.autofillState == .filling {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("wordList.rowProgress")
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

    // MARK: - More menu (export and import)

    private var moreMenu: some View {
        Menu("More", systemImage: "ellipsis.circle") {
            exportRow
            Button("Import…", systemImage: "square.and.arrow.down", action: startImport)
                .accessibilityIdentifier("wordList.import")
        }
        .accessibilityIdentifier("wordList.moreMenu")
    }

    /// The share sheet in production; under the UI-test hook, a plain button that writes the file to the
    /// given path so the test can read it.
    @ViewBuilder private var exportRow: some View {
        if let path = hooks.exportPath {
            Button("Export…", systemImage: "square.and.arrow.up") {
                exportToFile(atPath: path)
            }
            .accessibilityIdentifier("wordList.export")
        } else {
            let fileName = Exporter.fileName()
            ShareLink(
                item: ExportFile(fileName: fileName, makeData: exportData),
                preview: SharePreview(fileName)
            ) {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("wordList.export")
        }
    }

    private func exportData() throws -> Data {
        try Exporter.export(from: store, exportedAt: .now, appVersion: Bundle.main.wordhoardVersion)
    }

    private func exportToFile(atPath path: String) {
        do {
            try exportData().write(to: URL(filePath: path), options: .atomic)
        } catch {
            logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startImport() {
        if let path = hooks.importPath {
            importFile(at: URL(filePath: path), isSecurityScoped: false)
        } else {
            isImporterPresented = true
        }
    }

    private func importPicked(_ result: Result<URL, any Error>) {
        switch result {
        case let .success(url):
            importFile(at: url, isSecurityScoped: true)
        case let .failure(error):
            logger.error("File picker failed: \(error.localizedDescription, privacy: .public)")
            isReadFailurePresented = true
            model.reload()
        }
    }

    /// Reads the file into memory inside its security scope and hands the bytes to the model, which
    /// reloads the list whatever the outcome. A read failure is the view's alert; nothing reaches Core.
    private func importFile(at url: URL, isSecurityScoped: Bool) {
        let accessing = isSecurityScoped && url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try coordinatedRead(url)
            model.importWords(data)
        } catch {
            logger.error("Could not read the picked file: \(error.localizedDescription, privacy: .public)")
            isReadFailurePresented = true
            model.reload()
        }
    }

    /// Reads through a file coordinator so an iCloud Drive placeholder that is not downloaded yet is
    /// fetched first instead of failing with a generic read error.
    private func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var read: Result<Data, any Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, error: &coordinationError) { readURL in
            read = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError {
            throw coordinationError
        }
        return try read.get()
    }

    /// Word counts only; senses, examples and tags are detail the alert does not need.
    private func importMessage(_ counts: ImportSummary) -> Text {
        Text("Added \(counts.wordsCreated), updated \(counts.wordsUpdated), skipped \(counts.wordsSkipped).")
    }

    private var isImportSummaryPresented: Binding<Bool> {
        Binding(
            get: { model.importSummary != nil },
            set: { isPresented in
                if !isPresented {
                    model.importSummary = nil
                }
            }
        )
    }

    // MARK: - Failures

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
