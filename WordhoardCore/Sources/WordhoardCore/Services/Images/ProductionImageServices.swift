import Foundation

/// The production picture services, built here so the app target never names Image Playground (plan
/// 4.4's boundary): `ImagePlaygroundGenerator` where the framework exists, otherwise a generator that is
/// always unavailable, and the on-device prompt writer.
public enum ProductionImageServices {
    public static func generator() -> any ImageGenerator {
        #if canImport(ImagePlayground)
            ImagePlaygroundGenerator()
        #else
            StubImageGenerator(availability: .unavailable)
        #endif
    }

    public static func promptWriter() -> any ImagePromptWriter {
        FoundationModelsImagePromptWriter()
    }
}
