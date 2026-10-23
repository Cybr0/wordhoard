import SwiftUI
import WordhoardCore

/// The word card (W1, W2, W3): the headword, the autofill status row (C5, A6), one section per sense and
/// the add, remove, reorder and delete actions. Talks only to `WordCardModel` for edits; every edit is
/// held in a field's local state and committed through one model setter when the edit ends. The
/// `AutofillService` is read for progress and asked to retry; it never mutates the card from here.
struct WordCardView: View {
    @State private var model: WordCardModel
    @State private var isDeleteDialogPresented = false
    /// Whether the generator can run now; checked on appear and on every foreground (A6). Until it
    /// says `.available`, no fill-in button is offered.
    @State private var isGeneratorAvailable = false
    /// Whether the picture generator and its prompt writer can both run now (plan 4.3/4.4).
    @State private var canGeneratePicture = false
    /// Between this card's `onAppear` and `onDisappear`: only a card on screen may dismiss itself, so a
    /// covered card does not pop the one that deleted the word.
    @State private var isOnScreen = false
    /// Set by `dismissOnce()`, so the delete button and `onChange` on the same card do not pop twice.
    @State private var isDismissing = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    private let autofill: AutofillService
    private let store: WordStore

    init(
        word: Word,
        store: WordStore,
        imageStore: ImageStore?,
        imageQueue: ImageGenerationQueue?,
        autofill: AutofillService
    ) {
        _model = State(initialValue: WordCardModel(
            word: word,
            store: store,
            imageStore: imageStore,
            imageQueue: imageQueue
        ))
        self.autofill = autofill
        self.store = store
    }

    private var word: Word {
        model.word
    }

