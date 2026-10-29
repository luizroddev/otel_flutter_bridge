import Foundation

/// Holds native journey events until Dart is ready, then hands them to
/// [sink] in batches. Same rules as `PendingSpanQueue`: bounded (the oldest
/// events are dropped first), thread-safe, never throws.
public final class PendingEventQueue: @unchecked Sendable {
  public typealias Sink = (_ batch: [String: Any]) -> Void

  private let lock = NSLock()
  private var pending: [BridgeLogRecord] = []
  private var ready = false
  private var enabled = true
  private var maxBatchSize: Int
  private var sink: Sink?

  /// Maximum events kept while Dart is not ready.
  public let capacity: Int

  /// Events dropped because the queue was full or recording was disabled.
  public private(set) var droppedCount = 0

  public init(capacity: Int = 512, maxBatchSize: Int = 64) {
    self.capacity = max(1, capacity)
    self.maxBatchSize = max(1, maxBatchSize)
  }

  /// Number of events waiting.
  public var count: Int { lock.locked { pending.count } }

  /// Whether Dart signalled it is ready.
  public var isReady: Bool { lock.locked { ready } }

  /// Whether events are accepted.
  public var isEnabled: Bool { lock.locked { enabled } }

  /// Sets where batches go. Does not mark the queue ready.
  public func setSink(_ sink: Sink?) {
    lock.locked { self.sink = sink }
  }

  /// Called when Dart is ready. Flushes everything queued so far.
  public func markReady(enabled: Bool, maxBatchSize: Int) {
    lock.locked {
      ready = true
      self.enabled = enabled
      self.maxBatchSize = max(1, maxBatchSize)
      if !enabled { pending.removeAll() }
    }
    flush()
  }

  /// Turns recording on or off. Turning it off discards what is pending.
  public func setEnabled(_ value: Bool) {
    lock.locked {
      enabled = value
      if !value {
        droppedCount += pending.count
        pending.removeAll()
      }
    }
  }

  /// Adds events. Sends right away when Dart is ready.
  public func enqueue(_ records: [BridgeLogRecord]) {
    guard !records.isEmpty else { return }
    lock.locked {
      guard enabled else {
        droppedCount += records.count
        return
      }
      pending.append(contentsOf: records)
      let overflow = pending.count - capacity
      if overflow > 0 {
        pending.removeFirst(overflow)
        droppedCount += overflow
      }
    }
    flush()
  }

  /// Sends everything pending, if Dart is ready and a sink is set.
  public func flush() {
    let (batches, sink): ([[String: Any]], Sink?) = lock.locked {
      guard ready, enabled, let sink = self.sink, !pending.isEmpty else { return ([], nil) }
      let batches = BridgeLogBatchEncoder.encode(pending, maxBatchSize: maxBatchSize)
      pending.removeAll()
      return (batches, sink)
    }
    guard let sink else { return }
    batches.forEach(sink)
  }
}

private extension NSLock {
  func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
