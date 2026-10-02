import Foundation

/// WebKit callbacks may never arrive after its content process exits. A task-group
/// timeout around WebKit's async API would still wait for that suspended child.
/// This bridge resumes exactly once on completion, timeout, or user cancellation.
@MainActor
final class WebCaptureRequest<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutTask: Task<Void, Never>?

    func run(timeout: Duration, operation: (@escaping @MainActor @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                        self?.finish(.failure(WebCaptureError.operationTimedOut))
                    } catch { }
                }
                operation { [weak self] result in self?.finish(result) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}
