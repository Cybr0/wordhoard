import Testing
import WordhoardCore

@Test("the core package reports a semantic version")
func corePackageReportsASemanticVersion() {
    let parts = CoreInfo.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}
