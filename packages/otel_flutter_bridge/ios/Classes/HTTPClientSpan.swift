import Foundation
import OpenTelemetryApi

/// One client span per HTTP request, for any native HTTP stack: the app's
/// own API client, Alamofire, a delegate-based `URLSession`. Call `start`
/// right before sending, send the returned request (it carries
/// `traceparent`), and call `finish` when the response or error arrives.
///
/// ```swift
/// let (span, traced) = HTTPClientSpan.start(urlRequest)
/// sessionManager.request(traced).validate().responseData { response in
///   HTTPClientSpan.finish(span, response: response.response, error: response.error)
///   completion(response)
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

  /// Starts the span and returns the request to send, with `traceparent`.
  ///
  /// `parent` defaults to the active span (see
  /// `OpenTelemetry.instance.contextProvider.withActiveSpan`), so a request
  /// made inside a traced channel handler becomes its child.
  public static func start(_ request: URLRequest,
                           parent: SpanContext? = nil) -> (span: Span, request: URLRequest) {
    let method = HTTPSemantics.method(request.httpMethod)
    let url = request.url
    let builder = OtelFlutterBridge.shared.tracer()
      .spanBuilder(spanName: HTTPSemantics.spanName(forMethod: method))
      .setSpanKind(spanKind: .client)
      .setAttribute(key: "http.request.method", value: method)
      .setAttribute(key: "url.path", value: HTTPSemantics.path(of: url))
    if let parent { builder.setParent(parent) }
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
    return (span, traced)
  }

  /// Records the outcome and ends the span. Call it exactly once per
  /// `start`, also on cancellation and errors.
  public static func finish(_ span: Span, response: URLResponse?, error: Error?) {
    let status = (response as? HTTPURLResponse)?.statusCode
    if let status { span.setAttribute(key: "http.response.status_code", value: status) }
    if let type = HTTPSemantics.errorType(statusCode: status, error: error) {
      span.setAttribute(key: "error.type", value: type)
      span.status = .error(description: type)
    }
    span.end()
  }
}
