import Foundation
import FoundationModels
import os

/// The production `ModelCalls` over Apple's Foundation Models (ADR 0001 point 2).
///
/// **Isolation: none.** A stateless `Sendable` struct; every method creates **one fresh
/// `LanguageModelSession`** through `makeSession`, calls `respond(to:generating:options:)` once and
/// discards the session, so no transcript accumulates and the 4K context is never approached.
/// Callers check `availability()` first; the methods themselves do not. Prompt text and `@Generable`
/// output types live in `Services/Prompts/`, nowhere else.
///
/// Logging: call label and duration at `.debug`; never the prompt or the output at `.info` or above.
public struct FoundationModelCalls: ModelCalls {
    private static let logger = Logger(subsystem: "Wordhoard", category: "autofill")
    private static let options = GenerationOptions(temperature: GenerationDefaults.temperature)

    public init() {}

    public func availability() async -> CardGeneratorAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            .available
        case .unavailable(.deviceNotEligible):
            .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady):
            .unavailable(.modelNotReady)
        case .unavailable:
            .unavailable(.unknown)
        }
    }

    public func proposeSenses(headword: String, wordClass: FunctionWordClass?) async throws -> [ProposedSense] {
        let entry = try await respond(
            instructions: SensesPrompt.instructions,
            prompt: SensesPrompt.prompt(headword: headword, wordClass: wordClass),
            generating: ProposedEntry.self,
            label: "senses"
        )
        return entry.senses.map { sense in
            ProposedSense(
                partOfSpeech: sense.partOfSpeech.partOfSpeech,
                definition: sense.definition.trimmingCharacters(in: .whitespacesAndNewlines),
                synonyms: sense.synonyms,
                antonyms: sense.antonyms
            )
        }
    }

    public func verify(headword: String, sense: ProposedSense, wordClass: FunctionWordClass?) async throws -> Bool {
        let verdict = try await respond(
            instructions: VerifierPrompt.instructions,
            prompt: VerifierPrompt.prompt(
                headword: headword,
                partOfSpeech: sense.partOfSpeech,
                definition: sense.definition,
                wordClass: wordClass
            ),
            generating: SenseVerdict.self,
            label: "verify"
        )
        return verdict.isCommonlyUsed
    }

    /// The prompt numbers candidates from 1; the answer is mapped back to 0-based indices here.
    public func selectSenses(headword: String, candidates: [WordNetSense]) async throws -> [Int] {
        let selection = try await respond(
            instructions: SenseSelectionPrompt.instructions,
            prompt: SenseSelectionPrompt.prompt(headword: headword, candidates: candidates),
            generating: SenseSelection.self,
            label: "select senses"
        )
        return selection.numbers.map { $0 - 1 }
    }

    public func writeDefinition(headword: String, sense: WordNetSense) async throws -> String {
        let writing = try await respond(
            instructions: DefinitionPrompt.instructions,
            prompt: DefinitionPrompt.prompt(headword: headword, sense: sense),
            generating: SenseWriting.self,
            label: "definition"
        )
        return writing.learnerDefinition.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func writeExample(
        headword: String,
        partOfSpeech: PartOfSpeech,
        definition: String,
        topic: GrammarTopic?,
        mustContainHeadword: Bool
    ) async throws -> ExampleAnswer {
        let reply = try await respond(
            instructions: ExamplePrompt.instructions,
            prompt: ExamplePrompt.prompt(
                headword: headword,
                partOfSpeech: partOfSpeech,
                definition: definition,
                topic: topic,
                mustContainHeadword: mustContainHeadword
            ),
            generating: ExampleReply.self,
            label: topic == nil ? "neutral example" : "topic example"
        )
        return ExampleAnswer(fits: reply.fits, text: reply.text)
    }

    // MARK: - The one session factory

    /// The only place a session is created. The Private Cloud Compute tier (A10, ADR 0001 appendix F)
    /// is compiled in only when the build defines `WORDHOARD_PCC`, which the build configuration sets
    /// solely when the provisioning profile carries the `com.apple.developer.private-cloud-compute`
    /// entitlement: without it the first request crashes instead of throwing, so `availability` alone
    /// is not a safe gate. No build defines the flag today; the on-device model is the only live path.
    private static func makeSession(instructions: String) -> LanguageModelSession {
        #if WORDHOARD_PCC
            let model = PrivateCloudComputeLanguageModel()
        #else
            let model = SystemLanguageModel.default
        #endif
        return LanguageModelSession(model: model, instructions: instructions)
    }

    /// One structured generation in a fresh session. Maps the framework's errors to `ModelCallError`;
    /// cancellation passes through untouched.
    private func respond<Content: Generable & Sendable>(
        instructions: String,
        prompt: String,
        generating type: Content.Type,
        label: String
    ) async throws -> Content {
        let session = Self.makeSession(instructions: instructions)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await session.respond(to: prompt, generating: type, options: Self.options)
            Self.logger.debug(
                "\(label, privacy: .public) call took \((clock.now - start).formattedSeconds, privacy: .public)"
            )
            return response.content
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let mapped = Self.modelCallError(for: error)
            let elapsed = (clock.now - start).formattedSeconds
            Self.logger.debug(
                """
                \(label, privacy: .public) call failed after \(elapsed, privacy: .public): \
                \(String(describing: mapped), privacy: .public)
                """
            )
            throw mapped
        }
    }

    /// iOS 27 throws the top-level `LanguageModelError`; its guardrail and refusal cases are `.refused`.
    private static func modelCallError(for error: any Error) -> ModelCallError {
        if let modelError = error as? LanguageModelError {
            switch modelError {
            case .guardrailViolation, .refusal:
                return .refused
            default:
                break
            }
        }
        return .failed(String(describing: error))
    }
}

extension Duration {
    /// `"1.7 s"`, for log lines.
    var formattedSeconds: String {
        formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
    }
}
