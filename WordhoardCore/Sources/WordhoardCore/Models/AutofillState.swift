/// Where a `Word` is in the autofill pipeline (requirements C5, A6, §5; plan 2.3).
///
/// Written by `AutofillService` only. `filling` is persisted before the generator is called and `ready`
/// in the same commit as the generated senses, so a stored word is either untouched or complete; a
/// `filling` word found at launch is re-queued. Not exported: the importer derives `ready` / `pending`
/// from the senses. The raw value is the case name; cases are never renamed.
public enum AutofillState: String, Codable, Sendable, CaseIterable {
    /// Queued or not yet picked up. The default for every new word, whoever created it.
    case pending
    /// A generation call is in flight.
    case filling
    /// The first card has been merged; topic examples may still be arriving.
    case ready
    /// The generator threw `.refused` or `.failed`; the reason lives on the service for this session.
    case failed
    /// The generator threw `.unavailable`: the device cannot fill the card right now.
    case unavailable
}
