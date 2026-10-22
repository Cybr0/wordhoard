import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// A deterministic `ImageGenerator` for tests and the `--stub-images` debug hook (plan 4.1): a 64 × 64
/// solid-colour PNG, a refusal, a background refusal or a failure, after an optional delay. Records
/// every prompt it was asked for; an unavailable stub throws `.unavailable` without recording or
/// consulting `outcome`.
public final class StubImageGenerator: ImageGenerator {
    public enum Outcome: Sendable, Equatable {
        case image
        case refused
        case backgroundForbidden
        case failed
    }

    private let configuredAvailability: ImageGeneratorAvailability
    private let outcome: Outcome
    private let delay: Duration
    private let state = Mutex(State())

    private struct State {
        var prompts: [String] = []
        var running = 0
        var maxConcurrent = 0
    }

    public init(
        availability: ImageGeneratorAvailability = .available,
        outcome: Outcome = .image,
        delay: Duration = .zero
    ) {
        configuredAvailability = availability
        self.outcome = outcome
        self.delay = delay
    }

    /// Every prompt `generate` received, in call order.
    public var prompts: [String] {
        state.withLock { $0.prompts }
    }

    /// The most `generate` calls that were running at once; `1` for a serial caller.
    public var maxConcurrentCalls: Int {
        state.withLock { $0.maxConcurrent }
    }

    public var availability: ImageGeneratorAvailability {
        get async { configuredAvailability }
    }

    public func generate(prompt: String) async throws -> ImageResult {
        guard configuredAvailability == .available else {
            throw ImageGeneratorError.unavailable
        }
        state.withLock {
            $0.prompts.append(prompt)
            $0.running += 1
            $0.maxConcurrent = max($0.maxConcurrent, $0.running)
        }
        defer {
            state.withLock { $0.running -= 1 }
        }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        switch outcome {
        case .image:
            return try ImageResult(data: Self.solidPNG(), style: nil)
        case .refused:
            throw ImageGeneratorError.refused
        case .backgroundForbidden:
            throw ImageGeneratorError.backgroundForbidden
        case .failed:
            throw ImageGeneratorError.failed
        }
    }

    /// A 64 × 64 opaque PNG in one colour.
    public static func solidPNG(red: CGFloat = 0.12, green: CGFloat = 0.44, blue: CGFloat = 0.37) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: 64,
                  height: 64,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else {
            throw ImageGeneratorError.failed
        }
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else {
            throw ImageGeneratorError.failed
        }
        return try png(image)
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageGeneratorError.failed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageGeneratorError.failed
        }
        return data as Data
    }
}
