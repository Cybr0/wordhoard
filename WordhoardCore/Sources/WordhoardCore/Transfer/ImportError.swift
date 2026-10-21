import Foundation

/// Why an import was refused. Every case leaves the store exactly as it was.
///
/// `errorDescription` goes through the app's String Catalog (`Localizable.xcstrings`, looked up in
/// `Bundle.main`); the keys are the English text, so a host without the catalog, such as `swift test`,
/// gets the same words back.
public enum ImportError: Error, Equatable, Sendable, LocalizedError {
    /// Malformed JSON, the wrong shape, a missing or non-integer `schemaVersion`, or one below 1.
    case notAWordhoardExport
    /// `schemaVersion` is above what this build reads.
    case newerSchema(found: Int, supported: Int)
    /// An enum raw value this build does not know; `field` is the JSON key.
    case unknownValue(field: String, value: String)
    /// The same word, sense, example or tag id appears twice in one file.
    case duplicateID(UUID)

    public var errorDescription: String? {
        switch self {
        case .notAWordhoardExport:
            String(localized: "This file isn't a Wordhoard export.", bundle: .main)
        case .newerSchema:
            String(
                localized: "This file was made by a newer version of Wordhoard. Update the app and try again.",
                bundle: .main
            )
        case let .unknownValue(field, value):
            String(
                localized: "This file uses a value this version of Wordhoard doesn't recognize (\(field): \(value)).",
                bundle: .main
            )
        case let .duplicateID(id):
            String(localized: "This file lists the same item twice (\(id.uuidString)).", bundle: .main)
        }
    }
}
