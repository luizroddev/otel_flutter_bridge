import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

enum TScreen with JourneyScreen {
  home,
  login('Login');

  const TScreen([this.label]);

  @override
  final String? label;
}

enum TFlow with JourneyFlow { login }

enum TAction with JourneyAction {
  chooseBiometric,
  confirmLogin('Confirmar login');

  const TAction([this.label]);

  @override
  final String? label;
}

enum Method { biometric, password }

class FixedSession implements SessionIdProvider {
  String id = 's1';
  @override
  String get currentId => id;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InMemoryTransport traces;
  late InMemoryLogTransport logs;
  late FixedSession session;

  Future<void> init({bool exportLogs = true}) => OtelFlutterBridge.initialize(
        OtelBridgeConfig(
          serviceName: 'shop',
          endpoint: Uri.parse('http://x'),
          deviceId: 'device-1',
          exportLogs: exportLogs,
        ),
        transport: traces,
        logTransport: logs,
        sessionIdProvider: session,
        connectNative: false,
        scheduleDelay: const Duration(milliseconds: 10),
      );

  setUp(() {
    traces = InMemoryTransport();
    logs = InMemoryLogTransport();
    session = FixedSession();
  });

  tearDown(() async {
    await OtelFlutterBridge.shutdown();
    await OTel.reset();
  });

  Object? value(pb.AnyValue v) => switch (v.whichValue()) {
        pb.AnyValue_Value.stringValue => v.stringValue,
        pb.AnyValue_Value.intValue => v.intValue.toInt(),
        pb.AnyValue_Value.boolValue => v.boolValue,
        pb.AnyValue_Value.doubleValue => v.doubleValue,
        _ => null,
      };

  Map<String, Object?> attrsOf(List<pb.KeyValue> kvs) =>
      {for (final kv in kvs) kv.key: value(kv.value)};

  List<Map<String, Object?>> events() =>
      [for (final r in logs.records) attrsOf(r.attributes)];

  Map<String, Object?> spanAttrs(String name) =>
      attrsOf(traces.spans.singleWhere((s) => s.name == name).attributes);

  test('screen, flow and instant action become ordered log events', () async {
    await init();
    Journey.setUser('u-42');
    Journey.screen(TScreen.login);
    final run = Journey.startFlow(TFlow.login);
    Journey.event(TAction.chooseBiometric,
        attributes: {'app.login.method': Method.biometric});
    run.end(JourneyOutcome.success);
    await OtelFlutterBridge.flush();

    final e = events();
    expect(e.map((a) => a['event.name']), [
      'app.screen.view',
      'app.flow.start',
      'app.action',
      'app.flow.end',
    ]);
    expect(e[0], containsPair('app.screen.name', 'login'));
    expect(e[0], containsPair('app.screen.label', 'Login'));
    for (final a in e) {
      expect(a, containsPair('session.id', 's1'));
      expect(a, containsPair('user.id', 'u-42'));
      expect(a, containsPair('otel_flutter_bridge.source', 'dart'));
    }
    final id = e[1]['app.flow.instance_id'];
    expect(id, isA<String>());
    expect((id! as String).length, 32);
    expect(e[2], containsPair('app.flow.instance_id', id));
    expect(e[2], containsPair('app.action.name', 'chooseBiometric'));
    expect(e[2], containsPair('app.login.method', 'biometric'));
    expect(e[2].containsKey('app.outcome'), isFalse);
    expect(e[3], containsPair('app.outcome', 'success'));
    expect(e[3], containsPair('app.flow.instance_id', id));
    expect(e[3]['app.duration_ms'], isA<int>());

    final resource =
        attrsOf(logs.requests.first.resourceLogs.first.resource.attributes);
    expect(resource, containsPair('service.name', 'shop'));
    expect(resource, containsPair('device.id', 'device-1'));
    // An instant event outside any span has no trace.
    expect(logs.records.first.traceId, isEmpty);
    // Body is never sent.
    expect(logs.records.every((r) => !r.hasBody()), isTrue);
  });

  test('track: span with children, event linked to its trace', () async {
    await init();
    Journey.screen(TScreen.login);
    final run = Journey.startFlow(TFlow.login);
    final client = OtelHttpClient(MockClient((_) async {
      Journey.screen(TScreen.home); // navigated while the request ran
      return http.Response('', 401);
    }));
    final ok = await Journey.track(
      TAction.confirmLogin,
      () async =>
          (await client.get(Uri.parse('http://api/login'))).statusCode == 200,
      outcome: (ok) => ok ? JourneyOutcome.success : JourneyOutcome.failure,
    );
    expect(ok, isFalse);
    await OtelFlutterBridge.flush();

    final action = traces.spans.singleWhere((s) => s.name == 'confirmLogin');
    final http0 = traces.spans.singleWhere((s) => s.name == 'GET');
    expect(http0.parentSpanId, action.spanId);
    expect(action.status.code, pb.Status_StatusCode.STATUS_CODE_ERROR);
    final a = spanAttrs('confirmLogin');
    expect(a, containsPair('app.action.name', 'confirmLogin'));
    expect(a, containsPair('app.outcome', 'failure'));
    expect(a, containsPair('app.screen.name', 'login'));
    expect(a, containsPair('app.flow.instance_id', run.instanceId));
    expect(a, containsPair('session.id', 's1'));

    final rec = logs.records.singleWhere(
        (r) => attrsOf(r.attributes)['event.name'] == 'app.action');
    expect(rec.traceId, action.traceId);
    expect(rec.spanId, action.spanId);
    final e = attrsOf(rec.attributes);
    expect(e, containsPair('app.outcome', 'failure'));
    expect(e, containsPair('app.action.label', 'Confirmar login'));
    expect(e['app.action.instance_id'], a['app.action.instance_id']);
    expect(e['app.duration_ms'], isA<int>());
  });

