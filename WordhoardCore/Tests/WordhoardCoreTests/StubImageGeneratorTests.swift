import Foundation
import Testing
import WordhoardCore

@Suite("StubImageGenerator")
struct StubImageGeneratorTests {
    @Test("the stub image generator honours its configured outcome")
    func stubImageGeneratorHonoursItsConfiguredOutcome() async throws {
        let directory = TemporaryImageDirectory()
        let image = StubImageGenerator()
        let result = try await image.generate(prompt: "a red apple")
        #expect(image.prompts == ["a red apple"])
        #expect(result.style == nil)
        #expect(try directory.store.write(result.data, id: UUID()).hasSuffix(".jpg"))

        await #expect(throws: ImageGeneratorError.refused) {
            try await StubImageGenerator(outcome: .refused).generate(prompt: "x")
        }
        await #expect(throws: ImageGeneratorError.failed) {
            try await StubImageGenerator(outcome: .failed).generate(prompt: "x")
        }
        let unavailable = StubImageGenerator(availability: .unavailable, outcome: .image)
        #expect(await unavailable.availability == .unavailable)
        await #expect(throws: ImageGeneratorError.unavailable) {
            try await unavailable.generate(prompt: "x")
        }
        #expect(unavailable.prompts.isEmpty)
    }
}
