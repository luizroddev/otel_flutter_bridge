import Foundation

/// Attribute keys shared with Dart (`lib/src/semantics.dart`).
public enum AppContextKeys {
  public static let screen = "app.screen"
  public static let flow = "app.flow"
}

/// The screen and flow a span was started in.
public struct AppContextValues: Equatable {
  public var screen: String?
  public var flow: String?

  public init(screen: String? = nil, flow: String? = nil) {
    self.screen = screen
    self.flow = flow
  }
}

/// Where the user is in the host app (screen, flow), and what each recent
/// span was stamped with, so its children copy it and one trace never mixes
/// screens. Thread-safe and bounded: the oldest span entries are dropped
/// after `capacity`, and a child whose parent was dropped takes the current
/// values.
///
/// Values must be fixed names such as `Statement.list`, never text with ids.
public final class AppContextStore: @unchecked Sendable {
  private let lock = NSLock()
  private var current = AppContextValues()
  private var bySpan: [String: AppContextValues] = [:]
  private var order: [String] = []

  public let capacity: Int

  public init(capacity: Int = 1024) {
    self.capacity = max(1, capacity)
  }

  /// The current screen. Set it when a native screen appears.
  public var screen: String? {
    get { lock.locked { current.screen } }
    set { lock.locked { current.screen = newValue } }
  }

  /// The current flow (a journey across screens). Set it when the journey
  /// starts and clear it when it ends.
  public var flow: String? {
    get { lock.locked { current.flow } }
    set { lock.locked { current.flow = newValue } }
  }

  public func clear() {
    lock.locked {
      current = AppContextValues()
      bySpan.removeAll()
      order.removeAll()
    }
  }

  /// What the span with `spanId` was stamped with, if still known.
  public func values(forSpanId spanId: String) -> AppContextValues? {
    lock.locked { bySpan[spanId] }
  }

  /// Values for a new span: its local parent's, or the current ones.
  public func valuesForNewSpan(parentSpanId: String?) -> AppContextValues {
    lock.locked {
      if let parentSpanId, let parent = bySpan[parentSpanId] { return parent }
      return current
    }
  }

  /// Remembers what the span with `spanId` was stamped with.
  public func register(_ values: AppContextValues, forSpanId spanId: String) {
    lock.locked {
      if bySpan.updateValue(values, forKey: spanId) == nil { order.append(spanId) }
      while order.count > capacity {
        bySpan.removeValue(forKey: order.removeFirst())
      }
    }
  }
}

private extension NSLock {
  func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