  test('track without outcome is completed, not success', () async {
    await init();
    await Journey.track(TAction.confirmLogin, () {});
    await OtelFlutterBridge.flush();
    expect(spanAttrs('confirmLogin'), containsPair('app.outcome', 'completed'));
    expect(events().single, containsPair('app.outcome', 'completed'));
  });

  test('track rethrows the same error, records only its type', () async {
    await init();
    final error = StateError('secret 123456789');
    Object? caught;
    try {
      await Journey.track(TAction.confirmLogin, () => throw error);
    } catch (e) {
      caught = e;
    }
    expect(caught, same(error));
    await OtelFlutterBridge.flush();
    final e = events().single;
    expect(e, containsPair('app.outcome', 'failure'));
    expect(e, containsPair('error.type', 'StateError'));
    expect(
        e.values.whereType<String>().any((v) => v.contains('secret')), isFalse);
    expect(spanAttrs('confirmLogin'), containsPair('error.type', 'StateError'));
  });

  test('event inside track carries the action trace', () async {
    await init();
    await Journey.track(TAction.confirmLogin, () async {
      Journey.event(TAction.chooseBiometric);
    });
    await OtelFlutterBridge.flush();
    final span = traces.spans.single;
    final inner = logs.records.firstWhere(
        (r) => attrsOf(r.attributes)['app.action.name'] == 'chooseBiometric');
    expect(inner.traceId, span.traceId);
  });

  test('spans keep the session they started in', () async {
    await init();
    final span = OTel.tracer().startSpan('old');
    session.id = 's2';
    span.end();
    await OtelFlutterBridge.flush();
    expect(spanAttrs('old'), containsPair('session.id', 's1'));
  });

  test('ending a flow leaves the context; user can be cleared', () async {
    await init();
    Journey.setUser('u-1');
    final run = Journey.startFlow(TFlow.login);
    expect(Journey.currentFlow, same(run));
    run
      ..end()
      ..end(JourneyOutcome.failure); // only the first call counts
    expect(AppContext.flow, isNull);
    expect(Journey.currentFlow, isNull);
    Journey.setUser(null);
    Journey.screen(TScreen.home);
    await OtelFlutterBridge.flush();
    final e = events();
    expect(e.where((a) => a['event.name'] == 'app.flow.end'), hasLength(1));
    expect(e[1], containsPair('app.outcome', 'completed'));
    expect(e.last.containsKey('user.id'), isFalse);
    expect(e.last.containsKey('app.flow.name'), isFalse);
  });

  test('exportLogs false: no events, spans still flow', () async {
    await init(exportLogs: false);
    await Journey.track(TAction.confirmLogin, () {});
    Journey.screen(TScreen.home);
    await OtelFlutterBridge.flush();
    expect(logs.requests, isEmpty);
    expect(traces.spans, hasLength(1));
  });

  test('kill switch drops events', () async {
    await init();
    await OtelFlutterBridge.setEnabled(false);
    Journey.screen(TScreen.home);
    await OtelFlutterBridge.flush();
    expect(logs.requests, isEmpty);
  });

  test('without initialize, track runs and nothing is recorded', () async {
    final r = await Journey.track(TAction.confirmLogin, () => 7);
    expect(r, 7);
    Journey.screen(TScreen.home);
    expect(AppContext.screen, 'home');
  });

  test('redaction scrubs app attributes of events', () async {
    await init();
    Journey.event(TAction.chooseBiometric,
        attributes: {'app.note': 'mail a@b.com', 'secret': 'x'});
    await OtelFlutterBridge.flush();
    final e = events().single;
    expect(e['app.note'], isNot(contains('a@b.com')));
    expect(e.containsKey('secret'), isFalse);
  });

  testWidgets('navigator observer records page routes', (tester) async {
    await tester.runAsync(init);
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: key,
      navigatorObservers: [
        JourneyNavigatorObserver(
          screenOf: (r) => r.settings.name == '/' ? TScreen.home : null,
        ),
      ],
      routes: {
        '/': (_) => const SizedBox(),
        '/cart': (_) => const SizedBox(),
      },
    ));
    key.currentState!.pushNamed('/cart');
    await tester.pumpAndSettle();
    unawaited(showDialog<void>(
        context: key.currentContext!, builder: (_) => const SizedBox()));
    await tester.pumpAndSettle();
    key.currentState!.pop(); // dialog
    await tester.pumpAndSettle();
    key.currentState!.pop(); // cart
    await tester.pumpAndSettle();
    await tester.runAsync(OtelFlutterBridge.flush);
    expect(
      events().map((a) => a['app.screen.name']),
      ['home', '/cart', 'home'],
    );
  });
}
