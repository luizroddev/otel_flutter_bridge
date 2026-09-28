import Foundation

/// Holds native spans until Dart is ready, then hands them to [sink] in
/// batches. See `docs/specs/native-bridge.md`.
///
/// Bounded: when full, the oldest spans are dropped first. Thread-safe.
/// Never throws.
public final class PendingSpanQueue: @unchecked Sendable {
  public typealias Sink = (_ batch: [String: Any]) -> Void

  private let lock = NSLock()
  private var pending: [BridgeSpan] = []
  private var ready = false
  private var enabled = true
  private var maxBatchSize: Int
  private var sink: Sink?

  /// Maximum spans kept while Dart is not ready.
  public let capacity: Int
  /// Resource attributes attached to every batch.
  public var resource: [String: BridgeAttributeValue] {
    get { lock.locked { _resource } }
    set { lock.locked { _resource = newValue } }
  }
  private var _resource: [String: BridgeAttributeValue] = [:]

  /// Spans dropped because the queue was full or recording was disabled.
  public private(set) var droppedCount = 0

  public init(capacity: Int = 512, maxBatchSize: Int = 64) {
    self.capacity = max(1, capacity)
    self.maxBatchSize = max(1, maxBatchSize)
  }

  /// Number of spans waiting.
  public var count: Int { lock.locked { pending.count } }

  /// Whether Dart signalled it is ready.
  public var isReady: Bool { lock.locked { ready } }

  /// Whether spans are accepted.
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

  /// Adds finished spans. Sends right away when Dart is ready.
  public func enqueue(_ spans: [BridgeSpan]) {
    guard !spans.isEmpty else { return }
    lock.locked {
      guard enabled else {
        droppedCount += spans.count
        return
      }
      pending.append(contentsOf: spans)
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
      let batches = BridgeBatchEncoder.encode(pending, resource: _resource, maxBatchSize: maxBatchSize)
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
