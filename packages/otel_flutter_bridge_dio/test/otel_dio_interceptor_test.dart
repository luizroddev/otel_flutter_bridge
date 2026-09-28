import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';
import 'package:otel_flutter_bridge_dio/otel_flutter_bridge_dio.dart';

/// Answers every request locally and remembers its headers.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.status);
  final int status;
  final seenHeaders = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seenHeaders.add(Map.of(options.headers));
    return ResponseBody.fromString('{}', status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

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

  Map<String, Object?> attrs(pb.Span span) => {
        for (final a in span.attributes)
          a.key: a.value.hasStringValue()
              ? a.value.stringValue
              : a.value.intValue.toInt(),
      };

  test('creates a client span and injects traceparent', () async {
    final adapter = FakeAdapter(200);
    final dio = Dio()
      ..httpClientAdapter = adapter
      ..interceptors.add(OtelDioInterceptor());
    await dio.get<Object?>('https://api.example.com/v1/customers/123?cpf=1');
    await OtelFlutterBridge.flush();

    final span = transport.spans.single;
    expect(span.name, 'GET');
    expect(attrs(span), containsPair('http.request.method', 'GET'));
    expect(attrs(span), containsPair('server.address', 'api.example.com'));
    expect(attrs(span), containsPair('url.path', '/v1/customers/{id}'));
    expect(attrs(span), containsPair('http.response.status_code', 200));
    final tp = Traceparent.parse(
      adapter.seenHeaders.single[Traceparent.header] as String?,
    )!;
    expect(tp.traceId, _hex(span.traceId));
    expect(tp.spanId, _hex(span.spanId));
  });

  test('marks 5xx as error and respects propagateTo', () async {
    final adapter = FakeAdapter(503);
    final dio = Dio()
      ..httpClientAdapter = adapter
      ..interceptors.add(OtelDioInterceptor(propagateTo: {'mine.com'}));
    await expectLater(
      dio.get<Object?>('https://third-party.com/x'),
      throwsA(isA<DioException>()),
    );
    await OtelFlutterBridge.flush();
    final span = transport.spans.single;
    expect(attrs(span), containsPair('error.type', '503'));
    expect(span.status.code.value, 2);
    expect(adapter.seenHeaders.single.containsKey('traceparent'), isFalse);
  });

  test('filter skips requests', () async {
    final dio = Dio()
      ..httpClientAdapter = FakeAdapter(200)
      ..interceptors.add(OtelDioInterceptor(filter: (o) => false));
    await dio.get<Object?>('https://a.com');
    await OtelFlutterBridge.flush();
    expect(transport.spans, isEmpty);
  });
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
