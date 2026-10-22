import Foundation
import Testing
import WordhoardCore

/// The picture path's contract (plan 4.2, #47) with the stubs and the 4.4 queue, and the prompt text.
@MainActor
@Suite("Picture prompt and generator contract")
struct ImagePromptTests {
    @Test("an unavailable model marks the word unavailable without generating")
    func unavailableModelMarksTheWordUnavailableWithoutGenerating() async throws {
        let fixture = try ImageQueueFixture(writer: StubImagePromptWriter(availability: .unavailable))
        let word = try fixture.add("apple")
        await fixture.queue.drain()
        #expect(word.imageStatus == .unavailable)
        #expect(fixture.writer.calls.isEmpty)
        #expect(fixture.generator.prompts.isEmpty)
    }

    @Test("no suitable image skips generation")
    func noSuitableImageSkipsGeneration() async throws {
        let fixture = try ImageQueueFixture(writer: StubImagePromptWriter(result: .success(nil)))
        let word = try fixture.add("however")
        await fixture.queue.drain()
        #expect(word.imageStatus == .skipped)
        #expect(word.image == nil)
        #expect(fixture.generator.prompts.isEmpty)
    }

    @Test("a blank prompt counts as no suitable image")
    func aBlankPromptIsSkipped() async throws {
        let fixture = try ImageQueueFixture(writer: StubImagePromptWriter(result: .success("  ")))
        let word = try fixture.add("despite")
        await fixture.queue.drain()
        #expect(word.imageStatus == .skipped)
        #expect(fixture.generator.prompts.isEmpty)
    }

    @Test("a refused prompt or image leaves the card without an image")
    func aRefusedPromptOrImageLeavesTheCardWithoutAnImage() async throws {
        let prompt = try ImageQueueFixture(writer: StubImagePromptWriter(result: .failure(.refused)))
        let image = try ImageQueueFixture(generator: StubImageGenerator(outcome: .refused))
        for fixture in [prompt, image] {
            let word = try fixture.add("run")
            await fixture.queue.drain()
            #expect(word.imageStatus == .refused)
            #expect(word.image == nil)
            #expect(try fixture.assetCount() == 0)
            #expect(fixture.directory.allFiles.isEmpty)
        }
    }

    @Test("a failed generation leaves no file and no alert")
    func aFailedGenerationLeavesNoFileAndNoAlert() async throws {
        let fixture = try ImageQueueFixture(generator: StubImageGenerator(outcome: .failed))
        let word = try fixture.add("apple")
        let card = fixture.cardModel(word)
        await fixture.queue.drain()
        #expect(word.imageStatus == .failed)
        #expect(try fixture.assetCount() == 0)
        #expect(fixture.directory.allFiles.isEmpty)
        #expect(card.failure == nil)
    }

    @Test("an unavailable generator marks the word unavailable")
    func unavailableGeneratorMarksTheWordUnavailable() async throws {
        let fixture = try ImageQueueFixture(generator: StubImageGenerator(availability: .unavailable))
        let word = try fixture.add("apple")
        await fixture.queue.drain()
        #expect(word.imageStatus == .unavailable)
        #expect(fixture.writer.calls.isEmpty, "both availabilities are checked before any model call")
    }

    @Test("picture work never touches the rest of the card")
    func pictureWorkNeverTouchesTheRestOfTheCard() async throws {
        let fixture = try ImageQueueFixture(
            writer: StubImagePromptWriter(result: .failure(.failed), delay: .seconds(2))
        )
        let clock = ContinuousClock()
        var word: Word?
        let elapsed = try clock.measure {
            word = try fixture.add("apple")
        }
        let added = try #require(word)
        #expect(elapsed < .milliseconds(500), "the add does not wait for the picture")
        try fixture.store.transaction { _ in
            added.senses = [Sense(partOfSpeech: .noun, definition: "a round fruit", order: 0)]
        }
        let card = fixture.cardModel(added)
        let updatedAt = added.updatedAt
        fixture.queue.cancel(added.id)
        await fixture.queue.drain()
        #expect(added.sortedSenses.map(\.definition) == ["a round fruit"])
        #expect(added.headword == "apple")
        #expect(added.updatedAt == updatedAt)
        #expect(card.failure == nil)
    }

    @Test("generated assets carry their prompt")
    func generatedAssetsCarryTheirPrompt() async throws {
        let fixture = try ImageQueueFixture(writer: StubImagePromptWriter(result: .success("a red apple on a table")))
        let word = try fixture.add("apple")
        await fixture.queue.drain()
        #expect(word.image?.prompt == "a red apple on a table")
        #expect(word.image?.source == .generated)
    }

    @Test("the picture prompt names the word and the meaning")
    func thePromptNamesTheWordAndTheMeaning() {
        let prompt = ImagePrompt.prompt(headword: "apple", definition: "a round fruit")
        #expect(prompt.contains("\"apple\""))
        #expect(prompt.contains("a round fruit"))
        #expect(!ImagePrompt.prompt(headword: "apple", definition: nil).contains("Meaning"))
        #expect(ImagePrompt.instructions.contains("drawable to false"))
    }

    @Test("a reply without a drawable picture is no prompt")
    func replyMapping() {
        #expect(ImagePrompt.result(prompt: " a red apple ", drawable: true) == "a red apple")
        #expect(ImagePrompt.result(prompt: "a red apple", drawable: false) == nil)
        #expect(ImagePrompt.result(prompt: "   ", drawable: true) == nil)
    }
}
