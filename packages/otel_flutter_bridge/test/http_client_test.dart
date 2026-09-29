import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:http/testing.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InMemoryTransport transport;

  setUp(() async {
    transport = InMemoryTransport();
    await OtelFlutterBridge.initialize(
      OtelBridgeConfig(serviceName: 't', endpoint: Uri.parse('http://x')),
      transport: transport,
      connectNative: false,
      scheduleDelay: const Duration(milliseconds: 10),
    );
  });

  tearDown(() async {
    await OtelFlutterBridge.shutdown();
    await OTel.reset();
  });

  /// Answers every request with [status] and remembers the requests.
  MockClient fake(int status, List<http.BaseRequest> seen) =>
      MockClient((request) async {
        seen.add(request);
        return http.Response('{}', status);
      });

  test('creates a client span and injects traceparent', () async {
    final seen = <http.BaseRequest>[];
    final client = OtelHttpClient(fake(200, seen));
    final res = await client.get(
      Uri.parse('https://api.example.com/v1/customers/123?cpf=1'),
    );
    expect(res.statusCode, 200);
    await OtelFlutterBridge.flush();

    final span = transport.spans.single;
    expect(span.name, 'GET');
    expect(span.kind, pb.Span_SpanKind.SPAN_KIND_CLIENT);
    final a = _attrs(span);
    expect(a, containsPair('http.request.method', 'GET'));
    expect(a, containsPair('server.address', 'api.example.com'));
    expect(a, containsPair('url.scheme', 'https'));
    expect(a, containsPair('url.path', '/v1/customers/{id}'));
    expect(a, containsPair('http.response.status_code', 200));
    expect(a.values.join(' '), isNot(contains('cpf')));

    final tp = Traceparent.parse(seen.single.headers[Traceparent.header])!;
    expect(tp.traceId, _hex(span.traceId));
    expect(tp.spanId, _hex(span.spanId));
  });

  test('marks 4xx/5xx as error and respects propagateTo', () async {
    final seen = <http.BaseRequest>[];
    final client = OtelHttpClient(fake(503, seen), propagateTo: {'mine.com'});
    final res = await client.post(Uri.parse('https://third-party.com/x'));
    expect(res.statusCode, 503);
    await OtelFlutterBridge.flush();

    final span = transport.spans.single;
    expect(span.name, 'POST');
    expect(_attrs(span), containsPair('error.type', '503'));
    expect(span.status.code, pb.Status_StatusCode.STATUS_CODE_ERROR);
    expect(seen.single.headers.containsKey(Traceparent.header), isFalse);
  });

  test('records transport errors and rethrows the same error', () async {
    final boom = http.ClientException('connection refused');
    final client = OtelHttpClient(MockClient((_) async => throw boom));
    await expectLater(
      client.get(Uri.parse('https://api.example.com/a')),
      throwsA(same(boom)),
    );
    await OtelFlutterBridge.flush();

    final span = transport.spans.single;
    expect(_attrs(span), containsPair('error.type', 'ClientException'));
    expect(span.status.code, pb.Status_StatusCode.STATUS_CODE_ERROR);
  });

  test('filter skips requests and leaves them untouched', () async {
    final seen = <http.BaseRequest>[];
    final client = OtelHttpClient(fake(200, seen), filter: (_) => false);
    await client.get(Uri.parse('https://a.com'));
    await OtelFlutterBridge.flush();
    expect(transport.spans, isEmpty);
    expect(seen.single.headers.containsKey(Traceparent.header), isFalse);
  });

  test('a throwing filter or enricher never breaks the request', () async {
    final seen = <http.BaseRequest>[];
    final noFilter = OtelHttpClient(
      fake(200, seen),
      filter: (_) => throw StateError('bug'),
    );
    expect((await noFilter.get(Uri.parse('https://a.com'))).statusCode, 200);

    final badEnrich = OtelHttpClient(
      fake(200, seen),
      enrich: (_, __, ___, ____) => throw StateError('bug'),
    );
    expect((await badEnrich.get(Uri.parse('https://a.com'))).statusCode, 200);
    await OtelFlutterBridge.flush();
    expect(transport.spans, hasLength(1));
  });

  test('enrich adds app.* attributes', () async {
    final client = OtelHttpClient(
      fake(200, []),
      enrich: (span, request, response, error) =>
          span.setStringAttribute('app.api', 'orders'),
    );
    await client.get(Uri.parse('https://a.com/orders'));
    await OtelFlutterBridge.flush();
    expect(_attrs(transport.spans.single), containsPair('app.api', 'orders'));
  });

  test('is a child of the active span', () async {
    final client = OtelHttpClient(fake(200, []));
    final tracer = OTel.tracer();
    final parent = tracer.startSpan('orders.load');
    await tracer.withSpanAsync(parent, () async {
      await client.get(Uri.parse('https://a.com/orders'));
    });
    parent.end();
    await OtelFlutterBridge.flush();

    final http = transport.spans.singleWhere((s) => s.name == 'GET');
    final root = transport.spans.singleWhere((s) => s.name == 'orders.load');
    expect(http.traceId, root.traceId);
    expect(http.parentSpanId, root.spanId);
  });

  test('inside RetryClient: one span per attempt', () async {
    var calls = 0;
    final inner = MockClient((_) async {
      calls++;
      return http.Response('', calls == 1 ? 503 : 200);
    });
    final client = RetryClient(
      OtelHttpClient(inner),
      delay: (_) => Duration.zero,
    );
    final res = await client.get(Uri.parse('https://a.com/x'));
    expect(res.statusCode, 200);
    await OtelFlutterBridge.flush();

    final statuses =
        transport.spans.map((s) => _attrs(s)['http.response.status_code']);
    expect(statuses, [503, 200]);
  });
}

Map<String, Object?> _attrs(pb.Span span) => {
      for (final a in span.attributes)
        a.key: a.value.hasStringValue()
            ? a.value.stringValue
            : a.value.intValue.toInt(),
    };

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
