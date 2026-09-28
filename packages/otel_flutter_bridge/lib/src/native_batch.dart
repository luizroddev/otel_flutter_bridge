import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:fixnum/fixnum.dart';

import 'semantics.dart';

/// Result of decoding a native batch.
class DecodedNativeBatch {
  /// Creates a result.
  const DecodedNativeBatch(this.resourceSpans, this.accepted, this.rejected);

  /// Spans grouped by scope, ready to be merged into an export request.
  final pb.ResourceSpans? resourceSpans;

  /// Spans that were decoded.
  final int accepted;

  /// Spans that were malformed and skipped.
  final int rejected;
}

/// Decodes the native to Dart batch format, version
/// [nativeBatchFormatVersion]. See `docs/specs/native-bridge.md`.
///
/// Never throws: malformed spans are skipped and counted, and a batch with an
/// unknown version is rejected as a whole.
DecodedNativeBatch decodeNativeBatch(Object? payload) {
  if (payload is! Map) return const DecodedNativeBatch(null, 0, 0);
  final spans = payload['spans'];
  final spanCount = spans is List ? spans.length : 0;
  if (payload['v'] != nativeBatchFormatVersion || spans is! List) {
    return DecodedNativeBatch(null, 0, spanCount);
  }

  final byScope = <String, pb.ScopeSpans>{};
  var rejected = 0;
  for (final raw in spans) {
    final span = raw is Map ? _decodeSpan(raw) : null;
    if (span == null) {
      rejected++;
      continue;
    }
    final scope = raw['scope'] is Map ? raw['scope'] as Map : const {};
    final name = scope['name'] is String ? scope['name'] as String : 'native';
    final version =
        scope['version'] is String ? scope['version'] as String : '';
    byScope
        .putIfAbsent(
          '$name@$version',
          () => pb.ScopeSpans(
            scope: pb.InstrumentationScope(name: name, version: version),
          ),
        )
        .spans
        .add(span);
  }

  final accepted = spanCount - rejected;
  if (accepted == 0) return DecodedNativeBatch(null, 0, rejected);
  return DecodedNativeBatch(
    pb.ResourceSpans(
      resource: pb.Resource(attributes: _attributes(payload['resource'])),
      scopeSpans: byScope.values,
    ),
    accepted,
    rejected,
  );
}

pb.Span? _decodeSpan(Map<Object?, Object?> m) {
  final traceId = _hex(m['traceId'], 16);
  final spanId = _hex(m['spanId'], 8);
  final name = m['name'];
  final start = m['startTimeUnixNano'];
  final end = m['endTimeUnixNano'];
  if (traceId == null || spanId == null || name is! String) return null;
  if (start is! int || end is! int || end < start) return null;

  final span = pb.Span(
    traceId: traceId,
    spanId: spanId,
    name: name,
    kind: _kind(m['kind']),
    startTimeUnixNano: Int64(start),
    endTimeUnixNano: Int64(end),
    attributes: _attributes(m['attributes']),
    flags: m['flags'] is int ? m['flags'] as int : 1,
  );
  final parent = _hex(m['parentSpanId'], 8);
  if (parent != null) span.parentSpanId = parent;

  final status = m['status'];
  if (status is Map) {
    span.status = pb.Status(
      code: switch (status['code']) {
        'ok' => pb.Status_StatusCode.STATUS_CODE_OK,
        'error' => pb.Status_StatusCode.STATUS_CODE_ERROR,
        _ => pb.Status_StatusCode.STATUS_CODE_UNSET,
      },
      message: status['message'] is String ? status['message'] as String : '',
    );
  }

  final events = m['events'];
  if (events is List) {
    for (final e in events.whereType<Map<Object?, Object?>>()) {
      final eName = e['name'];
      final time = e['timeUnixNano'];
      if (eName is! String || time is! int) continue;
      span.events.add(
        pb.Span_Event(
          name: eName,
          timeUnixNano: Int64(time),
          attributes: _attributes(e['attributes']),
        ),
      );
    }
  }

  final links = m['links'];
  if (links is List) {
    for (final l in links.whereType<Map<Object?, Object?>>()) {
      final lTrace = _hex(l['traceId'], 16);
      final lSpan = _hex(l['spanId'], 8);
      if (lTrace == null || lSpan == null) continue;
      span.links.add(
        pb.Span_Link(
          traceId: lTrace,
          spanId: lSpan,
          attributes: _attributes(l['attributes']),
        ),
      );
    }
  }
  return span;
}

pb.Span_SpanKind _kind(Object? v) => switch (v) {
      'server' => pb.Span_SpanKind.SPAN_KIND_SERVER,
      'client' => pb.Span_SpanKind.SPAN_KIND_CLIENT,
      'producer' => pb.Span_SpanKind.SPAN_KIND_PRODUCER,
      'consumer' => pb.Span_SpanKind.SPAN_KIND_CONSUMER,
      _ => pb.Span_SpanKind.SPAN_KIND_INTERNAL,
    };

List<pb.KeyValue> _attributes(Object? raw) {
  if (raw is! Map) return [];
  final out = <pb.KeyValue>[];
  for (final e in raw.entries) {
    final key = e.key;
    final value = _anyValue(e.value);
    if (key is String && value != null) {
      out.add(pb.KeyValue(key: key, value: value));
    }
  }
  return out;
}

pb.AnyValue? _anyValue(Object? v) => switch (v) {
      final String s => pb.AnyValue(stringValue: s),
      final bool b => pb.AnyValue(boolValue: b),
      final int i => pb.AnyValue(intValue: Int64(i)),
      final double d => pb.AnyValue(doubleValue: d),
      final List<Object?> l => pb.AnyValue(
          arrayValue: pb.ArrayValue(values: l.map(_anyValue).nonNulls),
        ),
      _ => null,
    };

final _hexPattern = RegExp(r'^[0-9a-f]+$');

List<int>? _hex(Object? v, int bytes) {
  if (v is! String || v.length != bytes * 2) return null;
  final s = v.toLowerCase();
  if (!_hexPattern.hasMatch(s) || s == '0' * s.length) return null;
  return [
    for (var i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ];
}
