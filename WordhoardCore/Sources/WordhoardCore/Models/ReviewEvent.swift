import Foundation
import SwiftData

/// One spaced-repetition review, append-only (requirements §5, post-v1).
///
/// In the schema from day one so review (v2) adds code, not a migration. Nothing in v1 writes it.
/// `senseID` is a plain id rather than a relationship so the log survives sense deletion.
@Model
public final class ReviewEvent {
    public var id: UUID = UUID()
    public var senseID: UUID = UUID()
    public var reviewedAt: Date = Date.now
    /// FSRS rating: 1 again, 2 hard, 3 good, 4 easy. Not validated here.
    public var rating: Int = 0
    public var direction: ReviewDirection = ReviewDirection.wordToMeaning

    public init(senseID: UUID, rating: Int, direction: ReviewDirection, reviewedAt: Date = .now) {
        self.senseID = senseID
        self.rating = rating
        self.direction = direction
        self.reviewedAt = reviewedAt
    }
}
