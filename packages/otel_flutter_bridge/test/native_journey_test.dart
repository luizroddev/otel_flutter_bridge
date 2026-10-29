import 'dart:convert';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';
import 'package:otel_flutter_bridge/src/journey.dart' show applyJourneyOp;

const bridge = MethodChannel(bridgeChannelName);

enum TScreen with JourneyScreen { home, password }

enum TFlow with JourneyFlow { login }

enum TAction with JourneyAction { confirmLogin }

const traceId = '4bf92f3577b34da6a3ce929d0e0e4736';
const spanId = '00f067aa0ba902b7';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late InMemoryTransport traces;
  late InMemoryLogTransport logs;
  late List<MethodCall> calls;

  /// Starts the bridge; native replies to `ready` with [ready].
  Future<void> init({
    Object? ready,
    SessionConfig session = const SessionConfig(),
    Duration delay = const Duration(milliseconds: 10),
  }) async {
    messenger.setMockMethodCallHandler(bridge, (call) async {
      calls.add(call);
      return call.method == 'ready' ? ready : null;
    });
    await OtelFlutterBridge.initialize(
      OtelBridgeConfig(
        serviceName: 'shop',
        endpoint: Uri.parse('http://x'),
        session: session,
      ),
      transport: traces,
      logTransport: logs,
      scheduleDelay: delay,
    );
  }

  setUp(() {
    traces = InMemoryTransport();
    logs = InMemoryLogTransport();
    calls = [];
  });

  tearDown(() async {
    await OtelFlutterBridge.shutdown();
    await OTel.reset();
    messenger.setMockMethodCallHandler(bridge, null);
  });

  Future<void> fromNative(String method, Object? arguments) =>
      messenger.handlePlatformMessage(
        bridgeChannelName,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );

  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await OtelFlutterBridge.flush();
  }

  Object? value(pb.AnyValue v) => switch (v.whichValue()) {
        pb.AnyValue_Value.stringValue => v.stringValue,
        pb.AnyValue_Value.intValue => v.intValue.toInt(),
        pb.AnyValue_Value.boolValue => v.boolValue,
        _ => null,
      };

  Map<String, Object?> attrsOf(List<pb.KeyValue> kvs) =>
      {for (final kv in kvs) kv.key: value(kv.value)};

  List<Map<String, Object?>> events() =>
      [for (final r in logs.records) attrsOf(r.attributes)];

  List<Object?> ops() =>
      [for (final c in calls.where((c) => c.method == 'journey')) c.arguments];

  Map<String, Object?> nativeRun(String id, {String code = 'login'}) => {
        'code': code,
        'label': null,
        'instanceId': id,
        'parentInstanceId': null,
        'startUnixNano': DateTime.now()
                .subtract(const Duration(seconds: 3))
                .microsecondsSinceEpoch *
            1000,
      };

  group('native events', () {
    test('go out as OTLP log records with their own context', () async {
      await init();
      final now = DateTime.now().microsecondsSinceEpoch * 1000;
      await fromNative('exportEvents', {
        'v': 1,
        'events': [
          {
            'name': 'journey.screen.view',
            'timeUnixNano': now,
            'attributes': {
              'session.id': 'native-session',
              'app.screen.name': 'Login.document',
              'log.record.uid': 'a' * 32,
              'otel_flutter_bridge.source': 'native',
            },
          },
          {
            'name': 'journey.action',
            'timeUnixNano': now,
            'attributes': {'journey.action.name': 'confirmLogin'},
            'traceId': traceId,
            'spanId': spanId,
            'flags': 1,
          },
          {'name': 'no time'},
          'not a map',
        ],
      });
      await settle();

      // The event without a session made Dart start one (session.start).
      final records = [
        for (final r in logs.records)
          if (attrsOf(r.attributes)['event.name'] != 'session.start') r,
      ];
      expect(records, hasLength(2));
      final view = attrsOf(records[0].attributes);
      expect(view['event.name'], 'journey.screen.view');
      expect(view['session.id'], 'native-session');
      expect(view['app.screen.name'], 'Login.document');
      expect(view['otel_flutter_bridge.source'], 'native');
      // OTLP `event_name` (field 12) survives encoding.
      final decoded = pb.LogRecord.fromBuffer(records[0].writeToBuffer());
      expect(
        utf8.decode(decoded.unknownFields.getField(12)!.lengthDelimited.single),
        'journey.screen.view',
      );

      final action = attrsOf(records[1].attributes);
      // No session from native: the current one.
      expect(action['session.id'], OtelFlutterBridge.sessionId);
      expect(action['otel_flutter_bridge.source'], 'native');
      expect(records[1].traceId, hasLength(16));
      expect(records[1].spanId, hasLength(8));
    });

    test('share requests with the Dart events (one batch, not one each)',
        () async {
      await init(delay: const Duration(minutes: 1));
      final now = DateTime.now().microsecondsSinceEpoch * 1000;
      for (var i = 0; i < 3; i++) {
        await fromNative('exportEvents', {
          'v': 1,
          'events': [
            {
              'name': 'journey.screen.view',
              'timeUnixNano': now + i,
              'attributes': {'session.id': 's', 'app.screen.name': 'n$i'},
            },
          ],
        });
      }
      Journey.screen(TScreen.home);
      await OtelFlutterBridge.flush();
      // Three native batches, the Dart screen view and session.start.
      expect(logs.requests, hasLength(1));
      expect(logs.records, hasLength(5));
    });

    test('a batch with another version is rejected whole', () {
      final batch = decodeNativeEvents({
        'v': 2,
        'events': [
          {'name': 'x', 'timeUnixNano': 1},
        ],
      });
      expect(batch.records, isEmpty);
      expect(batch.rejected, 1);
    });
  });

  group('shared journey state', () {
    test('Dart changes are mirrored on the native side', () async {
      await init();
      Journey.screen(TScreen.password);
      final run = Journey.startFlow(TFlow.login);
      Journey.setUser('u-1');
      run.end(JourneyOutcome.success);
      await settle();

      final sent = ops();
      expect(sent[0], {'op': 'screen', 'code': 'password'});
      expect(sent[1], containsPair('op', 'flowStart'));
      final wire = (sent[1] as Map)['run'] as Map;
      expect(wire['code'], 'login');
      expect(wire['instanceId'], run.instanceId);
      expect(wire['startUnixNano'], isA<int>());
      expect(sent[2], {'op': 'user', 'id': 'u-1'});
      expect(sent[3], {'op': 'flowEnd', 'instanceId': run.instanceId});
    });

    test('a flow started on a native screen ends on a Flutter one', () async {
      await init();
      await fromNative('journey', {'op': 'screen', 'code': 'Login.document'});
      await fromNative('journey', {
        'op': 'flowStart',
        'run': nativeRun('n' * 32),
      });
      await fromNative('journey', {'op': 'user', 'id': 'u-9'});
      // Applying native changes sends nothing back.
      expect(ops(), isEmpty);
      expect(AppContext.screen, 'Login.document');
      expect(AppContext.userId, 'u-9');

      final run = Journey.flowRun(TFlow.login)!;
      expect(run.instanceId, 'n' * 32);
      expect(Journey.currentFlow, same(run));
      Journey.screen(TScreen.password);
      run.end(JourneyOutcome.success);
      await settle();

      final end = events().singleWhere(
        (e) => e['event.name'] == 'journey.flow.end',
      );
      expect(end['journey.flow.instance_id'], 'n' * 32);
      expect(end['user.id'], 'u-9');
      expect(end['journey.duration_ms'], greaterThanOrEqualTo(3000));
      expect(ops().last, {'op': 'flowEnd', 'instanceId': 'n' * 32});
      expect(Journey.currentFlow, isNull);
      expect(AppContext.flowInstanceId, isNull);
    });

    test('a Dart run ended in native code is no longer open here', () async {
      await init();
      final run = Journey.startFlow(TFlow.login);
      await fromNative('journey', {
        'op': 'flowEnd',
        'instanceId': run.instanceId,
      });
      expect(run.isEnded, isTrue);
      expect(Journey.currentFlow, isNull);
      expect(AppContext.flow, isNull);

      // Ending it here too records nothing: native already did.
      final before = calls.length;
      run.end(JourneyOutcome.failure);
      await settle();
      expect(
        events().where((e) => e['event.name'] == 'journey.flow.end'),
        isEmpty,
      );
      expect(calls.length, before);
    });

    test('spans started after a native change carry it', () async {
      await init();
      await fromNative(
          'journey', {'op': 'flowStart', 'run': nativeRun('f' * 32)});
      await Journey.track(TAction.confirmLogin, () async => true);
      await settle();
      final span = traces.spans.singleWhere((s) => s.name == 'confirmLogin');
      final attrs = attrsOf(span.attributes);
      expect(attrs['journey.flow.name'], 'login');
      expect(attrs['journey.flow.instance_id'], 'f' * 32);
    });
  });

  group('ready', () {
    test('sends the Dart state and adopts the native one', () async {
      await init(ready: {
        'journey': {
          'screen': 'Login.document',
          'userId': null,
          'flows': [nativeRun('a' * 32)],
        },
        'resource': {
          'device.model.identifier': 'iPhone15,2',
          'os.version': '17.5',
          'service.name': 'not this one',
        },
      });
      final ready = calls.singleWhere((c) => c.method == 'ready');
      expect((ready.arguments as Map)['journey'], {
        'screen': null,
        'userId': null,
        'flows': <Object?>[],
      });
      expect(AppContext.screen, 'Login.document');
      expect(Journey.currentFlow?.instanceId, 'a' * 32);
      expect(AppContext.flowInstanceId, 'a' * 32);

      // What native knows about the device reaches Dart spans and events,
      // without replacing the app's own values.
      final span = OTel.tracer().startSpan('op');
      span.end();
      Journey.screen(TScreen.home);
      await settle();
      final resource = attrsOf(
          traces.requests.last.resourceSpans.single.resource.attributes);
      expect(resource['device.model.identifier'], 'iPhone15,2');
      expect(resource['os.version'], '17.5');
      expect(resource['service.name'], 'shop');
      final logResource =
          attrsOf(logs.requests.last.resourceLogs.single.resource.attributes);
      expect(logResource['device.model.identifier'], 'iPhone15,2');
    });

    test('an older native side that replies null still works', () async {
      await init();
      expect(OtelFlutterBridge.isInitialized, isTrue);
      Journey.screen(TScreen.home);
      expect(ops(), [
        {'op': 'screen', 'code': 'home'},
      ]);
    });
  });

  group('session from the host', () {
    test('Dart follows the native session', () async {
      await init(
        session: const SessionConfig(fromHost: true),
        ready: {
          'journey': {'sessionId': 'host-1', 'flows': <Object?>[]},
        },
      );
      expect(OtelFlutterBridge.sessionId, 'host-1');
      await fromNative('journey', {'op': 'session', 'id': 'host-2'});
      expect(OtelFlutterBridge.sessionId, 'host-2');
      Journey.screen(TScreen.home);
      await settle();
      expect(events().single['session.id'], 'host-2');
      // Dart starts no session of its own.
      expect(
        events().where((e) => e['event.name'] == 'session.start'),
        isEmpty,
      );
    });

    test('until the host sends one, the built-in rules apply', () async {
      await init(session: const SessionConfig(fromHost: true));
      final own = OtelFlutterBridge.sessionId!;
      expect(own, hasLength(32));
      await fromNative('journey', {'op': 'session', 'id': 'host-1'});
      expect(OtelFlutterBridge.sessionId, 'host-1');
    });

    test('without fromHost, a native session is ignored', () async {
      await init(ready: {
        'journey': {'sessionId': 'host-1'},
      });
      await fromNative('journey', {'op': 'session', 'id': 'host-2'});
      expect(OtelFlutterBridge.sessionId, isNot(anyOf('host-1', 'host-2')));
    });
  });

  test('SessionConfig.fromMap reads fromHost', () {
    expect(SessionConfig.fromMap(const {'fromHost': true}).fromHost, isTrue);
    expect(SessionConfig.fromMap(const {}).fromHost, isFalse);
  });

  test('HostSession ignores empty ids', () {
    final fallback = SessionManager(const SessionConfig());
    final host = HostSession(fallback)..set('');
    expect(host.hostId, isNull);
    expect(host.currentId, fallback.currentId);
    host.set('h');
    expect(host.currentId, 'h');
  });

  test('applyJourneyOp ignores malformed changes', () {
    applyJourneyOp('x');
    applyJourneyOp({
      'op': 'flowStart',
      'run': {'code': 'login'}
    });
    applyJourneyOp({'op': 'unknown'});
    expect(Journey.currentFlow, isNull);
  });
}
