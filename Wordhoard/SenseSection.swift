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
            // Short placeholders keep the definition's size at AX5; the stored "big, large" shows the commas.
            CommittingTextField(Text("Synonyms"), value: joined(sense.synonyms)) { text in
                model.setSynonyms(text, for: sense)
            }
            .accessibilityIdentifier(identifier("synonyms"))
            CommittingTextField(Text("Antonyms"), value: joined(sense.antonyms)) { text in
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
            Button {
                model.addExample(to: sense)
            } label: {
                AddRowLabel(title: Text("Add example"))
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
            // 6.1: a 44 pt target around the 18 pt symbol.
            Image(systemName: "ellipsis.circle")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Sense actions")
        .accessibilityIdentifier(identifier("menu"))
    }

    /// A neutral example is its text field; a tagged one adds the badge link (3.3). The field stays its
    /// own editable accessibility element and the link is read "Topic: <name>" (6.1, W2), so VoiceOver
    /// can still edit a tagged example.
    @ViewBuilder
    private func exampleRow(_ example: Example, position: Int) -> some View {
        if let topic = example.grammarTopic.flatMap(GrammarCatalog.english.topic(for:)) {
            HStack(alignment: .firstTextBaseline) {
                exampleField(example, position: position)
                // Plan 3.3: the badge opens the topic's examples; plain style keeps the hit area the badge's own.
                NavigationLink(value: Route.topic(topic.key)) {
                    // 6.1: the padding makes the hit area 44 pt tall; the capsule stays its own size.
                    badge(Text(verbatim: topic.name))
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .navigationLinkIndicatorVisibility(.hidden)
                .accessibilityLabel(Text("Topic: \(topic.name)"))
                .accessibilityIdentifier(identifier("example.\(position).topicBadge"))
            }
        } else {
            exampleField(example, position: position)
        }
    }

    private func exampleField(_ example: Example, position: Int) -> some View {
        CommittingTextField(Text("Example sentence"), value: example.text, axis: .vertical) { text in
            model.setExampleText(text, for: example)
        }
        .accessibilityIdentifier(identifier("example.\(position).text"))
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
        case .wiktionary:
            Text("Wiktionary")
        case .wordnet:
            Text("WordNet")
        case .model:
            Text("Model")
        }
    }

    /// Primary text in an outlined capsule on the row's own background, so the badge passes the contrast
    /// audit at every size (6.1).
    private func badge(_ text: Text) -> some View {
        text
            .font(.footnote)
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(.secondary))
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
