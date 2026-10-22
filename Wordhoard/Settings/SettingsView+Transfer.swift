import OSLog
import SwiftUI
import WordhoardCore

// MARK: - Export and import (S3, 1.7)

/// The 1.7 mechanics, moved from the list's "More" menu (#36): the share sheet with
/// `Wordhoard-YYYY-MM-DD.json` and the file picker, or the `--ui-testing-export-path` /
/// `--ui-testing-import-path` hooks instead of the two system sheets.
extension SettingsView {
    /// The share sheet in production; under the UI-test hook, a plain button that writes the file to the
    /// given path so the test can read it.
    @ViewBuilder var exportRow: some View {
        if let path = hooks.exportPath {
            Button("Export…", systemImage: "square.and.arrow.up") {
                exportToFile(atPath: path)
            }
            .accessibilityIdentifier("settings.export")
        } else {
            let fileName = Exporter.fileName()
            ShareLink(
                item: ExportFile(fileName: fileName, makeData: exportData),
                preview: SharePreview(fileName)
            ) {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("settings.export")
        }
    }

    func exportData() throws -> Data {
        try model.exportData(appVersion: Bundle.main.wordhoardVersion)
    }

    func exportToFile(atPath path: String) {
        do {
            try exportData().write(to: URL(filePath: path), options: .atomic)
        } catch {
            logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func startImport() {
        if let path = hooks.importPath {
            importFile(at: URL(filePath: path), isSecurityScoped: false)
        } else {
            isImporterPresented = true
        }
    }

    func importPicked(_ result: Result<URL, any Error>) {
        switch result {
        case let .success(url):
            importFile(at: url, isSecurityScoped: true)
        case let .failure(error):
            logger.error("File picker failed: \(error.localizedDescription, privacy: .public)")
            isReadFailurePresented = true
        }
    }

    /// Reads the file into memory inside its security scope and hands the bytes to the model; the list
    /// re-reads when the sheet closes. A read failure is the view's alert; nothing reaches Core.
    func importFile(at url: URL, isSecurityScoped: Bool) {
        let accessing = isSecurityScoped && url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try coordinatedRead(url)
            model.importWords(data)
        } catch {
            logger.error("Could not read the picked file: \(error.localizedDescription, privacy: .public)")
            isReadFailurePresented = true
        }
    }

    /// Reads through a file coordinator so an iCloud Drive placeholder that is not downloaded yet is
    /// fetched first instead of failing with a generic read error.
    func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var read: Result<Data, any Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, error: &coordinationError) { readURL in
            read = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError {
            throw coordinationError
        }
        return try read.get()
    }

    /// Word counts only; senses, examples and tags are detail the alert does not need.
    func importMessage(_ counts: ImportSummary) -> Text {
        Text("Added \(counts.wordsCreated), updated \(counts.wordsUpdated), skipped \(counts.wordsSkipped).")
    }

    var isImportSummaryPresented: Binding<Bool> {
        Binding(
            get: { model.importSummary != nil },
            set: { isPresented in
                if !isPresented {
                    model.importSummary = nil
                }
            }
        )
    }
}
