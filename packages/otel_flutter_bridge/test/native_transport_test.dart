import 'dart:io' show gzip;

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

const bridge = MethodChannel(bridgeChannelName);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> exports;

  /// Native side: records `export` calls and replies [accepted].
  void nativeSide({Object? accepted = true}) {
    exports = [];
    messenger.setMockMethodCallHandler(bridge, (call) async {
      if (call.method != 'export') return null;
      exports.add(call);
      return accepted;
    });
  }

  tearDown(() async {
    await OtelFlutterBridge.shutdown();
    await OTel.reset();
    messenger.setMockMethodCallHandler(bridge, null);
  });

  final request = pb.ExportTraceServiceRequest(
    resourceSpans: [
      pb.ResourceSpans(
        scopeSpans: [
          pb.ScopeSpans(spans: [pb.Span(name: 'op')]),
        ],
      ),
    ],
  );

  group('NativeExport', () {
    test('hands the encoded request to native code', () async {
      nativeSide();
      final export = NativeExport(
        'traces',
        Uri.parse('https://collector.example.com/v1/traces'),
        headers: {'X-App': 'shop'},
      );
      expect(await NativeTraceTransport(export).send(request), isTrue);
      final args = exports.single.arguments as Map;
      expect(args['signal'], 'traces');
      expect(args['url'], 'https://collector.example.com/v1/traces');
      expect(args['headers'], {
        'X-App': 'shop',
        'Content-Type': 'application/x-protobuf',
      });
      expect(
        pb.ExportTraceServiceRequest.fromBuffer(args['body'] as Uint8List),
        request,
      );
    });

    test('gzip compresses the body and says so', () async {
      nativeSide();
      final export = NativeExport('logs', Uri.parse('http://x'), gzip: true);
      await NativeLogTransport(export).send(pb.ExportLogsServiceRequest());
      final args = exports.single.arguments as Map;
      expect((args['headers'] as Map)['Content-Encoding'], 'gzip');
      expect(gzip.decode(args['body'] as Uint8List), isEmpty);
    });

    test('a refusal, no handler or no native side is a failure', () async {
      nativeSide(accepted: false);
      final export = NativeExport('traces', Uri.parse('http://x'));
      expect(await export.send([1]), isFalse);
      nativeSide(accepted: null);
      expect(await export.send([1]), isFalse);
      messenger.setMockMethodCallHandler(bridge, null);
      expect(await export.send([1]), isFalse);
    });

    test('no reply in time is a failure', () async {
      messenger.setMockMethodCallHandler(bridge, (_) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        return true;
      });
      final export = NativeExport(
        'traces',
        Uri.parse('http://x'),
        timeout: const Duration(milliseconds: 20),
      );
      expect(await export.send([1]), isFalse);
    });
  });

  test('sendThroughNative: spans and events go out through native code',
      () async {
    nativeSide();
    await OtelFlutterBridge.initialize(
      OtelBridgeConfig(
        serviceName: 'shop',
        endpoint: Uri.parse('https://collector.example.com'),
        sendThroughNative: true,
      ),
      scheduleDelay: const Duration(milliseconds: 10),
    );
    OTel.tracer().startSpan('cart.load').end();
    Journey.screenNamed('home');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await OtelFlutterBridge.flush();

    final bySignal = {
      for (final c in exports) (c.arguments as Map)['signal']: c.arguments,
    };
    expect(bySignal.keys, containsAll(['traces', 'logs']));
    expect(
      (bySignal['logs'] as Map)['url'],
      'https://collector.example.com/v1/logs',
    );
    final traces = pb.ExportTraceServiceRequest.fromBuffer(
      (bySignal['traces'] as Map)['body'] as Uint8List,
    );
    expect(
      traces.resourceSpans.expand((r) => r.scopeSpans).expand((s) => s.spans),
      contains(predicate<pb.Span>((s) => s.name == 'cart.load')),
    );
  });

  test('OtlpHttpTransport with gzip', () async {
    late http.Request sent;
    final transport = OtlpHttpTransport(
      Uri.parse('http://x/v1/traces'),
      gzip: true,
      client: MockClient((r) async {
        sent = r;
        return http.Response('', 200);
      }),
    );
    expect(await transport.send(request), isTrue);
    expect(sent.headers['Content-Encoding'], 'gzip');
    expect(
      pb.ExportTraceServiceRequest.fromBuffer(gzip.decode(sent.bodyBytes)),
      request,
    );
  });

  test('config reads sendThroughNative and gzip', () {
    final c = OtelBridgeConfig.fromMap(const {
      'endpoint': 'http://x',
      'sendThroughNative': true,
      'gzip': true,
    });
    expect(c.sendThroughNative, isTrue);
    expect(c.gzip, isTrue);
    final d = OtelBridgeConfig.fromMap(const {'endpoint': 'http://x'});
    expect(d.sendThroughNative, isFalse);
    expect(d.gzip, isFalse);
  });
}
