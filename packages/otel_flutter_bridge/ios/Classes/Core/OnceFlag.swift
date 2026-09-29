import Foundation

/// True exactly once, from any thread. Used so a span is ended once even if
/// a Flutter `result` is called twice by mistake.
public final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  public init() {}

  /// Returns true the first time, false afterwards.
  public func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if claimed { return false }
    claimed = true
    return true
  }
}
