import Foundation
import SwiftData
import Testing
import WordhoardCore

/// The launch orphan scan's keep-list (plan 4.1, PR #63 review must-fix 1): an in-memory store, such as
/// the fallback after the on-disk store failed to open, knows none of the pictures on disk, so the scan
/// must not run against it.
@MainActor
@Suite("Orphan scan keep-list")
struct OrphanScanKeepListTests {
    @Test("an in-memory store refuses the orphan scan, so no picture on disk is deleted")
    func anInMemoryStoreRefusesTheScan() throws {
        let store = try WordStore(container: WordhoardContainer.makeInMemory())
        #expect(try store.orphanScanKeepList() == nil)
    }

    @Test("an on-disk store gives every picture name as the keep-list")
    func anOnDiskStoreGivesTheKeepList() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wordhoard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WordStore(container: WordhoardContainer.makeOnDisk(url: directory.appending(path: "W.store")))
        let apple = try store.add("apple").word
        try store.setImage(ImageAsset(fileName: "apple.jpg", source: .library), for: apple)
        #expect(try store.orphanScanKeepList() == ["apple.jpg"])
    }
}
