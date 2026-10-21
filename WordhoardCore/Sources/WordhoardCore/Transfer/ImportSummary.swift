/// What an import did. Counts are of rows, not of fields; a value that already matched writes nothing
/// and counts nothing, so importing a file twice yields `.nothing`.
///
/// A word is *updated* when any of its own fields, its tag set, or anything under it changed; a revived
/// tombstone counts as *created*; a word left out because its headword was blank or would collide with
/// another word counts as *skipped*.
public struct ImportSummary: Equatable, Sendable {
    public var wordsCreated: Int
    public var wordsUpdated: Int
    public var wordsSkipped: Int
    public var sensesCreated: Int
    public var sensesUpdated: Int
    public var examplesCreated: Int
    public var examplesUpdated: Int
    public var tagsCreated: Int
    public var tagsUpdated: Int
    public var settingsChanged: Bool

    /// All zero and `false`: the store already matched the file.
    public static let nothing = ImportSummary()

    public init(
        wordsCreated: Int = 0,
        wordsUpdated: Int = 0,
        wordsSkipped: Int = 0,
        sensesCreated: Int = 0,
        sensesUpdated: Int = 0,
        examplesCreated: Int = 0,
        examplesUpdated: Int = 0,
        tagsCreated: Int = 0,
        tagsUpdated: Int = 0,
        settingsChanged: Bool = false
    ) {
        self.wordsCreated = wordsCreated
        self.wordsUpdated = wordsUpdated
        self.wordsSkipped = wordsSkipped
        self.sensesCreated = sensesCreated
        self.sensesUpdated = sensesUpdated
        self.examplesCreated = examplesCreated
        self.examplesUpdated = examplesUpdated
        self.tagsCreated = tagsCreated
        self.tagsUpdated = tagsUpdated
        self.settingsChanged = settingsChanged
    }
}
