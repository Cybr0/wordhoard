import FoundationModels
import SwiftUI

struct ContentView: View {
    @State private var word = ""
    @State private var model = CardGenerationModel()
    @State private var showPCCStatus = false

    private let languageModel = SystemLanguageModel.default
    private var pcc: PCCStatus { PCCStatus.shared }

    private var isAvailable: Bool {
        if case .available = languageModel.availability { return true }
        return false
    }

    /// PCC mode is gated on the server model's availability, the others on the on-device one.
    private var canGenerate: Bool {
        model.mode == .pcc ? pcc.isAvailable : isAvailable
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

                pccStatusSection

                Picker("Mode", selection: $model.mode) {
                    ForEach(CardGenerationModel.Mode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isGenerating)

                Text(model.mode.rawValue)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if model.mode == .pcc {
                    if !pcc.isSupported {
                        // The segment is selectable but nothing can run: iOS 26 has no PCC API.
                        Text("PCC: requires iOS 27 — this mode is disabled on this device.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else {
                        Toggle("PCC alone (single call, no WordNet)", isOn: $model.pccSingleCall)
                            .font(.footnote)
                            .disabled(model.isGenerating)
                    }
                }

                if model.mode != .single, !(model.mode == .pcc && (model.pccSingleCall || !pcc.isSupported)) {
                    Toggle(
                        model.mode == .wordNet || model.mode == .pcc
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
                            .disabled(!canGenerate || trimmedWord.isEmpty)
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
                        if let pccRequests = model.pccRequestsThisRun {
                            Text("PCC requests this run: \(pccRequests) · since launch: \(pcc.requestsThisLaunch)")
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

                if let translationNote = model.translationNote {
                    Text(translationNote)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                if let verificationNote = model.verificationNote {
                    Text(verificationNote)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if let pccQuotaNote = model.pccQuotaNote {
                    Text(pccQuotaNote)
                        .font(.caption2)
                        .foregroundStyle(.purple)
                        .textSelection(.enabled)
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
        .task {
            // Issue #15: log PCC availability, context size, languages and quota at launch.
            await PCCStatus.shared.probeAtLaunch()
            runLaunchArgumentProbe()
        }
    }

    /// Headless probe for `simctl launch` / Xcode scheme arguments (issue #15):
    /// `-pccProbeWord book` generates that word in PCC mode at launch; `-pccProbeVariant b`
    /// selects "PCC alone" (default `a`, WordNet + PCC). Everything is printed as usual.
    private func runLaunchArgumentProbe() {
        let defaults = UserDefaults.standard
        guard let probeWord = defaults.string(forKey: "pccProbeWord")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !probeWord.isEmpty else { return }
        let variant = defaults.string(forKey: "pccProbeVariant") ?? "a"
        guard pcc.isAvailable else {
            print("PCC: probe word \"\(probeWord)\" skipped — \(pcc.availabilityText)")
            return
        }
        model.mode = .pcc
        model.pccSingleCall = variant.lowercased() == "b"
        word = probeWord
        print("PCC: launch-argument probe: \"\(probeWord)\", variant \(model.pccSingleCall ? "b (PCC alone)" : "a (WordNet + PCC)")")
        model.generate(word: probeWord)
    }

    /// Collapsible "PCC status": the one-line availability as the label, the launch log inside.
    private var pccStatusSection: some View {
        DisclosureGroup(isExpanded: $showPCCStatus) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(pcc.launchLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
                if pcc.isSupported {
                    Text("PCC requests since launch: \(pcc.requestsThisLaunch)")
                    if let last = pcc.lastRequestLabel {
                        Text("Last request: \(last)")
                    }
                    Button("Re-read availability and quota") {
                        pcc.refreshAvailability()
                        showPCCStatus = true
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(pcc.availabilityText, systemImage: pcc.isAvailable ? "cloud.fill" : "cloud.slash")
                .foregroundStyle(pcc.isAvailable ? .green : (pcc.isSupported ? .red : .secondary))
                .font(.footnote)
        }
    }

    private var trimmedWord: String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generate() {
        let target = trimmedWord
        guard canGenerate, !target.isEmpty else { return }
        model.generate(word: target)
    }
}

#Preview {
    ContentView()
}
