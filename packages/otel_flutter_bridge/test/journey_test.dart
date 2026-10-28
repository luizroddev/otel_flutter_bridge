import 'dart:async';
import 'dart:convert';

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

enum TFlow with JourneyFlow { login, activation }

enum TAction with JourneyAction {
  chooseBiometric,
  confirmLogin('Confirmar login');

  const TAction([this.label]);

  @override
  final String? label;
}

enum Method { biometric, password }

enum TReason with JourneyReason { invalidPassword, blockedAccount }

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
          installationId: 'install-1',
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
      'journey.screen.view',
      'journey.flow.start',
      'journey.action',
      'journey.flow.end',
    ]);
    expect(e[0], containsPair('app.screen.name', 'login'));
    expect(e[0], containsPair('journey.screen.label', 'Login'));
    for (final a in e) {
      expect(a, containsPair('session.id', 's1'));
      expect(a, containsPair('user.id', 'u-42'));
      expect(a, containsPair('otel_flutter_bridge.source', 'dart'));
    }
    final id = e[1]['journey.flow.instance_id'];
    expect(id, isA<String>());
    expect((id! as String).length, 32);
    expect(e[2], containsPair('journey.flow.instance_id', id));
    expect(e[2], containsPair('journey.action.name', 'chooseBiometric'));
    expect(e[2], containsPair('app.login.method', 'biometric'));
    expect(e[2].containsKey('journey.outcome'), isFalse);
    expect(e[3], containsPair('journey.outcome', 'success'));
    expect(e[3], containsPair('journey.flow.instance_id', id));
    expect(e[3]['journey.duration_ms'], isA<int>());

    final resource =
        attrsOf(logs.requests.first.resourceLogs.first.resource.attributes);
    expect(resource, containsPair('service.name', 'shop'));
    expect(resource, containsPair('app.installation.id', 'install-1'));
    // The library never sends device.id: a receiver stamps it.
    expect(resource.containsKey('device.id'), isFalse);
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
    expect(a, containsPair('journey.action.name', 'confirmLogin'));
    expect(a, containsPair('journey.outcome', 'failure'));
    expect(a, containsPair('app.screen.name', 'login'));
    expect(a, containsPair('journey.flow.instance_id', run.instanceId));
    expect(a, containsPair('session.id', 's1'));

    final rec = logs.records.singleWhere(
        (r) => attrsOf(r.attributes)['event.name'] == 'journey.action');
    expect(rec.traceId, action.traceId);
    expect(rec.spanId, action.spanId);
    final e = attrsOf(rec.attributes);
    expect(e, containsPair('journey.outcome', 'failure'));
    expect(e, containsPair('journey.action.label', 'Confirmar login'));
    expect(e['journey.action.instance_id'], a['journey.action.instance_id']);
    expect(e['journey.duration_ms'], isA<int>());
  });

  test('track without outcome is completed, not success', () async {
    await init();
    await Journey.track(TAction.confirmLogin, () {});
    await OtelFlutterBridge.flush();
    expect(spanAttrs('confirmLogin'),
        containsPair('journey.outcome', 'completed'));
    expect(events().single, containsPair('journey.outcome', 'completed'));
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
    expect(e, containsPair('journey.outcome', 'failure'));
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
    final inner = logs.records.firstWhere((r) =>
        attrsOf(r.attributes)['journey.action.name'] == 'chooseBiometric');
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
      ..end(JourneyOutcome.completed)
      ..end(JourneyOutcome.failure); // only the first call counts
    expect(AppContext.flow, isNull);
    expect(Journey.currentFlow, isNull);
    Journey.setUser(null);
    Journey.screen(TScreen.home);
    await OtelFlutterBridge.flush();
    final e = events();
    expect(e.where((a) => a['event.name'] == 'journey.flow.end'), hasLength(1));
    expect(e[1], containsPair('journey.outcome', 'completed'));
    expect(e.last.containsKey('user.id'), isFalse);
    expect(e.last.containsKey('journey.flow.name'), isFalse);
  });

  test('reason: on flow end, instant event and track', () async {
    await init();
    final run = Journey.startFlow(TFlow.login);
    Journey.event(TAction.chooseBiometric,
        outcome: JourneyOutcome.failure, reason: TReason.blockedAccount);
    await Journey.track(TAction.confirmLogin, () async => false,
        outcome: (ok) => ok ? JourneyOutcome.success : JourneyOutcome.failure,
        reason: (ok) => ok ? null : TReason.invalidPassword);
    run.end(JourneyOutcome.failure, reason: TReason.invalidPassword);
    await OtelFlutterBridge.flush();

    final e = events();
    Map<String, Object?> action(String name) =>
        e.singleWhere((a) => a['journey.action.name'] == name);
    expect(action('chooseBiometric'),
        containsPair('journey.outcome_reason', 'blockedAccount'));
    expect(action('confirmLogin'),
        containsPair('journey.outcome_reason', 'invalidPassword'));
    expect(spanAttrs('confirmLogin'),
        containsPair('journey.outcome_reason', 'invalidPassword'));
    final end = e.singleWhere((a) => a['event.name'] == 'journey.flow.end');
    expect(end, containsPair('journey.outcome', 'failure'));
    expect(end, containsPair('journey.outcome_reason', 'invalidPassword'));
    expect(e.first.containsKey('journey.outcome_reason'), isFalse);
  });

  test('session.start: first session, then renewal with previous_id', () async {
    var now = DateTime(2026, 1, 1, 10);
    final sessions = SessionManager(
      const SessionConfig(inactivityTimeout: Duration(minutes: 30)),
      clock: () => now,
    );
    await OtelFlutterBridge.initialize(
      OtelBridgeConfig(serviceName: 'shop', endpoint: Uri.parse('http://x')),
      transport: traces,
      logTransport: logs,
      sessionIdProvider: sessions,
      connectNative: false,
      scheduleDelay: const Duration(milliseconds: 10),
    );
    Journey.screen(TScreen.home);
    now = now.add(const Duration(minutes: 31));
    Journey.screen(TScreen.login);
    await OtelFlutterBridge.flush();

    final e = events();
    expect(e.map((a) => a['event.name']), [
      'session.start',
      'journey.screen.view',
      'session.start',
      'journey.screen.view',
    ]);
    final first = e[0]['session.id'];
    final second = e[2]['session.id'];
    expect(first, isNot(second));
    expect(e[0].containsKey('session.previous_id'), isFalse);
    expect(e[1], containsPair('session.id', first));
    expect(e[2], containsPair('session.previous_id', first));
    expect(e[3], containsPair('session.id', second));
  });

  test('sessionStarted never links a session to itself', () async {
    await init();
    Journey.sessionStarted('s1', previousId: 's1');
    await OtelFlutterBridge.flush();
    final e = events().single;
    expect(e, containsPair('event.name', 'session.start'));
    expect(e.containsKey('session.previous_id'), isFalse);
  });

  test('the data contract keeps its names', () {
    // Receivers (a backend allowlist, the dashboard) depend on these exact
    // strings. Changing one is a breaking change of docs/specs/journey.md.
    expect({
      sessionIdKey,
      sessionPreviousIdKey,
      userIdKey,
      appInstallationIdKey,
      eventNameKey,
      logRecordUidKey,
      appScreenKey,
      journeyScreenLabelKey,
      journeyFlowKey,
      journeyFlowLabelKey,
      journeyFlowInstanceKey,
      journeyFlowParentInstanceKey,
      journeyActionKey,
      journeyActionLabelKey,
      journeyActionInstanceKey,
      journeyOutcomeKey,
      journeyOutcomeReasonKey,
      journeyDurationKey,
      bridgeSourceKey,
    }, {
      'session.id',
      'session.previous_id',
      'user.id',
      'app.installation.id',
      'event.name',
      'log.record.uid',
      'app.screen.name',
      'journey.screen.label',
      'journey.flow.name',
      'journey.flow.label',
      'journey.flow.instance_id',
      'journey.flow.parent_instance_id',
      'journey.action.name',
      'journey.action.label',
      'journey.action.instance_id',
      'journey.outcome',
      'journey.outcome_reason',
      'journey.duration_ms',
      'otel_flutter_bridge.source',
    });
    expect([
      eventScreenView,
      eventFlowStart,
      eventFlowEnd,
      eventAction,
      eventSessionStart,
    ], [
      'journey.screen.view',
      'journey.flow.start',
      'journey.flow.end',
      'journey.action',
      'session.start',
    ]);
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

  test('nested flows: the inner one ends, the outer is current again',
      () async {
    await init();
    final login = Journey.startFlow(TFlow.login);
    final activation = Journey.startFlow(TFlow.activation);
    expect(Journey.currentFlow, same(activation));
    Journey.event(TAction.chooseBiometric);
    activation.end(JourneyOutcome.success);
    expect(Journey.currentFlow, same(login));
    expect(AppContext.flow, 'login');
    expect(AppContext.flowInstanceId, login.instanceId);
    Journey.event(TAction.confirmLogin);
    login.end(JourneyOutcome.success);
    expect(Journey.currentFlow, isNull);
    expect(AppContext.flowInstanceId, isNull);
    await OtelFlutterBridge.flush();

    final e = events();
    final starts =
        e.where((a) => a['event.name'] == 'journey.flow.start').toList();
    expect(
        starts.first.containsKey('journey.flow.parent_instance_id'), isFalse);
    expect(starts.last['journey.flow.parent_instance_id'], login.instanceId);
    final ends = e.where((a) => a['event.name'] == 'journey.flow.end').toList();
    expect(ends.first['journey.flow.parent_instance_id'], login.instanceId);
    Map<String, Object?> action(String name) =>
        e.singleWhere((a) => a['journey.action.name'] == name);
    expect(action('chooseBiometric')['journey.flow.instance_id'],
        activation.instanceId);
    expect(
        action('confirmLogin')['journey.flow.instance_id'], login.instanceId);
  });

  test('ending the outer flow first keeps the inner one current', () async {
    await init();
    final login = Journey.startFlow(TFlow.login);
    final activation = Journey.startFlow(TFlow.activation);
    login.end(JourneyOutcome.completed);
    expect(Journey.currentFlow, same(activation));
    expect(AppContext.flowInstanceId, activation.instanceId);
    activation.end(JourneyOutcome.completed);
    expect(Journey.currentFlow, isNull);
  });

  test('track: span and event keep the context of when it started', () async {
    await init();
    Journey.screen(TScreen.login);
    final run = Journey.startFlow(TFlow.login);
    await Journey.track(TAction.confirmLogin, () async {
      Journey.screen(TScreen.home); // navigated while it ran
      Journey.setUser('u-9'); // logged in while it ran
      run.end(JourneyOutcome.success);
      session.id = 's2'; // session renewed while it ran
    });
    await OtelFlutterBridge.flush();
    final e = events().singleWhere((a) =>
        a['event.name'] == 'journey.action' &&
        a['journey.action.name'] == 'confirmLogin');
    expect(e, containsPair('app.screen.name', 'login'));
    expect(e, containsPair('journey.flow.instance_id', run.instanceId));
    expect(e, containsPair('session.id', 's1'));
    expect(e.containsKey('user.id'), isFalse);
    final span = spanAttrs('confirmLogin');
    expect(span, containsPair('app.screen.name', 'login'));
    expect(span, containsPair('session.id', 's1'));
    expect(span.containsKey('user.id'), isFalse);
  });

  test('every event has its own log.record.uid and the OTLP event_name',
      () async {
    await init();
    Journey.screen(TScreen.home);
    Journey.event(TAction.chooseBiometric);
    await OtelFlutterBridge.flush();
    final uids = events().map((a) => a['log.record.uid']).toList();
    expect(uids.toSet(), hasLength(2));
    for (final uid in uids) {
      expect(uid, matches(RegExp(r'^[0-9a-f]{32}$')));
    }
    // Field 12 survives encoding, so OTLP receivers read event_name.
    final decoded = pb.ExportLogsServiceRequest.fromBuffer(
      logs.requests.single.writeToBuffer(),
    );
    final names = [
      for (final r in decoded.resourceLogs.single.scopeLogs.single.logRecords)
        utf8.decode(r.unknownFields.getField(12)!.lengthDelimited.single),
    ];
    expect(names, ['journey.screen.view', 'journey.action']);
  });

  test('os.type and os.name follow the semantic conventions', () {
    expect(osAttributes('ios'), {'os.type': 'darwin', 'os.name': 'iOS'});
    expect(osAttributes('android'), {'os.type': 'linux', 'os.name': 'Android'});
    expect(osAttributes('fuchsia'), {'os.name': 'fuchsia'});
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
