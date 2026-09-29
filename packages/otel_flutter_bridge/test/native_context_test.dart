import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

const bridge = MethodChannel(bridgeChannelName);
const appChannel = MethodChannel('app/native');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late InMemoryTransport transport;

  Future<void> init({double sampleRatio = 1.0}) async {
    messenger.setMockMethodCallHandler(bridge, (_) async => null);
    await OtelFlutterBridge.initialize(
      OtelBridgeConfig(
        serviceName: 't',
        endpoint: Uri.parse('http://x'),
        sampleRatio: sampleRatio,
      ),
      transport: transport,
      scheduleDelay: const Duration(milliseconds: 10),
    );
  }

  setUp(() => transport = InMemoryTransport());

  tearDown(() async {
    await OtelFlutterBridge.shutdown();
    await OTel.reset();
    messenger.setMockMethodCallHandler(bridge, null);
    messenger.setMockMethodCallHandler(appChannel, null);
  });

  Map<String, String> attrs(pb.Span span) =>
      {for (final a in span.attributes) a.key: a.value.stringValue};

  pb.Span named(String name) =>
      transport.spans.singleWhere((s) => s.name == name);

  Future<void> sendNative(List<Map<String, Object?>> spans) =>
      messenger.handlePlatformMessage(
        bridgeChannelName,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('exportSpans', {'v': 1, 'spans': spans}),
        ),
        (_) {},
      );

  Map<String, Object?> nativeSpan(String traceId, String spanId, String name) =>
      {
        'traceId': traceId,
        'spanId': spanId,
        'name': name,
        'startTimeUnixNano': 1,
        'endTimeUnixNano': 2,
      };

  group('Dart → native', () {
    test('invokeTraced sends screen and flow with traceparent', () async {
      await init();
      Map<Object?, Object?>? otel;
      messenger.setMockMethodCallHandler(appChannel, (call) async {
        otel = (call.arguments as Map)[channelContextKey] as Map?;
        return null;
      });
      AppContext.screen = 'checkout.review';
      AppContext.flow = 'purchase';
      final tracer = OTel.tracer();
      final span = tracer.startSpan('checkout.confirm');
      AppContext.screen = 'home'; // navigated before the call
      await tracer.withSpanAsync(span, () => appChannel.invokeTraced('pay'));
      span.end();

      expect(otel![Traceparent.header], isNotNull);
      expect(otel![appScreenKey], 'checkout.review');
      expect(otel![appFlowKey], 'purchase');
    });

    test('no screen or flow, only traceparent', () async {
      await init();
      Map<Object?, Object?>? otel;
      messenger.setMockMethodCallHandler(appChannel, (call) async {
        otel = (call.arguments as Map)[channelContextKey] as Map?;
        return null;
      });
      await appChannel.invokeTraced<void>('pay');
      expect(otel!.keys, [Traceparent.header]);
    });
  });

  group('native → Dart', () {
    const traceId = '0af7651916cd43dd8448eb211c80319c';
    const parentId = 'b7ad6b7169203331';

    test('continues the native trace with its screen and flow', () async {
      await init();
      AppContext.screen = 'flutter.home';
      final args = {
        'orderId': 'x',
        channelContextKey: {
          Traceparent.header: '00-$traceId-$parentId-01',
          appScreenKey: 'Extrato',
          appFlowKey: 'statement',
        },
      };
      final tracer = OTel.tracer();
      await runWithTraceContext(args, () async {
        final span = tracer.startSpan('statement.sync');
        await tracer.withSpanAsync(span, () async {
          AppContext.screen = 'elsewhere';
          tracer.startSpan('statement.parse').end();
        });
        span.end();
      });
      await OtelFlutterBridge.flush();

      final sync = named('statement.sync');
      final parse = named('statement.parse');
      expect(_hex(sync.traceId), traceId);
      expect(_hex(sync.parentSpanId), parentId);
      expect(parse.parentSpanId, sync.spanId);
      expect(attrs(sync), containsPair('app.screen', 'Extrato'));
      expect(attrs(sync), containsPair('app.flow', 'statement'));
      expect(attrs(parse), containsPair('app.screen', 'Extrato'));
    });

    test('without context, just runs; malformed context is ignored', () async {
      await init();
      expect(await runWithTraceContext(null, () async => 1), 1);
      expect(
        await runWithTraceContext({
          channelContextKey: {Traceparent.header: 'garbage'},
        }, () async => 2),
        2,
      );
      expect(
        await runWithTraceContext({channelContextKey: 'x'}, () async => 3),
        3,
      );
    });

    test('errors from fn reach the caller unchanged', () async {
      await init();
      await expectLater(
        runWithTraceContext(
          {
            channelContextKey: {
              Traceparent.header: '00-$traceId-$parentId-01',
            },
          },
          () async => throw StateError('x'),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('setTracedMethodCallHandler', () {
    const traceId = '0af7651916cd43dd8448eb211c80319c';
    const parentId = 'b7ad6b7169203331';

    Future<ByteData?> callFromNative(String method, Object? args) {
      final completer = Completer<ByteData?>();
      messenger.handlePlatformMessage(
        appChannel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        completer.complete,
      );
      return completer.future;
    }

    test('server span continues the native trace; handler spans are children',
        () async {
      await init();
      appChannel.setTracedMethodCallHandler((call) async {
        OTel.tracer().startSpan('saldo.changed').end();
        return 'ok';
      });
      final reply = await callFromNative('saldoAtualizado', {
        channelContextKey: {
          Traceparent.header: '00-$traceId-$parentId-01',
          appScreenKey: 'Extrato',
        },
      });
      expect(const StandardMethodCodec().decodeEnvelope(reply!), 'ok');
      await OtelFlutterBridge.flush();

      final server = named('app/native/saldoAtualizado');
      final child = named('saldo.changed');
      expect(server.kind, pb.Span_SpanKind.SPAN_KIND_SERVER);
      expect(_hex(server.traceId), traceId);
      expect(_hex(server.parentSpanId), parentId);
      expect(child.parentSpanId, server.spanId);
      expect(attrs(server), containsPair('rpc.method', 'saldoAtualizado'));
      expect(attrs(child), containsPair('app.screen', 'Extrato'));
    });

    test('errors mark the span and reach native code', () async {
      await init();
      appChannel.setTracedMethodCallHandler(
        (call) async => throw PlatformException(code: 'saldo_invalido'),
      );
      final reply = await callFromNative('saldoAtualizado', null);
      expect(
        () => const StandardMethodCodec().decodeEnvelope(reply!),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'saldo_invalido')),
      );
      await OtelFlutterBridge.flush();
      final server = named('app/native/saldoAtualizado');
      expect(server.parentSpanId, isEmpty);
      expect(server.status.code, pb.Status_StatusCode.STATUS_CODE_ERROR);
      expect(attrs(server), containsPair('error.type', 'PlatformException'));
    });
  });

  group('sampling native spans', () {
    // Trace ids whose last 8 bytes put them at the bottom and top of the
    // ratio range.
    const low = '0000000000000000000000000000000a';
    const high = '0000000000000000fffffffffffffff0';

    test('ratio 1 keeps everything', () async {
      await init();
      await sendNative([
        nativeSpan(low, '1111111111111111', 'a'),
        nativeSpan(high, '2222222222222222', 'b'),
      ]);
      await OtelFlutterBridge.flush();
      expect(transport.spans.map((s) => s.name), unorderedEquals(['a', 'b']));
    });

    test('native roots follow the same trace id ratio as Dart', () async {
      await init(sampleRatio: 0.5);
      await sendNative([
        nativeSpan(low, '1111111111111111', 'kept'),
        nativeSpan(high, '2222222222222222', 'dropped'),
      ]);
      await OtelFlutterBridge.flush();
      expect(transport.spans.map((s) => s.name), ['kept']);
    });

    test('native children of a sampled Dart trace are kept', () async {
      await init(sampleRatio: 0.5);
      final tracer = OTel.tracer();
      // Start Dart roots until the sampler keeps one.
      late Span root;
      for (var i = 0; i < 100; i++) {
        final s = tracer.startSpan('root');
        if (s.spanContext.traceFlags.isSampled) {
          root = s;
          break;
        }
        s.end();
      }
      final traceId = root.spanContext.traceId.hexString;
      root.end();
      await sendNative([
        {
          ...nativeSpan(traceId, '3333333333333333', 'native.child'),
          'parentSpanId': root.spanContext.spanId.hexString,
        },
      ]);
      await OtelFlutterBridge.flush();
      expect(transport.spans.map((s) => s.name),
          containsAll(['root', 'native.child']));
    });
  });
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
