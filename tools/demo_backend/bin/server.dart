// Tiny HTTP server that continues the app's trace. For local demos only.
//
//   dart run tools/demo_backend/bin/server.dart
//
// It reads `traceparent`, creates a server span as a child of the app's
// client span, and exports to the same local Jaeger, so the trace shows
// app -> native -> backend end to end.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

final _traceparent =
    RegExp(r'^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$');
final _random = Random();

Future<void> main(List<String> args) async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final otlp = Platform.environment['OTEL_ENDPOINT'] ?? 'http://localhost:4318';
  await OTel.initialize(
    serviceName: 'demo-backend',
    serviceVersion: '0.1.0',
    spanProcessor: SimpleSpanProcessor(
      OtlpHttpSpanExporter(OtlpHttpExporterConfig(endpoint: otlp)),
    ),
    enableMetrics: false,
    enableLogs: false,
    detectPlatformResources: false,
  );
  final tracer = OTel.tracer();
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('demo backend on http://localhost:$port, exporting to $otlp');

  await for (final req in server) {
    final parent = _parentContext(req.headers.value('traceparent'));
    final span = tracer.startSpan(
      '${req.method} ${_route(req.uri.path)}',
      kind: SpanKind.server,
      context: parent,
      attributes: OTel.attributesFromMap({
        'http.request.method': req.method,
        'http.route': _route(req.uri.path),
        'url.path': req.uri.path,
      }),
    );
    await tracer.withSpanAsync(span, () async {
      final db = tracer.startSpan('db.query', kind: SpanKind.client);
      await Future<void>.delayed(
          Duration(milliseconds: 20 + _random.nextInt(60)));
      db.end();
    });
    final status = req.uri.path.contains('fail') ? 500 : 200;
    span
      ..setIntAttribute('http.response.status_code', status)
      ..end();
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({
        'path': req.uri.path,
        'traced': parent != null,
        'traceparent': req.headers.value('traceparent'),
      }));
    await req.response.close();
    stdout.writeln(
        '${req.method} ${req.uri.path} traceparent=${req.headers.value('traceparent')}');
  }
}

Context? _parentContext(String? header) {
  final m = _traceparent.firstMatch(header ?? '');
  if (m == null) return null;
  return OTel.context(
    spanContext: OTel.spanContext(
      traceId: OTel.traceIdFrom(m.group(1)!),
      spanId: OTel.spanIdFrom(m.group(2)!),
      traceFlags: OTel.traceFlags(int.parse(m.group(3)!, radix: 16)),
      isRemote: true,
    ),
  );
}

String _route(String path) => path
    .split('/')
    .map((s) => RegExp(r'\d').hasMatch(s) ? '{id}' : s)
    .join('/');
