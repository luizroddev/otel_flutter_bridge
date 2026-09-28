// Sends real spans to a local Jaeger and reads them back from its API.
//
//   docker compose up -d
//   OTEL_JAEGER_TEST=1 flutter test test/integration/jaeger_test.dart
@Tags(['jaeger'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

final _enabled = Platform.environment['OTEL_JAEGER_TEST'] == '1';

void main() {
  test('trace reaches Jaeger with session, hierarchy and redaction', () async {
    final service = 'otel-bridge-it-${DateTime.now().millisecondsSinceEpoch}';
    await OtelFlutterBridge.initialize(
      OtelBridgeConfig(
        serviceName: service,
        endpoint: Uri.parse('http://localhost:4318'),
      ),
      connectNative: false,
      scheduleDelay: const Duration(milliseconds: 50),
    );

    final tracer = OTel.tracer();
    final root = tracer.startSpan('it.root');
    await tracer.withSpanAsync(root, () async {
      tracer
          .startSpan(
            'it.child',
            attributes: OTel.attributesFromMap({
              'app.step': 'child',
              'user.email': 'ana@example.com',
            }),
          )
          .end();
    });
    root.end();

    // A native batch in the same trace, as the iOS side would send it.
    final batch = decodeNativeBatch({
      'v': 1,
      'spans': [
        {
          'traceId': root.spanContext.traceId.hexString,
          'spanId': 'abcdefabcdef0001',
          'parentSpanId': root.spanContext.spanId.hexString,
          'name': 'it.native',
          'startTimeUnixNano': DateTime.now().microsecondsSinceEpoch * 1000,
          'endTimeUnixNano':
              DateTime.now().microsecondsSinceEpoch * 1000 + 1000,
        },
      ],
    });
    OtelFlutterBridge.pipeline!.submitNative(batch.resourceSpans!);
    await OtelFlutterBridge.flush();

    final traceId = root.spanContext.traceId.hexString;
    Map<String, Object?>? trace;
    for (var i = 0; i < 20 && trace == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      trace = await _fetchTrace(traceId);
    }
    expect(trace, isNotNull, reason: 'trace $traceId not found in Jaeger');

    final spans = (trace!['spans']! as List).cast<Map<String, Object?>>();
    final byName = {for (final s in spans) s['operationName']: s};
    expect(byName.keys, containsAll(['it.root', 'it.child', 'it.native']));

    String? parentOf(Map<String, Object?> s) {
      final refs = (s['references'] as List?) ?? const [];
      return refs.isEmpty ? null : (refs.first as Map)['spanID'] as String?;
    }

    final rootId = byName['it.root']!['spanID'];
    expect(parentOf(byName['it.child']!), rootId);
    expect(parentOf(byName['it.native']!), rootId);

    Map<String, Object?> tags(Map<String, Object?> s) => {
          for (final t in (s['tags']! as List).cast<Map<String, Object?>>())
            t['key']! as String: t['value'],
        };
    final childTags = tags(byName['it.child']!);
    expect(childTags['app.step'], 'child');
    expect(childTags.containsKey('user.email'), isFalse);
    final sessions = spans.map((s) => tags(s)[sessionIdKey]).toSet();
    expect(sessions, {OtelFlutterBridge.sessionId});

    await OtelFlutterBridge.shutdown();
  }, skip: _enabled ? false : 'set OTEL_JAEGER_TEST=1 with Jaeger running');
}

Future<Map<String, Object?>?> _fetchTrace(String traceId) async {
  final client = HttpClient();
  try {
    final req = await client
        .getUrl(Uri.parse('http://localhost:16686/api/traces/$traceId'));
    final res = await req.close();
    if (res.statusCode != 200) return null;
    final body = jsonDecode(await res.transform(utf8.decoder).join())
        as Map<String, Object?>;
    final data = body['data'] as List?;
    if (data == null || data.isEmpty) return null;
    final trace = data.first as Map<String, Object?>;
    return (trace['spans'] as List).length >= 3 ? trace : null;
  } finally {
    client.close();
  }
}
