import SwiftUI
import WordhoardCore

/// The word card (W1, W2, W3): the headword, one section per sense and the add, remove, reorder and
/// delete actions. Talks only to `WordCardModel`; every edit is held in a field's local state and
/// committed through one model setter when the edit ends.
struct WordCardView: View {
    @State private var model: WordCardModel
    @State private var isDeleteDialogPresented = false
    @Environment(\.dismiss) private var dismiss

    init(word: Word, store: WordStore) {
        _model = State(initialValue: WordCardModel(word: word, store: store))
    }

    private var word: Word {
        model.word
    }

    var body: some View {
        List {
            headwordSection
            if model.senses.isEmpty {
                emptyState
            }
            ForEach(Array(model.senses.enumerated()), id: \.element.id) { index, sense in
                SenseSection(model: model, sense: sense, index: index, count: model.senses.count)
            }
            Section {
                Button("Add sense", systemImage: "plus") {
                    model.addSense()
                }
                .accessibilityIdentifier("wordCard.addSense")
            }
        }
        .navigationTitle(word.headword)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .confirmationDialog(
            Text("Delete “\(word.headword)”?"),
            isPresented: $isDeleteDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: deleteWord)
                .accessibilityIdentifier("wordCard.deleteConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The word and all its senses will be removed.")
        }
        .alert(failureTitle, isPresented: isFailurePresented) {
            Button("OK", role: .cancel) {}
        }
    }

    private var headwordSection: some View {
        Section {
            CommittingTextField(Text(verbatim: word.headword), value: word.headword) { text in
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
        }
    }

    private func headwordMessage(for rejection: WordCardModel.HeadwordRejection) -> Text {
        switch rejection {
        case .empty:
            Text("The headword can't be empty.")
        case let .collision(existingHeadword):
            Text("“\(existingHeadword)” is already in your words.")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView("No senses yet", systemImage: "text.book.closed")
            .accessibilityIdentifier("wordCard.emptyState")
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private var failureTitle: Text {
        switch model.failure {
        case .saving:
            Text("Couldn't save your changes")
        case .deleting:
            Text("Couldn't delete the word")
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

    /// The delete is saved before the pop: the list reloads when the path changes, which happens before
    /// this card's `onDisappear`, so a delete done any later would leave the row visible.
    private func deleteWord() {
        if model.deleteWord() {
            dismiss()
        }
    }
}

/// One sense: the part-of-speech picker, source badge and actions menu in the header; the four fields,
/// the examples in order and the "Add example" row below.
private struct SenseSection: View {
    let model: WordCardModel
    let sense: Sense
    /// 0-based position in display order; part of the accessibility identifiers.
    let index: Int
    let count: Int

    var body: some View {
        Section {
            CommittingTextField(Text("Definition"), value: sense.definition, axis: .vertical) { text in
                model.setDefinition(text, for: sense)
            }
            .accessibilityIdentifier(identifier("definition"))
            CommittingTextField(Text("Translation"), value: sense.translation ?? "", axis: .vertical) { text in
                model.setTranslation(text, for: sense)
            }
            .accessibilityIdentifier(identifier("translation"))
            CommittingTextField(Text("Synonyms, separated by commas"), value: joined(sense.synonyms)) { text in
                model.setSynonyms(text, for: sense)
            }
            .accessibilityIdentifier(identifier("synonyms"))
            CommittingTextField(Text("Antonyms, separated by commas"), value: joined(sense.antonyms)) { text in
                model.setAntonyms(text, for: sense)
            }
            .accessibilityIdentifier(identifier("antonyms"))
            ForEach(Array(sense.sortedExamples.enumerated()), id: \.element.id) { position, example in
                exampleRow(example, position: position)
            }
            .onDelete(perform: removeExamples)
            .onMove { source, destination in
                model.moveExamples(in: sense, fromOffsets: source, toOffset: destination)
            }
            Button("Add example", systemImage: "plus") {
                model.addExample(to: sense)
            }
            .accessibilityIdentifier(identifier("addExample"))
        } header: {
            header
        }
    }

    private var header: some View {
        HStack {
            Picker("Part of speech", selection: partOfSpeech) {
                ForEach(PartOfSpeech.allCases, id: \.self) { partOfSpeech in
                    Text(partOfSpeech.displayName)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier(identifier("partOfSpeech"))
            if let source = sense.senseSource {
                badge(sourceName(source))
                    .accessibilityIdentifier(identifier("sourceBadge"))
            }
            Spacer()
            Menu {
                Button("Move up", systemImage: "arrow.up") {
                    model.moveSenses(fromOffsets: [index], toOffset: index - 1)
                }
                .disabled(index == 0)
                Button("Move down", systemImage: "arrow.down") {
                    model.moveSenses(fromOffsets: [index], toOffset: index + 2)
                }
                .disabled(index == count - 1)
                Button("Remove sense", systemImage: "trash", role: .destructive) {
                    model.removeSense(sense)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Sense actions")
            .accessibilityIdentifier(identifier("menu"))
        }
        .textCase(nil)
    }

    private func exampleRow(_ example: Example, position: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            CommittingTextField(Text("Example sentence"), value: example.text, axis: .vertical) { text in
                model.setExampleText(text, for: example)
            }
            .accessibilityIdentifier(identifier("example.\(position).text"))
            if let topic = example.grammarTopic.flatMap(GrammarCatalog.english.topic(for:)) {
                badge(Text(verbatim: topic.name))
                    .accessibilityIdentifier(identifier("example.\(position).topicBadge"))
            }
        }
    }

    /// The part of speech goes through the model like every other edit; the binding never writes to
    /// the sense itself.
    private var partOfSpeech: Binding<PartOfSpeech> {
        Binding(
            get: { sense.partOfSpeech },
            set: { model.setPartOfSpeech($0, for: sense) }
        )
    }

    private func sourceName(_ source: SenseSource) -> Text {
        switch source {
        case .wordnet:
            Text("WordNet")
        case .model:
            Text("Model")
        }
    }

    private func badge(_ text: Text) -> some View {
        text
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    private func removeExamples(at offsets: IndexSet) {
        let examples = sense.sortedExamples
        for example in offsets.compactMap({ examples.indices.contains($0) ? examples[$0] : nil }) {
            model.removeExample(example)
        }
    }

    private func joined(_ list: [String]) -> String {
        list.joined(separator: ", ")
    }

    private func identifier(_ element: String) -> String {
        "wordCard.sense.\(index).\(element)"
    }
}

/// A card over an in-memory store with one inserted and saved word, so the preview reads real
/// relationships: two senses, one with a WordNet badge, a translation, synonyms and a topic example.
@MainActor
private func previewCard() -> WordCardView? {
    guard let container = try? WordhoardContainer.makeInMemory() else {
        return nil
    }
    let store = WordStore(container: container)
    guard let word = try? store.add("book").word else {
        return nil
    }
    let noun = Sense(
        partOfSpeech: .noun,
        definition: "A written or printed work consisting of pages bound together.",
        order: 0,
        senseSource: .wordnet,
        translation: "книга",
        synonyms: ["volume", "tome"]
    )
    noun.examples = [
        Example(text: "She read a book on the train.", source: .auto, order: 0),
        Example(text: "I have read this book twice.", source: .auto, grammarTopic: "en.present_perfect", order: 1),
    ]
    let verb = Sense(partOfSpeech: .verb, definition: "To reserve a seat, room or table.", order: 1)
    word.senses = [noun, verb]
    try? store.save(word)
    return WordCardView(word: word, store: store)
}

#Preview {
    NavigationStack {
        previewCard()
    }
}
