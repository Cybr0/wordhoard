import Foundation
import SwiftData
import Testing
import WordhoardCore

/// A word added by Siri gets its automatic picture like a typed one (analyst ruling on #49, PR #63
/// review should-fix 1): the intent marks it `.pending` and starts nothing; the next foreground resume
/// runs the job. There is no sweep over words without a status.
@MainActor
@Suite("Automatic picture for a captured word")
struct CapturedWordPictureTests {
    @Test("a created word with the toggle on is marked pending without a job, then gets a picture on resume")
    func aCreatedWordIsMarkedPendingThenDrawn() async throws {
        let fixture = try ImageQueueFixture()
        let result = try fixture.store.add("pear")
        let word = result.word
        let updatedAt = word.updatedAt

        try fixture.store.markForAutomaticPicture(after: result)
        #expect(word.imageStatus == .pending)
        #expect(try fixture.storedWord(word).imageStatus == .pending)
        #expect(word.updatedAt == updatedAt, "the status is bookkeeping, not content")
        await fixture.queue.drain()
        #expect(fixture.writer.calls.isEmpty, "marking starts nothing")

        try fixture.queue.resumePending()
        await fixture.queue.drain()
        #expect(word.image?.source == .generated)
        #expect(word.imageStatus == nil)
    }

    @Test("with the toggle off a created word is left without a status")
    func theToggleOffWritesNothing() throws {
        let fixture = try ImageQueueFixture()
        try fixture.store.updateSettings { $0.autoGenerateImages = false }
        let result = try fixture.store.add("pear")

        try fixture.store.markForAutomaticPicture(after: result)
        #expect(result.word.imageStatus == nil)
        #expect(try fixture.storedWord(result.word).imageStatus == nil)
    }

    @Test("an existing word is left unchanged")
    func anExistingWordIsUnchanged() throws {
        let fixture = try ImageQueueFixture()
        let word = try fixture.store.add("pear").word
        let updatedAt = word.updatedAt
        let result = try fixture.store.add("Pear ")
        #expect(result == .existing(word))

        try fixture.store.markForAutomaticPicture(after: result)
        #expect(word.imageStatus == nil)
        #expect(try fixture.storedWord(word).imageStatus == nil)
        #expect(word.updatedAt == updatedAt)
    }

    @Test("an imported word stays without a status and is never queued")
    func anImportedWordIsNeverQueued() async throws {
        let fixture = try ImageQueueFixture()
        #expect(SettingsModel(store: fixture.store).importWords(GoldenExport.data)?.wordsCreated == 2)
        // The fixture file turns the toggle off; turn it back on so only the missing sweep keeps the
        // imported words without a picture.
        try fixture.store.updateSettings { $0.autoGenerateImages = true }
        try fixture.store.markForAutomaticPicture(after: fixture.store.add("pear"))

        try fixture.queue.resumePending()
        await fixture.queue.drain()
        let words = try fixture.store.words()
        #expect(words.filter { $0.image != nil }.map(\.headword) == ["pear"])
        #expect(words.filter { $0.headword != "pear" }.allSatisfy { $0.imageStatus == nil })
        #expect(fixture.writer.calls.map(\.headword) == ["pear"])
    }
}
