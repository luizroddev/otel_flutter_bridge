import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

const channel = MethodChannel(bridgeChannelName);
const appChannel = MethodChannel('poc/native');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late InMemoryTransport transport;
  late List<MethodCall> nativeCalls;

  setUp(() async {
    transport = InMemoryTransport();
    nativeCalls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return null;
    });
    await OtelFlutterBridge.initialize(
      OtelBridgeConfig(
        serviceName: 'poc-app',
        serviceVersion: '1.0.0',
        endpoint: Uri.parse('http://localhost:4318'),
      ),
      transport: transport,
      scheduleDelay: const Duration(milliseconds: 10),
    );
  });

  tearDown(() async {
    await OtelFlutterBridge.shutdown();
    await OTel.reset();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(appChannel, null);
  });

  test('signals ready to the native side', () {
    expect(nativeCalls.single.method, 'ready');
    expect(nativeCalls.single.arguments, containsPair('v', 1));
  });

  test('Dart spans keep their parent and child relation', () async {
    final tracer = OTel.tracer();
    final parent = tracer.startSpan('checkout');
    await tracer.withSpanAsync(parent, () async {
      tracer.startSpan('validate').end();
    });
    parent.end();
    await OtelFlutterBridge.flush();

    final spans = {for (final s in transport.spans) s.name: s};
    expect(spans.keys, containsAll(['checkout', 'validate']));
    expect(spans['validate']!.parentSpanId, spans['checkout']!.spanId);
    expect(spans['validate']!.traceId, spans['checkout']!.traceId);
    final resourceKeys = transport
        .requests.first.resourceSpans.first.resource.attributes
        .map((a) => a.key);
    expect(resourceKeys, containsAll(['service.name', 'service.version']));
  });

  test('channel call carries traceparent and native spans join the trace',
      () async {
    Map<Object?, Object?>? received;
    messenger.setMockMethodCallHandler(appChannel, (call) async {
      received = call.arguments as Map<Object?, Object?>;
      return 'ok';
    });

    final result = await appChannel.invokeTraced<String>(
      'loadCart',
      arguments: {'screen': 'home'},
    );
    expect(result, 'ok');
    expect(received!['screen'], 'home');
    final tp = Traceparent.parse(
      (received![channelContextKey]! as Map)[Traceparent.header] as String,
    )!;

    // The native side creates a child span and sends it back in a batch.
    final reply = await messenger.handlePlatformMessage(
      bridgeChannelName,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('exportSpans', {
          'v': 1,
          'spans': [
            {
              'traceId': tp.traceId,
              'spanId': '1234567890abcdef',
              'parentSpanId': tp.spanId,
              'name': 'NativeCart.load',
              'kind': 'internal',
              'startTimeUnixNano': 1,
              'endTimeUnixNano': 2,
              'attributes': {'customer.cpf': '123.456.789-09'},
            },
          ],
        }),
      ),
      (_) {},
    );
    expect(
      const StandardMethodCodec().decodeEnvelope(reply!),
      {'accepted': 1, 'rejected': 0},
    );
    await OtelFlutterBridge.flush();

    final spans = {for (final s in transport.spans) s.name: s};
    final channelSpan = spans['poc/native/loadCart']!;
    final nativeSpan = spans['NativeCart.load']!;
    expect(nativeSpan.traceId, channelSpan.traceId);
    expect(nativeSpan.parentSpanId, channelSpan.spanId);
    final nativeKeys = nativeSpan.attributes.map((a) => a.key);
    expect(nativeKeys, isNot(contains('customer.cpf')));
    final sessions = transport.spans
        .map((s) => s.attributes.firstWhere((a) => a.key == sessionIdKey))
        .map((a) => a.value.stringValue)
        .toSet();
    expect(sessions, {OtelFlutterBridge.sessionId});
  });

  test('setEnabled(false) stops data and tells native', () async {
    await OtelFlutterBridge.setEnabled(false);
    OTel.tracer().startSpan('hidden').end();
    await OtelFlutterBridge.flush();
    expect(transport.spans, isEmpty);
    expect(nativeCalls.last.method, 'setEnabled');
  });
}
