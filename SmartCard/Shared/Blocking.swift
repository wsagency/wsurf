import Foundation

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    // Written once by the task before `done` is signalled; read once after `done.wait()`.
    let done = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
}

/// Runs async card I/O to completion from a synchronous framework callback (PKCS#11 entry points,
/// TKTokenSessionDelegate). Callers are host/XPC threads, never the Swift cooperative pool.
func blocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    Task.detached {
        do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
        box.done.signal()
    }
    box.done.wait()
    return try box.result!.get()
}
