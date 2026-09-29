import Foundation
import OpenTelemetryApi

/// The span native work runs under, across callbacks, `await` and child
/// tasks.
///
/// OpenTelemetry Swift's default context on iOS follows the thread
/// (`os_activity`): it survives synchronous code but not an `await` that
/// resumes on another thread. The bridge also keeps the span in a Swift
/// task-local, which child tasks and `async let` inherit. Its helpers
/// (`traced`, `HTTPClientSpan`, `bind`, `task`, `withTraceContext`) read
/// `current`, so both styles of code are covered.
public enum TraceContext {
  // Span is not Sendable; a task-local needs a Sendable value.
  final class Box: @unchecked Sendable {
    let span: Span
    init(_ span: Span) { self.span = span }
  }

  @TaskLocal static var box: Box?

  /// The current span: the one the bridge bound, else OpenTelemetry's
  /// active span, else nil.
  public static var current: Span? {
    box?.span ?? OpenTelemetry.instance.contextProvider.activeSpan
  }

  /// Runs synchronous `operation` with `span` as the current span (both the
  /// task-local and OpenTelemetry's active span). With nil, just runs it.
  public static func with<T>(_ span: Span?, _ operation: () throws -> T) rethrows -> T {
    guard let span else { return try operation() }
    return try $box.withValue(Box(span), operation: {
      try OpenTelemetry.instance.contextProvider.withActiveSpan(span, operation)
    })
  }

  /// Runs async `operation` with `span` as the current span. Spans started
  /// through the bridge's helpers inside it, and in its child tasks, use it
  /// as parent.
  public static func with<T>(_ span: Span?, _ operation: () async throws -> T) async rethrows -> T {
    guard let span else { return try await operation() }
    return try await $box.withValue(Box(span), operation: operation)
  }
}

public extension OtelFlutterBridge {
  /// Returns `closure` bound to the current span: when it runs later (a
  /// stored completion, a queued callback), it runs with that span current,
  /// so what it does joins the trace of whoever created it.
  ///
  /// ```swift
  /// callbacks.append(OtelFlutterBridge.shared.bind(completion))
  /// ```
  func bind<R>(_ closure: @escaping () -> R) -> () -> R {
    let span = TraceContext.current
    return { TraceContext.with(span) { closure() } }
  }

  func bind<A, R>(_ closure: @escaping (A) -> R) -> (A) -> R {
    let span = TraceContext.current
    return { a in TraceContext.with(span) { closure(a) } }
  }

  func bind<A, B, R>(_ closure: @escaping (A, B) -> R) -> (A, B) -> R {
    let span = TraceContext.current
    return { a, b in TraceContext.with(span) { closure(a, b) } }
  }

  /// `Task { }` that carries the current span into the async code, so
  /// requests made in it (and in its child tasks) join the trace.
  ///
  /// ```swift
  /// OtelFlutterBridge.shared.task {
  ///   result(try? await service.load())
  /// }
  /// ```
  @discardableResult
  func task<T: Sendable>(priority: TaskPriority? = nil,
                         _ operation: @escaping @Sendable () async -> T) -> Task<T, Never> {
    let box = TraceContext.current.map(TraceContext.Box.init)
    return Task(priority: priority) {
      await TraceContext.$box.withValue(box, operation: operation)
    }
  }
}
