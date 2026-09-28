import Foundation
import OpenTelemetryApi

/// Explicit HTTP instrumentation for native code. Call these instead of
/// `URLSession` directly for requests you want traced. No swizzling: only
/// calls that go through here are traced.
///
/// Only method, host, port, scheme and path are recorded; the path is
/// normalised by the Dart redaction before export.
public enum TracedURLSession {
  /// Hosts that receive `traceparent`. Empty means all. Set it so trace ids
  /// are not sent to third parties.
  public static var propagateTo: Set<String> = []

  @available(iOS 15.0, macOS 12.0, *)
  public static func data(for request: URLRequest, session: URLSession = .shared,
                          parent: SpanContext? = nil) async throws -> (Data, URLResponse) {
    let (span, traced) = start(request, parent: parent)
    do {
      let (data, response) = try await session.data(for: traced)
      finish(span, response: response, error: nil)
      return (data, response)
    } catch {
      finish(span, response: nil, error: error)
      throw error
    }
  }

  @discardableResult
  public static func dataTask(with request: URLRequest, session: URLSession = .shared,
                              parent: SpanContext? = nil,
                              completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
    let (span, traced) = start(request, parent: parent)
    let task = session.dataTask(with: traced) { data, response, error in
      finish(span, response: response, error: error)
      completion(data, response, error)
    }
    task.resume()
    return task
  }

  static func start(_ request: URLRequest, parent: SpanContext?) -> (Span, URLRequest) {
    let method = request.httpMethod ?? "GET"
    let url = request.url
    let builder = OtelFlutterBridge.shared.tracer().spanBuilder(spanName: method)
      .setSpanKind(spanKind: .client)
      .setAttribute(key: "http.request.method", value: method)
    if let parent { builder.setParent(parent) }
    if let host = url?.host { builder.setAttribute(key: "server.address", value: host) }
    if let port = url?.port { builder.setAttribute(key: "server.port", value: port) }
    if let scheme = url?.scheme { builder.setAttribute(key: "url.scheme", value: scheme) }
    builder.setAttribute(key: "url.path", value: url?.path.isEmpty == false ? url!.path : "/")
    let span = builder.startSpan()

    var traced = request
    if propagateTo.isEmpty || propagateTo.contains(url?.host ?? "") {
      let ctx = span.context
      traced.setValue(TraceparentCodec.format(traceId: ctx.traceId.hexString,
                                              spanId: ctx.spanId.hexString,
                                              sampled: ctx.traceFlags.sampled),
                      forHTTPHeaderField: TraceparentCodec.header)
    }
    return (span, traced)
  }

  static func finish(_ span: Span, response: URLResponse?, error: Error?) {
    if let http = response as? HTTPURLResponse {
      span.setAttribute(key: "http.response.status_code", value: http.statusCode)
      if http.statusCode >= 400 {
        span.setAttribute(key: "error.type", value: String(http.statusCode))
        span.status = .error(description: String(http.statusCode))
      }
    }
    if let error {
      let type = String(describing: Swift.type(of: error))
      span.setAttribute(key: "error.type", value: type)
      span.status = .error(description: type)
    }
    span.end()
  }
}
