import Foundation
import OpenTelemetryApi

/// One client span per HTTP request, for any native HTTP stack: the app's
/// own API client, Alamofire, a delegate-based `URLSession`. Instrument the
/// single place where the app sends requests:
///
/// ```swift
/// let call = HTTPClientSpan.start(urlRequest)
/// sessionManager.request(call.request).validate().responseData { response in
///   call.finish(response: response.response, error: response.error) {
///     completion(response)   // runs with the requester's span current
///   }
/// }
/// ```
///
/// Same rules as Dart (`OtelHttpClient`): only method, host, port, scheme
/// and path are recorded; custom methods become `_OTHER`; `error.type` is
/// the status code (4xx/5xx) or the error type. No swizzling: only requests
/// that go through here are traced.
public enum HTTPClientSpan {
  /// Hosts that receive `traceparent`. Empty means all. Set it so trace ids
  /// are not sent to third parties.
  public static var propagateTo: Set<String> = []

  /// Starts the span and returns the call: send `call.request` (it carries
  /// `traceparent`) and call `finish` once when the response or error
  /// arrives.
  ///
  /// The parent is `parent`, else the current span (`TraceContext.current`:
  /// a traced channel handler, `task`, `bind`), else none.
  public static func start(_ request: URLRequest, parent: SpanContext? = nil) -> HTTPClientCall {
    let caller = TraceContext.current
    let method = HTTPSemantics.method(request.httpMethod)
    let url = request.url
    let builder = OtelFlutterBridge.shared.tracer()
      .spanBuilder(spanName: HTTPSemantics.spanName(forMethod: method))
      .setSpanKind(spanKind: .client)
      .setAttribute(key: "http.request.method", value: method)
      .setAttribute(key: "url.path", value: HTTPSemantics.path(of: url))
    if let parent {
      builder.setParent(parent)
    } else if let caller {
      builder.setParent(caller)
    }
    if let host = url?.host { builder.setAttribute(key: "server.address", value: host) }
    if let port = url?.port { builder.setAttribute(key: "server.port", value: port) }
    if let scheme = url?.scheme { builder.setAttribute(key: "url.scheme", value: scheme) }
    let span = builder.startSpan()

    var traced = request
    if propagateTo.isEmpty || propagateTo.contains(url?.host ?? "") {
      let ctx = span.context
      traced.setValue(TraceparentCodec.format(traceId: ctx.traceId.hexString,
                                              spanId: ctx.spanId.hexString,
                                              sampled: ctx.traceFlags.sampled),
                      forHTTPHeaderField: TraceparentCodec.header)
    }
    return HTTPClientCall(span: span, request: traced, caller: caller)
  }
}

/// A request in flight. See `HTTPClientSpan.start`.
public final class HTTPClientCall {
  /// The client span.
  public let span: Span
  /// The request to send, with `traceparent`.
  public let request: URLRequest

  private let caller: Span?
  private let ended = OnceFlag()

  init(span: Span, request: URLRequest, caller: Span?) {
    self.span = span
    self.request = request
    self.caller = caller
  }

  /// Records the outcome and ends the span. Call it on every path: success,
  /// error and cancellation. Later calls are ignored.
  public func finish(response: URLResponse?, error: Error?) {
    guard ended.claim() else { return }
    let status = (response as? HTTPURLResponse)?.statusCode
    if let status { span.setAttribute(key: "http.response.status_code", value: status) }
    if let type = HTTPSemantics.errorType(statusCode: status, error: error) {
      span.setAttribute(key: "error.type", value: type)
      span.status = .error(description: type)
    }
    span.end()
  }

  /// Ends the span, then runs `continuation` with the requester's span
  /// current (or this request's span when nobody asked, e.g. a timer), so
  /// what the response triggers (state updates, stored callbacks,
  /// notifications, calls to Flutter) stays in the same trace.
  public func finish<T>(response: URLResponse?, error: Error?,
                        then continuation: () throws -> T) rethrows -> T {
    finish(response: response, error: error)
    return try TraceContext.with(caller ?? span, continuation)
  }
}
