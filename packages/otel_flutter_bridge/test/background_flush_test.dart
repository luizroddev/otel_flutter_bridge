import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

const bridge = MethodChannel(bridgeChannelName);

enum TScreen with JourneyScreen { home }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late InMemoryTransport traces;
  late InMemoryLogTransport logs;

  // A long batch delay: only an explicit flush sends anything.
  Future<void> init() async {
    messenger.setMockMethodCallHandler(bridge, (_) async => null);
    await OtelFlutterBridge.initialize(
      OtelBridgeConfig(serviceName: 'shop', endpoint: Uri.parse('http://x')),
      transport: traces,
      logTransport: logs,
      scheduleDelay: const Duration(minutes: 1),
    );
  }

  setUp(() {
    traces = InMemoryTransport();
    logs = InMemoryLogTransport();
  });

  tearDown(() async {
    await OtelFlutterBridge.shutdown();
    await OTel.reset();
    messenger.setMockMethodCallHandler(bridge, null);
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  void record() {
    OTel.tracer().startSpan('cart.load').end();
    Journey.screen(TScreen.home);
  }

  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    test('leaving the foreground ($state) sends what is pending', () async {
      await init();
      record();
      await settle();
      expect(traces.spans, isEmpty);

      WidgetsBinding.instance.handleAppLifecycleStateChanged(state);
      await settle();
      expect(traces.spans.single.name, 'cart.load');
      expect(logs.records, isNotEmpty);
    });
  }

  test('inactive and resumed send nothing', () async {
    await init();
    record();
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle();
    expect(traces.spans, isEmpty);
  });

  test('native flush: Dart replies once everything was sent', () async {
    await init();
    record();
    Object? reply = 'pending';
    await messenger.handlePlatformMessage(
      bridgeChannelName,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('flush')),
      (data) => reply = const StandardMethodCodec().decodeEnvelope(data!),
    );
    expect(reply, isNull);
    expect(traces.spans.single.name, 'cart.load');
    expect(logs.records, isNotEmpty);
  });

  test('after shutdown, lifecycle changes do nothing', () async {
    await init();
    await OtelFlutterBridge.shutdown();
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settle();
    expect(traces.spans, isEmpty);
  });

  test('native lifecycle events pass redaction', () async {
    await init();
    await messenger.handlePlatformMessage(
      bridgeChannelName,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('exportEvents', {
          'v': 1,
          'events': [
            {
              'name': 'device.app.lifecycle',
              'timeUnixNano': DateTime.now().microsecondsSinceEpoch * 1000,
              'attributes': {'ios.app.state': 'background'},
            },
          ],
        }),
      ),
      (_) {},
    );
    await OtelFlutterBridge.flush();
    final events = [
      for (final r in logs.records)
        {for (final kv in r.attributes) kv.key: kv.value.stringValue},
    ];
    final lifecycle = events.singleWhere(
      (e) => e['event.name'] == 'device.app.lifecycle',
    );
    expect(lifecycle['ios.app.state'], 'background');
  });
}
