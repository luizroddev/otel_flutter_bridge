import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dio/dio.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

const _spanKey = 'otel_flutter_bridge.span';

/// Decides whether a request is traced. Extension point.
typedef RequestFilter = bool Function(RequestOptions options);

/// Adds attributes to the request span. Extension point. Keys must be
/// allowed by the redaction config (for example `app.*`), or they are
/// dropped before export.
typedef RequestSpanEnricher = void Function(
  Span span,
  RequestOptions options,
  Response<Object?>? response,
  DioException? error,
);

/// Creates one client span per request, following the OpenTelemetry HTTP
/// semantic conventions, and injects the W3C `traceparent` header so the
/// backend continues the same trace.
///
/// Only the method, host, port, scheme and path are recorded. The full URL,
/// query string, headers and bodies are never recorded.
class OtelDioInterceptor extends Interceptor {
  /// Creates the interceptor.
  ///
  /// [propagateTo] limits which hosts receive `traceparent`; when empty,
  /// every traced request gets it. Use it so trace ids are not sent to third
  /// parties.
  OtelDioInterceptor({
    Tracer? tracer,
    this.propagateTo = const {},
    this.filter,
    this.enrich,
  }) : _tracer = tracer;

  final Tracer? _tracer;

  /// Hosts that receive the `traceparent` header. Empty means all.
  final Set<String> propagateTo;

  /// Returns false for requests that must not be traced.
  final RequestFilter? filter;

  /// Adds custom attributes to each span.
  final RequestSpanEnricher? enrich;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    try {
      if (filter == null || filter!(options)) _start(options);
    } catch (_) {
      // Telemetry never breaks a request.
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<Object?> response,
    ResponseInterceptorHandler handler,
  ) {
    _finish(response.requestOptions, response: response);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _finish(err.requestOptions, response: err.response, error: err);
    handler.next(err);
  }

  void _start(RequestOptions options) {
    final uri = options.uri;
    final method = options.method.toUpperCase();
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
    options.extra[_spanKey] = span;
    if (propagateTo.isEmpty || propagateTo.contains(uri.host)) {
      final value = Traceparent.format(span.spanContext);
      if (value != null) options.headers[Traceparent.header] = value;
    }
  }

  void _finish(
    RequestOptions options, {
    Response<Object?>? response,
    DioException? error,
  }) {
    try {
      final span = options.extra.remove(_spanKey);
      if (span is! Span) return;
      final status = response?.statusCode;
      if (status != null) {
        span.setIntAttribute('http.response.status_code', status);
      }
      if (error != null) {
        span
          ..setStringAttribute(
              'error.type', status?.toString() ?? error.type.name)
          ..setStatus(SpanStatusCode.Error, error.type.name);
      } else if (status != null && status >= 400) {
        span
          ..setStringAttribute('error.type', status.toString())
          ..setStatus(SpanStatusCode.Error);
      }
      enrich?.call(span, options, response, error);
      span.end();
    } catch (_) {
      // Telemetry never breaks a request.
    }
  }
}
