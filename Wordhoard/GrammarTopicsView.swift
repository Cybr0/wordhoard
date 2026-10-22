import SwiftUI
import WordhoardCore

/// "Topics I'm learning" (G2, S2; plan 3.1 to #45's spec): one section per catalog group, a checkmark on
/// every active topic, a "Default" caption on the catalog's default set, "Reset to default" in the
/// toolbar. Every write goes through `SettingsModel`. Has no navigation stack of its own: the list's
/// stack pushes it now, the Settings sheet's stack in 5.3.
struct GrammarTopicsView: View {
    @State private var model: SettingsModel

    init(store: WordStore) {
        _model = State(initialValue: SettingsModel(store: store))
    }

    var body: some View {
        List {
            if model.catalog.topics.isEmpty {
                // 6.2: the catalog is bundled, so this is a build defect, never a crash.
                ContentUnavailableView("Couldn't load the grammar topics.", systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("settings.topics.loadFailure")
            }
            ForEach(model.catalog.groups, id: \.name) { group in
                Section {
                    ForEach(group.topics) { topic in
                        row(topic)
                    }
                } header: {
                    Text(verbatim: group.name)
                } footer: {
                    if group == model.catalog.groups.last {
                        Text(Self.footer)
                    }
                }
            }
        }
        .navigationTitle("Topics I'm learning")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset to default") {
                    model.resetTopicsToDefault()
                }
                .accessibilityIdentifier("settings.topics.reset")
            }
        }
        .alert(failureTitle, isPresented: isFailurePresented) {
            Button("OK", role: .cancel) {}
        }
        .onAppear(perform: model.load)
    }

    private static let footer: LocalizedStringKey =
        "Autofill writes one extra example per active topic for every sense, so more topics mean slower cards."

    private func row(_ topic: GrammarTopic) -> some View {
        let isActive = model.activeTopics.contains(topic.key)
        return Button {
            model.setTopicActive(topic.key, !isActive)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: topic.name)
                    if model.catalog.defaultActiveKeys.contains(topic.key) {
                        Text("Default")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("settings.topics.\(topic.key)")
    }

    private var failureTitle: Text {
        switch model.failure {
        case .loading:
            Text("Couldn't load your settings")
        case .saving:
            Text("Couldn't save your settings")
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
