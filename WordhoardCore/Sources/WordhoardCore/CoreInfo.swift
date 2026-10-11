/// Namespace for package-level facts about `WordhoardCore`.
///
/// Models, services and the grammar catalog are added by later plan tasks; this type exists so the
/// app target has something real to import and the package has something real to test. It is not
/// named after the module on purpose: a type called `WordhoardCore` would shadow the module and break
/// `WordhoardCore.SomeType` qualified lookups.
public enum CoreInfo {
    /// Semantic version of the core package.
    public static let version = "0.1.0"
}
