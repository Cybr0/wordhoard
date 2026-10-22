/// Sampling defaults shared by every model call. Changing them is a prompt change: re-run the
/// regression word list (`docs/regression-words.md`) and note the results in the PR.
public enum GenerationDefaults {
    /// Low temperature: dictionary prose should be predictable, not creative. Measured at `665d06d`.
    public static let temperature = 0.3
}
