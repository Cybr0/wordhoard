#if canImport(ImagePlayground)
    import CoreGraphics
    import Foundation
    import ImagePlayground
    import os
    import Synchronization

    /// The production `ImageGenerator` on Image Playground's `ImageCreator` (plan 4.2, I1). Availability is
    /// "an `ImageCreator` can be made", checked on every call and never cached (it changes with Apple
    /// Intelligence); the style is `.illustration` when offered, else the first available one.
    ///
    /// iOS 27 deprecates `ImageCreator` in favour of the interactive `ImagePlaygroundViewController` /
    /// `imagePlaygroundSheet`, which cannot make a picture in the background (I3). The members that touch
    /// it carry the same deprecation, so the warning stays inside this file and callers reach them
    /// through the `ImageGenerator` protocol; the replacement is a decision for ADR 0003 (#47, #5).
    ///
    /// **Isolation: none.** A stateless `Sendable` struct; each call makes its own `ImageCreator`.
    public struct ImagePlaygroundGenerator: ImageGenerator {
        private static let logger = Logger(subsystem: "Wordhoard", category: "images")
        /// The styles line is written once per launch.
        private static let hasLoggedStyles = Mutex(false)

        public init() {}

        @available(iOS, deprecated: 27.0, message: "ImageCreator; see the type comment")
        @available(macOS, deprecated: 27.0, message: "ImageCreator; see the type comment")
        public var availability: ImageGeneratorAvailability {
            get async {
                do {
                    _ = try await ImageCreator()
                    return .available
                } catch {
                    return .unavailable
                }
            }
        }

        @available(iOS, deprecated: 27.0, message: "ImageCreator; see the type comment")
        @available(macOS, deprecated: 27.0, message: "ImageCreator; see the type comment")
        public func generate(prompt: String) async throws -> ImageResult {
            do {
                let creator = try await ImageCreator()
                let styles = creator.availableStyles
                guard let style = styles.contains(.illustration) ? .illustration : styles.first else {
                    throw ImageGeneratorError.unavailable
                }
                if Self.hasLoggedStyles.withLock({ logged in defer { logged = true }; return !logged }) {
                    let all = styles.map(\.id).joined(separator: ", ")
                    Self.logger
                        .info("Image Playground styles: \(all, privacy: .public); using \(style.id, privacy: .public)")
                }
                for try await created in creator.images(for: [.text(prompt)], style: style, limit: 1) {
                    return try ImageResult(data: StubImageGenerator.png(created.cgImage), style: style.id)
                }
                throw ImageGeneratorError.failed
            } catch let error as ImageGeneratorError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ImageCreator.Error {
                throw Self.mapped(error)
            } catch {
                throw Task.isCancelled ? CancellationError() : ImageGeneratorError.failed
            }
        }

        /// Provisional until the #5 device check (ADR 0003): a guardrail refusal that arrives as
        /// `.creationFailed` stays `.failed`, which the card shows the same way (I4).
        @available(iOS, deprecated: 27.0, message: "ImageCreator; see the type comment")
        @available(macOS, deprecated: 27.0, message: "ImageCreator; see the type comment")
        static func mapped(_ error: ImageCreator.Error) -> any Error {
            switch error {
            case .notSupported, .unavailable:
                ImageGeneratorError.unavailable
            case .unsupportedLanguage, .unsupportedInputImage, .faceInImageTooSmall, .conceptsRequirePersonIdentity:
                ImageGeneratorError.refused
            case .backgroundCreationForbidden:
                ImageGeneratorError.backgroundForbidden
            case .creationFailed:
                ImageGeneratorError.failed
            case .creationCancelled:
                CancellationError()
            @unknown default:
                ImageGeneratorError.failed
            }
        }
    }
#endif
