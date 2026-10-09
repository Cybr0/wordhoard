import FoundationModels
import SwiftUI

struct ContentView: View {
    @State private var word = ""
    @State private var model = CardGenerationModel()

    private let languageModel = SystemLanguageModel.default

    private var isAvailable: Bool {
        if case .available = languageModel.availability { return true }
        return false
    }

    private var availabilityText: String {
        switch languageModel.availability {
        case .available:
            return "Model available"
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible:
                return "Unavailable: device not eligible for Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                return "Unavailable: Apple Intelligence is not enabled in Settings"
            case .modelNotReady:
                return "Unavailable: model not ready (still downloading?)"
            @unknown default:
                return "Unavailable: \(String(describing: reason))"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Label(availabilityText, systemImage: isAvailable ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(isAvailable ? .green : .red)
                    .font(.footnote)

                Picker("Mode", selection: $model.mode) {
                    ForEach(CardGenerationModel.Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isGenerating)

                if model.mode != .single {
                    Toggle(
                        model.mode == .wordNet
                            ? "Verify model senses (fallback only; WordNet senses are not verified)"
                            : "Verify each sense (one yes/no call per sense)",
                        isOn: $model.verifySenses
                    )
                    .font(.footnote)
                    .disabled(model.isGenerating)
                    Toggle("Parallel example calls (3 at a time)", isOn: $model.parallelExamples)
                        .font(.footnote)
                        .disabled(model.isGenerating)
                }

                HStack {
                    TextField("English word", text: $word)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(generate)
                    if model.isGenerating {
                        Button("Cancel", role: .cancel) { model.cancel() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Generate", action: generate)
                            .buttonStyle(.borderedProminent)
                            .disabled(!isAvailable || trimmedWord.isEmpty)
                    }
                }

                HStack(spacing: 8) {
                    if model.isGenerating {
                        ProgressView()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if !model.statusText.isEmpty {
                            Text(model.statusText)
                        }
                        if !model.timingText.isEmpty {
                            Text(model.timingText)
                                .fontWeight(.semibold)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if let wordNetNote = model.wordNetNote {
                    Text(wordNetNote)
                        .font(.footnote)
                        .foregroundStyle(.blue)
                        .textSelection(.enabled)
                }

                if let verificationNote = model.verificationNote {
                    Text(verificationNote)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if let errorText = model.errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let card = model.card {
                            Text("Card")
                                .font(.headline)
                            Text(card.readableDescription)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if !model.rawLog.isEmpty {
                            Text("Raw JSON (\(model.callCount) call\(model.callCount == 1 ? "" : "s"))")
                                .font(.headline)
                            Text(model.rawLog)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .navigationTitle("Wordhoard Spike")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            // Decode the WordNet bundle at launch, off the main actor, so the first lookup
            // in "WordNet + model" mode does not pay for it; the load time is printed.
            await WordNetLookup.shared.warmUp()
        }
    }

    private var trimmedWord: String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generate() {
        let target = trimmedWord
        guard isAvailable, !target.isEmpty else { return }
        model.generate(word: target)
    }
}

#Preview {
    ContentView()
}
