import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:http/http.dart' as http;

import 'traceparent.dart';

/// Decides whether a request is traced. Extension point.
typedef HttpRequestFilter = bool Function(http.BaseRequest request);

/// Adds attributes to the request span. Extension point. Keys must be
/// allowed by the redaction config (for example `app.*`), or they are
/// dropped before export.
typedef HttpRequestSpanEnricher = void Function(
  Span span,
  http.BaseRequest request,
  http.StreamedResponse? response,
  Object? error,
);

/// A `package:http` client that creates one client span per request,
/// following the OpenTelemetry HTTP semantic conventions, and injects the
/// W3C `traceparent` header so the backend continues the same trace.
///
/// Wrap the app's single [http.Client] and inject it wherever requests are
/// made. Requests sent through other clients (including the top-level
/// `http.get` functions) are not traced.
///
/// Only the method, host, port, scheme and path are recorded. The full URL,
/// query string, headers and bodies are never recorded.
///
/// The span ends when the response headers arrive, which is when the status
/// code is known. Reading the body is not part of the span.
///
/// Compose it inside retry clients (`RetryClient(OtelHttpClient(...))`) to
/// get one span per attempt.
class OtelHttpClient extends http.BaseClient {
  /// Creates the client around [inner], which does the actual work.
  ///
  /// [propagateTo] limits which hosts receive `traceparent`; when empty,
  /// every traced request gets it. Use it so trace ids are not sent to third
  /// parties.
  OtelHttpClient(
    this._inner, {
    Tracer? tracer,
    this.propagateTo = const {},
    this.filter,
    this.enrich,
  }) : _tracer = tracer;

  final http.Client _inner;
  final Tracer? _tracer;

  /// Hosts that receive the `traceparent` header. Empty means all.
  final Set<String> propagateTo;

  /// Returns false for requests that must not be traced.
  final HttpRequestFilter? filter;

  /// Adds custom attributes to each span.
  final HttpRequestSpanEnricher? enrich;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Span? span;
    try {
      if (filter == null || filter!(request)) span = _start(request);
    } catch (_) {
      // Telemetry never breaks a request.
    }
    if (span == null) return _inner.send(request);

    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (e) {
      _finish(span, request, error: e);
      rethrow;
    }
    _finish(span, request, response: response);
    return response;
  }

  @override
  void close() => _inner.close();

  Span _start(http.BaseRequest request) {
    final uri = request.url;
    final method = request.method.toUpperCase();
    final tracer = _tracer ?? OTel.tracer();
    final span = tracer.startSpan(
      method,
      kind: SpanKind.client,
      attributes: OTel.attributesFromMap({
        'http.request.method': method,
        'server.address': uri.host,
        if (uri.hasPort) 'server.port': uri.port,
        'url.scheme': uri.scheme,
        'url.path': uri.path.isEmpty ? '/' : uri.path,
      }),
    );
    if (propagateTo.isEmpty || propagateTo.contains(uri.host)) {
      final value = Traceparent.format(span.spanContext);
      if (value != null) request.headers[Traceparent.header] = value;
    }
    return span;
  }

  void _finish(
    Span span,
    http.BaseRequest request, {
    http.StreamedResponse? response,
    Object? error,
  }) {
    try {
      final status = response?.statusCode;
      if (status != null) {
        span.setIntAttribute('http.response.status_code', status);
      }
      if (error != null) {
        final type = error.runtimeType.toString();
        span
          ..setStringAttribute('error.type', type)
          ..setStatus(SpanStatusCode.Error, type);
      } else if (status != null && status >= 400) {
        span
          ..setStringAttribute('error.type', status.toString())
          ..setStatus(SpanStatusCode.Error);
      }
      enrich?.call(span, request, response, error);
    } catch (_) {
      // Telemetry never breaks a request.
    }
    try {
      span.end();
    } catch (_) {
      // Telemetry never breaks a request.
    }
  }
}
