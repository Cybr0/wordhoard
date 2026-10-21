import Foundation
import SwiftData

/// Builds the app's `ModelContainer`. The `Schema` here is the only place the model list lives.
///
/// CloudKit is deliberately off (`cloudKitDatabase: .none`); the schema is kept sync-compatible so it
/// can be switched on later (plan v2) without a migration.
public enum WordhoardContainer {
    /// Every persisted model type. `ReviewEvent` is included although nothing writes it in v1.
    public static var schema: Schema {
        Schema([
            Word.self,
            Sense.self,
            Example.self,
            Tag.self,
            ImageAsset.self,
            ReviewEvent.self,
            UserSettings.self,
        ])
    }

    /// File name of the on-disk store inside Application Support.
    public static let storeFileName = "Wordhoard.store"

    /// An isolated in-memory container for tests and previews. Each call returns a separate store.
    public static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "Wordhoard-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// An on-disk container. `nil` opens the store file in the app's Application Support directory,
    /// creating the directory if needed.
    public static func makeOnDisk(url: URL? = nil) throws -> ModelContainer {
        let storeURL = try url ?? defaultStoreURL()
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func defaultStoreURL() throws -> URL {
        let directory = URL.applicationSupportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: storeFileName)
    }
}
