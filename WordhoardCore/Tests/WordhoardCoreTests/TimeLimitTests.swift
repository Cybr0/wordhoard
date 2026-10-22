import Foundation
import Testing
import WordhoardCore

/// `withTimeLimit` (plan 5.2, PR #63 review should-fix 2): the onboarding language query is bounded
/// even when the framework call ignores cancellation, so Continue can never stay disabled.
@Suite("withTimeLimit")
struct TimeLimitTests {
    @Test("an operation that ignores cancellation and never finishes gives nil once the limit passes")
    func aStuckOperationGivesNil() async {
        let gate = Gate()
        let result = await withTimeLimit(.milliseconds(50)) { () async -> Set<String>? in
            // Awaiting an unstructured task's value ignores the caller's cancellation, like a slow
            // framework query would.
            await Task {
                try? await gate.wait()
                return Set(["fr"])
            }.value
        }
        #expect(result == nil)
        gate.open()
    }

    @Test("an operation that finishes in time gives its result")
    func aFastOperationGivesItsResult() async {
        let result = await withTimeLimit(.seconds(60)) { () async -> Set<String>? in
            ["fr", "uz"]
        }
        #expect(result == ["fr", "uz"])
    }

    @Test("an operation that finishes in time with nil gives nil")
    func aFastNilGivesNil() async {
        let result = await withTimeLimit(.seconds(60)) { () async -> Set<String>? in
            nil
        }
        #expect(result == nil)
    }
}
