import FoundationModels
import SwiftUI

struct ContentView: View {
    @State private var word = ""
    @State private var isGenerating = false
    @State private var readableOutput = ""
    @State private var rawOutput = ""
    @State private var errorText: String?
    @State private var elapsedText: String?

    private let model = SystemLanguageModel.default

    private var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    private var availabilityText: String {
        switch model.availability {
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

                HStack {
                    TextField("English word", text: $word)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(generate)
                    Button("Generate", action: generate)
                        .buttonStyle(.borderedProminent)
                        .disabled(!isAvailable || isGenerating || trimmedWord.isEmpty)
                }

                if isGenerating {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Generating…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let elapsedText {
                    Text(elapsedText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !readableOutput.isEmpty {
                            Text("Card")
                                .font(.headline)
                            Text(readableOutput)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if !rawOutput.isEmpty {
                            Text("Raw JSON")
                                .font(.headline)
                            Text(rawOutput)
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
    }

    private var trimmedWord: String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generate() {
        let target = trimmedWord
        guard isAvailable, !isGenerating, !target.isEmpty else { return }

        isGenerating = true
        errorText = nil
        elapsedText = nil
        readableOutput = ""
        rawOutput = ""

        Task {
            do {
                let result = try await generateCard(for: target)
                readableOutput = result.card.readableDescription
                rawOutput = result.rawJSON
                elapsedText = "Took \(result.elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))"
            } catch let error as LanguageModelSession.GenerationError {
                errorText = "GenerationError: \(error.errorDescription ?? String(describing: error))"
                print("GenerationError: \(error)")
            } catch {
                errorText = "Error: \(error.localizedDescription)"
                print("Error: \(error)")
            }
            isGenerating = false
        }
    }
}

#Preview {
    ContentView()
}
