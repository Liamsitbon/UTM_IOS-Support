import Foundation

// NSLock keeps the storage exclusion layer available on UTM's oldest hosts.
final class UTMPortableLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State
    init(initialState: State) { state = initialState }
    func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
