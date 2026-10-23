import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WordhoardCore

/// Settings (S1–S3, S5, S6; plan 5.3, #45): a sheet over the word list with its own stack and Done.
/// Grammar → the 3.1 topics screen; Images → the auto-pictures toggle;
/// Data → export and import (1.7, moved here from the list's "More" menu); About. The Private Cloud
/// Compute toggle (A10) is not built: it arrives with the entitlement. Every write goes through
/// `SettingsModel`; the import hands the picked file's bytes to it, so Core never sees a URL.
struct SettingsView: View {
    @State var model: SettingsModel
    @State var isImporterPresented = false
    @State var isReadFailurePresented = false
    /// Whether pictures can be made on this device; until known, the toggle is enabled.
    @State private var canGeneratePictures = true
    @Environment(\.dismiss) private var dismiss
    let store: WordStore
    /// Read for the generator's availability (the toggle's notice, 6.2).
    let imageQueue: ImageGenerationQueue
    let hooks: UITestingHooks
    let logger = Logger(subsystem: "Wordhoard", category: "transfer")

    init(store: WordStore, autofill: AutofillService, imageQueue: ImageGenerationQueue, hooks: UITestingHooks) {
        _model = State(initialValue: SettingsModel(store: store, autofill: autofill))
        self.store = store
        self.imageQueue = imageQueue
        self.hooks = hooks
    }

    var body: some View {
        NavigationStack {
            Form {
                grammarSection
                imagesSection
                dataSection
                Section("About") {
                    NavigationLink(value: SettingsRoute.about) {
                        Text("About Wordhoard")
                    }
                    .accessibilityIdentifier("settings.about")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self, destination: destination)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("settings.done")
                }
            }
            .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.json], onCompletion: importPicked)
            .alert(failureTitle, isPresented: isFailurePresented) {
                Button("OK", role: .cancel) {}
            } message: {
                if case let .importing(description?) = model.failure {
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
            .onAppear(perform: model.load)
        }
    }

    // MARK: - Sections

    private var grammarSection: some View {
        Section("Grammar") {
            NavigationLink(value: SettingsRoute.topics) {
                LabeledContent {
                    Text("\(model.activeTopics.count) of \(model.catalog.topics.count)")
                } label: {
                    Text("Topics I'm learning")
                }
            }
            .accessibilityIdentifier("settings.topics")
        }
    }

    private var imagesSection: some View {
        Section {
            Toggle("Generate images automatically", isOn: autoImages)
                .disabled(!canGeneratePictures)
                .accessibilityIdentifier("settings.autoImages")
        } header: {
            Text("Images")
        } footer: {
            // 6.2: a persistent condition is the disabled control's footer, never an alert.
            if canGeneratePictures {
                Text("Wordhoard makes a picture for each new word on your iPhone. You can always add a photo yourself.")
            } else {
                Text("Image Playground isn't available on this iPhone")
                    .accessibilityIdentifier("settings.imagesUnavailable")
            }
        }
        .task {
            let writer = await imageQueue.promptWriter.availability
            let generator = await imageQueue.generator.availability
            canGeneratePictures = writer == .available && generator == .available
        }
    }

    private var autoImages: Binding<Bool> {
        Binding(get: { model.autoGenerateImages }, set: { model.setAutoGenerateImages($0) })
    }

    private var dataSection: some View {
        Section {
            exportRow
            Button("Import…", systemImage: "square.and.arrow.down", action: startImport)
                .accessibilityIdentifier("settings.import")
        } header: {
            Text("Data")
        } footer: {
            Text(
                "Your words, senses and settings as one JSON file. Importing merges by word and never deletes anything."
            )
        }
    }

    @ViewBuilder private func destination(_ route: SettingsRoute) -> some View {
        switch route {
        case .topics:
            GrammarTopicsView(store: store)
        case .about:
            AboutView()
        case .wordNetLicense:
            LicenseTextView(title: Text("Open English WordNet license"), text: CoreInfo.wordNetLicenseText())
        case .wiktionaryLicense:
            LicenseTextView(title: Text("Simple English Wiktionary license"), text: CoreInfo.wiktionaryLicenseText())
        case .appLicense:
            LicenseTextView(title: Text("Apache License 2.0"), text: AboutView.appLicenseText())
        }
    }

    // MARK: - Failures

    private var failureTitle: Text {
        switch model.failure {
        case .loading:
            Text("Couldn't load your settings")
        case .saving:
            Text("Couldn't save your settings")
        case .importing:
            Text("Couldn't import")
        case nil:
            Text(verbatim: String())
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
