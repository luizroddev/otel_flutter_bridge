import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InMemoryTransport transport;

  Future<void> init({RedactionConfig redaction = const RedactionConfig()}) =>
      OtelFlutterBridge.initialize(
        OtelBridgeConfig(
          serviceName: 't',
          endpoint: Uri.parse('http://x'),
          redaction: redaction,
        ),
        transport: transport,
        connectNative: false,
        scheduleDelay: const Duration(milliseconds: 10),
      );

  setUp(() => transport = InMemoryTransport());

  tearDown(() async {
    await OtelFlutterBridge.shutdown();
    await OTel.reset();
  });

  Map<String, String> attrs(String name) => {
        for (final a
            in transport.spans.singleWhere((s) => s.name == name).attributes)
          a.key: a.value.stringValue,
      };

  test('stamps screen and flow when the span starts, not on export', () async {
    await init();
    AppContext.screen = 'checkout.review';
    AppContext.flow = 'purchase';
    final span = OTel.tracer().startSpan('checkout.confirm');
    AppContext.screen = 'home';
    AppContext.flow = null;
    span.end();
    await OtelFlutterBridge.flush();

    expect(attrs('checkout.confirm'),
        containsPair('app.screen', 'checkout.review'));
    expect(attrs('checkout.confirm'), containsPair('app.flow', 'purchase'));
  });

  test('children copy the local parent, even after navigation', () async {
    await init();
    AppContext.screen = 'orders';
    final client = OtelHttpClient(MockClient((_) async {
      AppContext.screen = 'order.detail'; // user navigated meanwhile
      return http.Response('', 200);
    }));
    final tracer = OTel.tracer();
    final parent = tracer.startSpan('orders.load');
    await tracer.withSpanAsync(parent, () async {
      await client.get(Uri.parse('https://a.com/x'));
      await client.get(Uri.parse('https://a.com/y'));
    });
    parent.end();
    tracer.startSpan('order.open').end();
    await OtelFlutterBridge.flush();

    for (final s in transport.spans.where((s) => s.name == 'GET')) {
      final a = {for (final kv in s.attributes) kv.key: kv.value.stringValue};
      expect(a, containsPair('app.screen', 'orders'));
    }
    expect(attrs('order.open'), containsPair('app.screen', 'order.detail'));
  });

  test('nothing set, nothing stamped', () async {
    await init();
    OTel.tracer().startSpan('x.y').end();
    await OtelFlutterBridge.flush();
    expect(attrs('x.y').keys, isNot(contains('app.screen')));
    expect(attrs('x.y').keys, isNot(contains('app.flow')));
  });

  test('kept when the app replaces the allowed prefixes', () async {
    await init(
      redaction: const RedactionConfig(allowedPrefixes: {'poc.'}),
    );
    AppContext.screen = 'home';
    OTel.tracer().startSpan('x.y').end();
    await OtelFlutterBridge.flush();
    expect(attrs('x.y'), containsPair('app.screen', 'home'));
  });

  test('values are still scrubbed', () async {
    await init();
    AppContext.screen = '/orders/123456/detail';
    OTel.tracer().startSpan('x.y').end();
    await OtelFlutterBridge.flush();
    expect(attrs('x.y')['app.screen'], isNot(contains('123456')));
  });

  test('shutdown clears the context', () async {
    await init();
    AppContext.screen = 'home';
    await OtelFlutterBridge.shutdown();
    expect(AppContext.screen, isNull);
  });
}
