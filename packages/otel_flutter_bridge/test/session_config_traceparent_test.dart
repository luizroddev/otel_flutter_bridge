import 'dart:math';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

void main() {
  group('SessionManager', () {
    late DateTime now;
    late SessionManager session;

    setUp(() {
      now = DateTime(2026, 1, 1, 10);
      session = SessionManager(
        const SessionConfig(
          inactivityTimeout: Duration(minutes: 30),
          maxDuration: Duration(hours: 4),
        ),
        clock: () => now,
        random: Random(1),
      );
    });

    test('id is 32 lowercase hex characters', () {
      expect(session.currentId, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('keeps the id while there is activity', () {
      final id = session.currentId;
      now = now.add(const Duration(minutes: 29));
      expect(session.currentId, id);
      now = now.add(const Duration(minutes: 29));
      expect(session.currentId, id);
    });

    test('starts a new session after inactivity', () {
      final id = session.currentId;
      now = now.add(const Duration(minutes: 30));
      expect(session.currentId, isNot(id));
    });

    test('starts a new session after the maximum duration', () {
      final id = session.currentId;
      for (var i = 0; i < 16; i++) {
        now = now.add(const Duration(minutes: 15));
        session.currentId;
      }
      expect(session.currentId, isNot(id));
    });

    test('reset forces a new session', () {
      final id = session.currentId;
      session.reset();
      expect(session.currentId, isNot(id));
    });
  });

  group('OtelBridgeConfig', () {
    test('appends /v1/traces to the endpoint', () {
      OtelBridgeConfig c(String e) =>
          OtelBridgeConfig(serviceName: 's', endpoint: Uri.parse(e));
      expect(c('http://h:4318').tracesEndpoint.toString(),
          'http://h:4318/v1/traces');
      expect(c('http://h:4318/').tracesEndpoint.toString(),
          'http://h:4318/v1/traces');
      expect(c('http://h/otel/v1/traces').tracesEndpoint.toString(),
          'http://h/otel/v1/traces');
    });

    test('fromMap reads values and falls back on invalid ones', () {
      final c = OtelBridgeConfig.fromMap({
        'serviceName': 'poc-app',
        'endpoint': 'https://collector.example.com',
        'enabled': false,
        'sampleRatio': 7,
        'headers': {'x-a': 'b', 'x-bad': 1},
        'session': {'inactivityTimeoutMs': 60000, 'maxDurationMs': -1},
        'limits': {'maxQueuedBatches': 'x', 'maxSpansPerExport': 10},
        'redaction': {
          'allowedPrefixes': ['poc.']
        },
      });
      expect(c.serviceName, 'poc-app');
      expect(c.enabled, isFalse);
      expect(c.sampleRatio, 1);
      expect(c.headers, {'x-a': 'b'});
      expect(c.session.inactivityTimeout, const Duration(minutes: 1));
      expect(c.session.maxDuration, const Duration(hours: 4));
      expect(c.limits.maxQueuedBatches, 32);
      expect(c.limits.maxSpansPerExport, 10);
      expect(c.redaction.allowedPrefixes, {'poc.'});
    });

    test('fromMap on an empty map does not throw', () {
      final c = OtelBridgeConfig.fromMap({});
      expect(c.serviceName, 'unknown_service');
      expect(c.enabled, isTrue);
    });
  });

  group('Traceparent', () {
    test('parses a valid header', () {
      final v = Traceparent.parse(
        '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
      )!;
      expect(v.traceId, '4bf92f3577b34da6a3ce929d0e0e4736');
      expect(v.spanId, '00f067aa0ba902b7');
      expect(v.sampled, isTrue);
    });

    test('rejects malformed, zero and ff headers', () {
      for (final bad in [
        null,
        '',
        'garbage',
        '00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01',
        '00-00000000000000000000000000000000-00f067aa0ba902b7-01',
        '00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01',
        'ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
        '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7',
      ]) {
        expect(Traceparent.parse(bad), isNull, reason: bad);
      }
    });

    test('formats a span context', () async {
      await OTel.initialize(
        serviceName: 't',
        enableMetrics: false,
        enableLogs: false,
        detectPlatformResources: false,
        spanProcessor: SimpleSpanProcessor(_NoopExporter()),
      );
      addTearDown(OTel.reset);
      final span = OTel.tracer().startSpan('x');
      final value = Traceparent.format(span.spanContext)!;
      final parsed = Traceparent.parse(value)!;
      expect(parsed.traceId, span.spanContext.traceId.hexString);
      expect(parsed.spanId, span.spanContext.spanId.hexString);
      expect(Traceparent.format(null), isNull);
      span.end();
    });
  });
}

class _NoopExporter implements SpanExporter {
  @override
  Future<void> export(List<Span> spans) async {}
  @override
  Future<void> forceFlush() async {}
  @override
  Future<void> shutdown() async {}
}
