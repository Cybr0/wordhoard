// Phase 0 spike, issue #15: everything the probe knows about Private Cloud Compute.
//
// `PCCStatus.shared` is a @MainActor @Observable singleton that
//   - at launch, reads `PrivateCloudComputeLanguageModel().availability`, `capabilities`,
//     `contextSize`, `supportedLanguages` and `quotaUsage` and keeps the lines for the screen
//     (and prints them, prefixed `PCC:`), spelling out every enum case by name;
//   - counts every PCC request the app attempts since launch (CardGeneration.swift calls
//     `noteRequest` right before each PCC `respond`);
//   - describes `quotaUsage` on demand so the generation model can log it after each call batch;
//   - names PCC-specific and iOS 27 `LanguageModelError` cases when a call fails.
//
// Everything that touches `PrivateCloudComputeLanguageModel` sits behind `#available(iOS 27, *)`;
// the deployment target stays iOS 26, where the probe only reports "requires iOS 27".
// No `FoundationModels` call is made here other than reading those properties.
//
// Throwaway code. Not held to the root CLAUDE.md conventions (print is fine here).

import Foundation
import FoundationModels
import Observation

/// Which model a `LanguageModelSession` targets. The on-device model is the iOS 26 baseline;
/// the server model (`PrivateCloudComputeLanguageModel`) exists from iOS 27.
enum ModelBackend: String, Sendable {
    case onDevice = "on-device"
    case privateCloudCompute = "pcc"
}

/// The PCC backend was asked for on a system that has no such API.
struct PCCUnsupportedError: Error, LocalizedError {
    var errorDescription: String? { "PCC: requires iOS 27 (this device runs an older iOS)" }
}

@MainActor
@Observable
final class PCCStatus {
    static let shared = PCCStatus()

    /// True when the OS has `PrivateCloudComputeLanguageModel` at all (iOS 27+).
    let isSupported: Bool = {
        if #available(iOS 27, *) { return true }
        return false
    }()

    /// `PrivateCloudComputeLanguageModel().availability == .available` as read at launch
    /// (and re-read by `refreshAvailability()`).
    private(set) var isAvailable = false
    /// One line for the label next to the mode picker.
    private(set) var availabilityText = "PCC: not probed yet"
    /// Launch report, one line per fact, as printed to the console.
    private(set) var launchLines: [String] = []
    /// Every PCC request attempted since launch (counted before the call, so failures count).
    private(set) var requestsThisLaunch = 0
    /// Labels of the last few requests, for the status section.
    private(set) var lastRequestLabel: String?

    private init() {}

    // MARK: Launch probe

    /// Reads and logs availability, capabilities, context size, supported languages and quota.
    /// Called once from the root view's `.task`.
    func probeAtLaunch() async {
        launchLines = []
        guard #available(iOS 27, *) else {
            isAvailable = false
            availabilityText = "PCC: requires iOS 27"
            log("PCC: requires iOS 27 — PrivateCloudComputeLanguageModel is not in this OS; the PCC mode is disabled")
            return
        }
        let model = PrivateCloudComputeLanguageModel()

        let availability = Self.describe(model.availability)
        if case .available = model.availability {
            isAvailable = true
        } else {
            isAvailable = false
        }
        availabilityText = "PCC: \(availability)"
        log("PCC: availability = \(availability)")
        log("PCC: isAvailable = \(model.isAvailable)")

        let capabilities = [
            ("guidedGeneration", LanguageModelCapabilities.Capability.guidedGeneration),
            ("reasoning", .reasoning),
            ("toolCalling", .toolCalling),
            ("vision", .vision),
        ].map { name, capability in "\(name)=\(model.capabilities.contains(capability))" }
        log("PCC: capabilities: \(capabilities.joined(separator: ", "))")

        do {
            let contextSize = try await model.contextSize
            log("PCC: contextSize = \(contextSize) tokens")
        } catch {
            log("PCC: contextSize failed: \(Self.describe(error))")
        }

        do {
            let languages = try await model.supportedLanguages
            let identifiers = languages.map(\.minimalIdentifier).sorted()
            let sample = identifiers.prefix(8).joined(separator: ", ")
            let more = identifiers.count > 8 ? ", … (+\(identifiers.count - 8))" : ""
            log("PCC: supportedLanguages = \(identifiers.count): \(sample)\(more)")
            let supportsCurrent = try await model.supportsLocale()
            log("PCC: supportsLocale(\(Locale.current.identifier)) = \(supportsCurrent)")
        } catch {
            log("PCC: supportedLanguages failed: \(Self.describe(error))")
        }

