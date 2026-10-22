import SwiftUI
import WordhoardCore

/// One sense: the part-of-speech picker, source badge and actions menu in the header; the four fields,
/// the examples in order and the "Add example" row below.
struct SenseSection: View {
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
            if sense.translationIsFallback {
                // Plan 2.10: the proposed equivalent was not confirmed, so this is the definition translated.
                Text("Translated from the definition")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(identifier("translationNote"))
            }
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

    /// Picker, badge and menu on one line; at accessibility sizes, where that no longer fits, the
    /// picker takes its own line so no label wraps mid-word.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                partOfSpeechPicker
                sourceBadge
                Spacer()
                actionsMenu
            }
            VStack(alignment: .leading) {
                partOfSpeechPicker
                HStack {
                    sourceBadge
                    Spacer()
                    actionsMenu
                }
            }
        }
        .textCase(nil)
    }

    private var partOfSpeechPicker: some View {
        Picker("Part of speech", selection: partOfSpeech) {
            ForEach(PartOfSpeech.allCases, id: \.self) { partOfSpeech in
                Text(partOfSpeech.displayName)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier(identifier("partOfSpeech"))
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if let source = sense.senseSource {
            badge(sourceName(source))
                .accessibilityIdentifier(identifier("sourceBadge"))
        }
    }

    private var actionsMenu: some View {
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

    private func exampleRow(_ example: Example, position: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            CommittingTextField(Text("Example sentence"), value: example.text, axis: .vertical) { text in
                model.setExampleText(text, for: example)
            }
            .accessibilityIdentifier(identifier("example.\(position).text"))
            if let topic = example.grammarTopic.flatMap(GrammarCatalog.english.topic(for:)) {
                // Plan 3.3: the badge opens the topic's examples; plain style keeps the hit area the badge's own.
                NavigationLink(value: Route.topic(topic.key)) {
                    badge(Text(verbatim: topic.name))
                }
                .buttonStyle(.plain)
                .navigationLinkIndicatorVisibility(.hidden)
                .accessibilityLabel(Text(verbatim: topic.name))
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
