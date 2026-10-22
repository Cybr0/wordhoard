import Foundation
import Synchronization

/// Runs `operation` and returns its result, or `nil` once `limit` has passed, whichever comes first.
/// Unlike a task group, this never waits for an `operation` that ignores cancellation: on timeout the
/// operation is cancelled and left to finish on its own, and its late result is dropped. Used for the
/// onboarding language query (plan 5.2), so the sheet never waits longer than the limit.
public func withTimeLimit<Value: Sendable>(
    _ limit: Duration,
    operation: @escaping @Sendable () async -> Value?
) async -> Value? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
        let once = ResumeOnce(continuation)
        let work = Task {
            await operation()
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else {
                return
            }
            work.cancel()
            once.resume(nil)
        }
        Task {
            let value = await work.value
            timer.cancel()
            once.resume(value)
        }
    }
}

/// Resumes a continuation at most once; later calls do nothing.
private final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value?, Never>?>

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: Value?) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: value)
    }
}
