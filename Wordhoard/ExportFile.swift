import CoreTransferable
import OSLog
import UniformTypeIdentifiers
import WordhoardCore

/// The share-sheet item for "Export…" (S3): a JSON file named `Wordhoard-YYYY-MM-DD.json`, produced on
/// demand when the sheet asks for it, so opening the menu costs nothing.
///
/// `Transferable` requires `Sendable`, and the store is main-actor bound, so the item carries a
/// `@MainActor` closure rather than the store itself; the exporter runs on the main actor when the sheet
/// pulls the file. An export error is logged and rethrown: the only possible failure is the SwiftData
/// fetch the list already reports as "Couldn't load your words", so there is no second alert.
struct ExportFile: Transferable {
    let fileName: String
    let makeData: @MainActor () throws -> Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let data: Data
            do {
                data = try await file.makeData()
            } catch {
                Logger(subsystem: "Wordhoard", category: "transfer")
                    .error("Export failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
            let url = URL.temporaryDirectory.appending(path: file.fileName)
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

extension Bundle {
    /// `CFBundleShortVersionString (CFBundleVersion)`, e.g. `0.1.0 (1)`; written to the export file as
    /// `appVersion`, which the importer ignores.
    var wordhoardVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