        log("PCC: quotaUsage at launch: \(Self.describe(model.quotaUsage))")
        log("PCC: generation uses ContextOptions(reasoningLevel: .light); flip `pccReasoningLevel` in CardGeneration.swift to compare")
        log("PCC: quota sheet API: PrivateCloudComputeLanguageModel.QuotaUsage.LimitIncreaseSuggestion.show() (not wired in the spike)")
    }

    /// Re-reads availability (it can change when the network or Apple Intelligence state changes).
    func refreshAvailability() {
        guard #available(iOS 27, *) else { return }
        let model = PrivateCloudComputeLanguageModel()
        if case .available = model.availability {
            isAvailable = true
        } else {
            isAvailable = false
        }
        availabilityText = "PCC: \(Self.describe(model.availability))"
    }

    // MARK: Request counting

    /// Called by `respond(...)` right before every PCC call.
    func noteRequest(label: String) {
        requestsThisLaunch += 1
        lastRequestLabel = label
        print("PCC: request #\(requestsThisLaunch): \(label)")
    }

    /// `quotaUsage` right now as one line, or the "requires iOS 27" text.
    func quotaLine() -> String {
        guard #available(iOS 27, *) else { return "PCC: requires iOS 27" }
        return Self.describe(PrivateCloudComputeLanguageModel().quotaUsage)
    }

    // MARK: Describers (every enum case spelled out by name)

    @available(iOS 27, *)
    static func describe(_ availability: PrivateCloudComputeLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "available"
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible:
                return "unavailable(deviceNotEligible)"
            case .systemNotReady:
                return "unavailable(systemNotReady)"
            @unknown default:
                return "unavailable(unknown case: \(String(describing: reason)))"
            }
        }
    }

    @available(iOS 27, *)
    static func describe(_ usage: PrivateCloudComputeLanguageModel.QuotaUsage) -> String {
        var parts: [String] = []
        switch usage.status {
        case let .belowLimit(info):
            parts.append("status=belowLimit(isApproachingLimit: \(info.isApproachingLimit))")
        case .limitReached:
            parts.append("status=limitReached")
        @unknown default:
            parts.append("status=unknown case: \(String(describing: usage.status))")
        }
        parts.append("isLimitReached=\(usage.isLimitReached)")
        if let resetDate = usage.resetDate {
            parts.append("resetDate=\(resetDate.formatted(date: .abbreviated, time: .shortened))")
        } else {
            parts.append("resetDate=nil")
        }
        parts.append("limitIncreaseSuggestion=\(usage.limitIncreaseSuggestion == nil ? "nil" : "present")")
        return parts.joined(separator: ", ")
    }

    /// Names PCC and iOS 27 `LanguageModelError` cases; anything else keeps the old
    /// `String(describing:)` text so the on-device log lines read as before.
    nonisolated static func describe(_ error: any Error) -> String {
        if #available(iOS 27, *) {
            if let pccError = error as? PrivateCloudComputeLanguageModel.Error {
                switch pccError {
                case let .networkFailure(info):
                    return "PCC Error.networkFailure: \(info.debugDescription)"
                case let .quotaLimitReached(info):
                    let reset = info.resetDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "nil"
                    let suggestion = info.limitIncreaseSuggestion == nil ? "nil" : "present"
                    return "PCC Error.quotaLimitReached: \(info.debugDescription) (resetDate=\(reset), limitIncreaseSuggestion=\(suggestion))"
                case let .serviceUnavailable(info):
                    return "PCC Error.serviceUnavailable: \(info.debugDescription)"
                @unknown default:
                    return "PCC Error, unknown case: \(String(describing: pccError))"
                }
            }
            if let systemError = error as? SystemLanguageModel.Error {
                // The iOS 27 on-device error type. The iOS 27.0 simulator throws this from a PCC
                // session too ("Host is not running macOS 27.").
                switch systemError {
                case let .assetsUnavailable(info):
                    return "SystemLanguageModel.Error.assetsUnavailable: \(info.debugDescription)"
                @unknown default:
                    return "SystemLanguageModel.Error, unknown case: \(String(describing: systemError))"
                }
            }
            if let modelError = error as? LanguageModelError {
                switch modelError {
                case let .contextSizeExceeded(info):
                    return "LanguageModelError.contextSizeExceeded (contextSize=\(info.contextSize), tokenCount=\(info.tokenCount)): \(info.debugDescription)"
                case let .rateLimited(info):
                    let reset = info.resetDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "nil"
                    return "LanguageModelError.rateLimited (resetDate=\(reset)): \(info.debugDescription)"
                case let .guardrailViolation(info):
                    return "LanguageModelError.guardrailViolation: \(info.debugDescription)"
                case let .refusal(info):
                    return "LanguageModelError.refusal: \(info.debugDescription)"
                case let .unsupportedCapability(info):
                    return "LanguageModelError.unsupportedCapability: \(info.debugDescription)"
                case let .unsupportedTranscriptContent(info):
                    return "LanguageModelError.unsupportedTranscriptContent: \(info.debugDescription)"
                case let .unsupportedGenerationGuide(info):
                    return "LanguageModelError.unsupportedGenerationGuide (schema=\(info.schemaName ?? "nil")): \(info.debugDescription)"
                case let .unsupportedLanguageOrLocale(info):
                    return "LanguageModelError.unsupportedLanguageOrLocale (\(info.languageCode.identifier)): \(info.debugDescription)"
                case let .timeout(info):
                    return "LanguageModelError.timeout: \(info.debugDescription)"
                @unknown default:
                    return "LanguageModelError, unknown case: \(String(describing: modelError))"
                }
            }
        }
        if let urlError = error as? URLError {
            return "URLError(\(urlError.code.rawValue)): \(urlError.localizedDescription)"
        }
        if error is LanguageModelSession.GenerationError {
            // On-device iOS 26 error type; keep its text exactly as before.
            return String(describing: error)
        }
        // Anything else: say what type it is, so an unexpected error (e.g. the simulator's
        // "Host is not running macOS 27.") can be identified from the log.
        let nsError = error as NSError
        return "\(type(of: error)) [\(nsError.domain) \(nsError.code)]: \(String(describing: error))"
    }

    private func log(_ line: String) {
        launchLines.append(line)
        print(line)
    }
}
