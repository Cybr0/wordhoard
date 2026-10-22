/// Where a word's generated picture is (plan 4.4, I3–I5). Stored on `Word.imageStatus`; `nil` means
/// nothing was requested (every pre-4.4 word, imported words, and any word whose picture was set or
/// removed by hand). Invariant: a word with a picture has no status. Not exported. The raw value is the
/// case name; cases are never renamed.
public enum ImageStatus: String, Codable, Sendable, CaseIterable {
    /// Queued or running; the card shows the placeholder. Survives a kill and resumes.
    case pending
    /// The prompt writer said there is nothing concrete to draw (I5); remembered, never retried.
    case skipped
    /// The prompt or the picture was refused.
    case refused
    /// Generation failed for another reason.
    case failed
    /// The prompt writer or Image Playground cannot run on this device.
    case unavailable
}
