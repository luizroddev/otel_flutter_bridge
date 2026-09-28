import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

class FixedSession implements SessionIdProvider {
  @override
  String get currentId => 'fixedsession';
}

class ThrowingTransport implements TraceTransport {
  @override
  Future<bool> send(pb.ExportTraceServiceRequest request) =>
      throw StateError('network down');
  @override
  Future<void> close() async {}
}

pb.ExportTraceServiceRequest requestWith(int spans) =>
    pb.ExportTraceServiceRequest(
      resourceSpans: [
        pb.ResourceSpans(
          resource: pb.Resource(),
          scopeSpans: [
            pb.ScopeSpans(
              scope: pb.InstrumentationScope(name: 's'),
              spans: [
                for (var i = 0; i < spans; i++)
                  pb.Span(
                    name: 'span $i',
                    attributes: [
                      pb.KeyValue(
                        key: 'user.email',
                        value: pb.AnyValue(stringValue: 'a@b.com'),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ],
    );

void main() {
  late InMemoryTransport transport;
  late List<BridgeDiagnostic> diagnostics;

  TelemetryPipeline build({
    TraceTransport? t,
    BridgeLimits limits = const BridgeLimits(),
    List<SpanEnricher> enrichers = const [],
  }) =>
      TelemetryPipeline(
        transport: t ?? transport,
        redactor: Redactor(const RedactionConfig()),
        session: FixedSession(),
        limits: limits,
        enrichers: enrichers,
        commonResource: [
          pb.KeyValue(
            key: 'service.name',
            value: pb.AnyValue(stringValue: 'svc'),
          ),
        ],
        onDiagnostic: diagnostics.add,
      );

  setUp(() {
    transport = InMemoryTransport();
    diagnostics = [];
  });

  test('stamps session and source, then redacts', () async {
    final p = build();
    p.submitDart(requestWith(1));
    await p.flush();
    final span = transport.spans.single;
    final attrs = {for (final a in span.attributes) a.key: a.value.stringValue};
    expect(attrs, {sessionIdKey: 'fixedsession', bridgeSourceKey: 'dart'});
    expect(span.droppedAttributesCount, 1);
  });

  test('native spans get the common resource and the native source', () async {
    final p = build();
    p.submitNative(requestWith(1).resourceSpans.single);
    await p.flush();
    final rs = transport.requests.single.resourceSpans.single;
    expect(rs.resource.attributes.single.key, 'service.name');
    expect(
      transport.spans.single.attributes
          .firstWhere((a) => a.key == bridgeSourceKey)
          .value
          .stringValue,
      bridgeSourceNative,
    );
  });

  test('enrichers run before redaction', () async {
    final p = build(
      enrichers: [
        (span, origin) => span.attributes.addAll([
              pb.KeyValue(
                key: 'app.flow',
                value: pb.AnyValue(stringValue: 'login'),
              ),
              pb.KeyValue(
                key: 'not.allowed',
                value: pb.AnyValue(stringValue: 'x'),
              ),
            ]),
      ],
    );
    p.submitDart(requestWith(1));
    await p.flush();
    final keys = transport.spans.single.attributes.map((a) => a.key);
    expect(keys, contains('app.flow'));
    expect(keys, isNot(contains('not.allowed')));
  });

  test('splits large requests', () async {
    final p = build(limits: const BridgeLimits(maxSpansPerExport: 2));
    p.submitDart(requestWith(5));
    await p.flush();
    expect(
        transport.requests
            .map((r) => r.resourceSpans.single.scopeSpans.single.spans.length),
        [2, 2, 1]);
  });

  test('drops the oldest request when the queue is full', () async {
    final p = build(
      limits: const BridgeLimits(maxQueuedBatches: 2, maxSpansPerExport: 1),
    );
    p.submitDart(requestWith(5));
    await p.flush();
    expect(transport.spans.map((s) => s.name), ['span 3', 'span 4']);
    expect(
      diagnostics.where((d) => d.kind == BridgeDiagnosticKind.queueFull),
      hasLength(3),
    );
  });

  test('does nothing while disabled', () async {
    final p = build()..enabled = false;
    p.submitDart(requestWith(1));
    await p.flush();
    expect(transport.requests, isEmpty);
  });

  group('failure never reaches the app', () {
    test('transport throwing', () async {
      final p = build(t: ThrowingTransport());
      p.submitDart(requestWith(1));
      await p.flush();
      expect(diagnostics.single.kind, BridgeDiagnosticKind.exportFailed);
    });

    test('transport rejecting', () async {
      transport.succeed = false;
      final p = build();
      p.submitDart(requestWith(1));
      await p.flush();
      expect(diagnostics.single.kind, BridgeDiagnosticKind.exportFailed);
    });

    test('enricher throwing drops the data', () async {
      final p = build(enrichers: [(_, __) => throw StateError('bug')]);
      p.submitDart(requestWith(1));
      await p.flush();
      expect(transport.requests, isEmpty);
      expect(diagnostics.single.kind, BridgeDiagnosticKind.internalError);
    });

    test('diagnostic listener throwing', () async {
      final p = TelemetryPipeline(
        transport: ThrowingTransport(),
        redactor: Redactor(const RedactionConfig()),
        session: FixedSession(),
        limits: const BridgeLimits(),
        onDiagnostic: (_) => throw StateError('bad listener'),
      );
      p.submitDart(requestWith(1));
      await p.flush();
    });
  });

  test('records stream shows what was sent, after redaction', () async {
    final p = build();
    final records = <ExportRecord>[];
    p.records.listen(records.add);
    p.submitDart(requestWith(2));
    await p.flush();
    await Future<void>.delayed(Duration.zero);
    expect(records.single.success, isTrue);
    expect(records.single.origin, SpanOrigin.dart);
    expect(records.single.spans, hasLength(2));
    expect(
      records.single.spans.expand((s) => s.attributes).map((a) => a.key),
      isNot(contains('user.email')),
    );
  });
}