    var body: some View {
        Group {
            // The card that deletes the word keeps its content while it slides out; the model already
            // refuses every edit, so only a deleted card still on screen afterwards shows the state.
            if model.isWordDeleted, !isDismissing {
                deletedState
            } else {
                card
            }
        }
        .navigationTitle(word.headword)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.isWordDeleted {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete word", systemImage: "trash", role: .destructive) {
                        isDeleteDialogPresented = true
                    }
                    .accessibilityIdentifier("wordCard.delete")
                }
            }
        }
        // An alert, not a confirmation dialog: it renders a labelled Cancel on every size class (6.1, #35).
        .alert(Text("Delete “\(word.headword)”?"), isPresented: $isDeleteDialogPresented) {
            Button("Delete", role: .destructive, action: deleteWord)
                .accessibilityIdentifier("wordCard.deleteConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The word and all its senses will be removed.")
        }
        .alert(failureTitle, isPresented: isFailurePresented) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: word.autofillState) { _, _ in
            // The service merges senses behind the model's back; re-read them when a fill ends or starts.
            model.reloadSenses()
        }
        .onAppear {
            isOnScreen = true
            isDismissing = false
            // The same word's card can be on the stack twice (card → badge → topic → example): the
            // other one may have deleted the word or changed its senses while this one was covered.
            if model.isWordDeleted {
                dismissOnce()
            } else {
                model.reloadSenses()
            }
        }
        .onDisappear {
            isOnScreen = false
        }
        .onChange(of: model.isWordDeleted) { _, isDeleted in
            if isDeleted, isOnScreen {
                dismissOnce()
            }
        }
        .task(id: isOnScreen, dismissIfStillDeleted)
        .task(checkAvailability)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await checkAvailability()
                }
            }
        }
    }

    /// The editable card; replaced by `deletedState` once the word is deleted, so nothing can edit it.
    private var card: some View {
        List {
            headwordSection
            PictureSection(model: model, canGenerate: canGeneratePicture, generate: model.generateImage)
            if model.senses.isEmpty, !isFilling {
                emptyState
            }
            ForEach(Array(model.senses.enumerated()), id: \.element.id) { index, sense in
                SenseSection(model: model, sense: sense, index: index, count: model.senses.count)
            }
            Section {
                Button {
                    model.addSense()
                } label: {
                    AddRowLabel(title: Text("Add sense"))
                }
                .accessibilityIdentifier("wordCard.addSense")
            }
        }
        // 6.2: a drag dismisses the keyboard; the system keeps the focused field above it.
        .scrollDismissesKeyboard(.interactively)
    }

    private var headwordSection: some View {
        Section {
            // "Headword" is the placeholder and so the label: VoiceOver reads "Headword, book" (6.1, #35).
            CommittingTextField(Text("Headword"), value: word.headword) { text in
                model.setHeadword(text)
            }
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            .font(.title2)
            .accessibilityIdentifier("wordCard.headword")
            if let rejection = model.headwordRejection {
                headwordMessage(for: rejection)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("wordCard.headwordMessage")
            }
            statusRow
        }
    }

    // MARK: - Autofill status (C5, A6)

    private var isFilling: Bool {
        word.autofillState == .pending || word.autofillState == .filling
    }

    /// Whether this word's topic examples are still arriving after its first card.
    private var isReceivingExamples: Bool {
        word.autofillState == .ready && autofill.currentWordID == word.id
    }

    /// One row under the headword, by state, with the card-level regenerate button (A5, plan 2.5):
    /// "Fill in again" on a ready card, "Try again" after a failure, "Fill in" when the device could not
    /// fill the card before; hidden while the word is in flight or the generator is unavailable. Editing
    /// is never blocked by the row (A7).
    @ViewBuilder private var statusRow: some View {
        switch word.autofillState {
        case .pending, .filling:
            progressRow(Text("Filling in…"))
        case .failed:
            // A failed card on a device that cannot fill now: the state is stale, say what matters.
            explanation(isGeneratorAvailable ? Text("Couldn't fill in this card.") : Text(Self.unavailableExplanation))
            regenerateButton(Text("Try again"))
        case .unavailable:
            explanation(Text(Self.unavailableExplanation))
            regenerateButton(Text("Fill in"))
        case .ready:
            if isReceivingExamples {
                progressRow(Text("Adding examples…"))
            } else {
                regenerateButton(Text("Fill in again"))
            }
        }
    }

    private func explanation(_ text: Text) -> some View {
        text
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("wordCard.status")
    }

    /// The one regenerate action; the merge decides what changes, so there is nothing to confirm.
    @ViewBuilder private func regenerateButton(_ label: Text) -> some View {
        if isGeneratorAvailable {
            Button {
                autofill.retry(word)
            } label: {
                label
            }
            .accessibilityIdentifier("wordCard.retry")
        }
    }

    private func checkAvailability() async {
        isGeneratorAvailable = await autofill.generator.availability() == .available
        if let queue = model.imageQueue {
            let writer = await queue.promptWriter.availability
            let generator = await queue.generator.availability
            canGeneratePicture = writer == .available && generator == .available
        } else {
            canGeneratePicture = false
        }
    }

    private static let unavailableExplanation: LocalizedStringKey =
        "Apple Intelligence isn't available on this device. Fill in the card by hand."

    /// A spinner with its words beside it (6.2: never a bare spinner); one element for VoiceOver.
    private func progressRow(_ text: Text) -> some View {
        HStack {
            ProgressView {
                text
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityHidden(true)
            text
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wordCard.status")
    }

    private func headwordMessage(for rejection: WordCardModel.HeadwordRejection) -> Text {
        switch rejection {
        case .empty:
            Text("The headword can't be empty.")
        case let .collision(existingHeadword):
            Text("“\(existingHeadword)” is already in your words.")
        }
    }

    /// After a fill that found nothing (A1) the description says so; otherwise the plain 1.6 empty state.
    private var emptyState: some View {
        Group {
            if word.autofillState == .ready {
                ContentUnavailableView(
                    "No senses yet",
                    systemImage: "text.book.closed",
                    description: Text("Nothing was found for this word. Add a sense by hand.")
                )
            } else {
                ContentUnavailableView("No senses yet", systemImage: "text.book.closed")
            }
        }
        .accessibilityIdentifier("wordCard.emptyState")
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

// MARK: - Failures and delete

extension WordCardView {
    private var failureTitle: Text {
        switch model.failure {
        case .saving:
            Text("Couldn't save your changes")
        case .deleting:
            Text("Couldn't delete the word")
        case .savingImage:
            Text("Couldn't save the picture")
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

    /// The delete is saved before the pop: the list reloads when the path changes, which happens before
    /// this card's `onDisappear`, so a delete done any later would leave the row visible.
    private func deleteWord() {
        if model.deleteWord() {
            dismissOnce()
        }
    }
}

// MARK: - Deleted word

extension WordCardView {
    /// What a deleted word's card shows if it is still on screen, e.g. after a cancelled Back swipe.
    private var deletedState: some View {
        ContentUnavailableView("This word was deleted.", systemImage: "trash")
            .accessibilityIdentifier("wordCard.deletedState")
    }

    private func dismissOnce() {
        guard !isDismissing else {
            return
        }
        isDismissing = true
        dismiss()
    }

    /// An interactive Back can start this card's appearance, swallow the on-appear dismiss and then be
    /// cancelled, leaving the card on top. Check again once the transition has settled: a card still on
    /// screen and deleted after 600 ms was not dismissed, so the earlier attempt is forgotten and the retry
    /// goes through `dismissOnce()` like every other dismiss. The task is cancelled when the card leaves
    /// the screen, so it never pops another screen.
    private func dismissIfStillDeleted() async {
        guard isOnScreen, model.isWordDeleted,
              await (try? Task.sleep(for: .milliseconds(600))) != nil,
              isOnScreen, model.isWordDeleted
        else {
            return
        }
        isDismissing = false
        dismissOnce()
    }
}
