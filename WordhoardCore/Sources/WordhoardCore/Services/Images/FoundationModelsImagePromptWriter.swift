import Foundation
import FoundationModels
import os

/// The production `ImagePromptWriter` (plan 4.2, I1, I5) over the on-device model only: one short call,
/// so no Private Cloud Compute tier. Follows the `CardGenerator` conventions: availability is checked
/// before any session exists, every call uses one fresh session, the prompt text lives in
/// `Services/Prompts/ImagePrompt.swift`, errors are typed.
///
/// **Isolation: none.** A stateless `Sendable` struct.
public struct FoundationModelsImagePromptWriter: ImagePromptWriter {
    private static let logger = Logger(subsystem: "Wordhoard", category: "images")

    public init() {}

    public var availability: ImageGeneratorAvailability {
        get async {
            if case .available = SystemLanguageModel.default.availability {
                return .available
            }
            return .unavailable
        }
    }

    public func imagePrompt(headword: String, definition: String?) async throws -> String? {
        guard await availability == .available else {
            throw ImagePromptError.unavailable
        }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: ImagePrompt.instructions)
        do {
            let response = try await session.respond(
                to: ImagePrompt.prompt(headword: headword, definition: definition),
                generating: ImagePromptSuggestion.self,
                options: GenerationOptions(temperature: GenerationDefaults.temperature)
            )
            return ImagePrompt.result(prompt: response.content.prompt, drawable: response.content.drawable)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LanguageModelError {
            Self.logger.notice("Picture prompt failed: \(String(describing: error), privacy: .public)")
            switch error {
            case .guardrailViolation, .refusal:
                throw ImagePromptError.refused
            default:
                throw ImagePromptError.failed
            }
        } catch {
            Self.logger.notice("Picture prompt failed: \(error.localizedDescription, privacy: .public)")
            throw ImagePromptError.failed
        }
    }
}
