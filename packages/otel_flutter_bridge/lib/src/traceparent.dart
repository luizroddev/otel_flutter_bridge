import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

/// Formats and parses the W3C Trace Context `traceparent` header.
/// https://www.w3.org/TR/trace-context/#traceparent-header
abstract final class Traceparent {
  static final _pattern = RegExp(
    r'^([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$',
  );

  /// Header name.
  static const header = 'traceparent';

  /// The `traceparent` value for [spanContext], or null when it is invalid.
  static String? format(SpanContext? spanContext) {
    if (spanContext == null || !spanContext.isValid) return null;
    return '00-${spanContext.traceId.hexString}-'
        '${spanContext.spanId.hexString}-${spanContext.traceFlags}';
  }

  /// The `traceparent` value for the span active in [context] (defaults to
  /// the current context), or null when there is none.
  static String? fromContext([Context? context]) {
    final ctx = context ?? Context.current;
    return format(ctx.span?.spanContext ?? ctx.spanContext);
  }

  /// Parses a `traceparent` value. Returns null when it is malformed,
  /// uses the all-zero trace or span id, or version `ff`.
  static TraceparentValue? parse(String? value) {
    if (value == null) return null;
    final m = _pattern.firstMatch(value.trim());
    if (m == null) return null;
    final version = m.group(1)!;
    final traceId = m.group(2)!;
    final spanId = m.group(3)!;
    if (version == 'ff') return null;
    if (traceId == '0' * 32 || spanId == '0' * 16) return null;
    return TraceparentValue(
      traceId: traceId,
      spanId: spanId,
      flags: int.parse(m.group(4)!, radix: 16),
    );
  }
}

/// A parsed `traceparent`.
class TraceparentValue {
  /// Creates a parsed value.
  const TraceparentValue({
    required this.traceId,
    required this.spanId,
    required this.flags,
  });

  /// 32 lowercase hex characters.
  final String traceId;

  /// 16 lowercase hex characters.
  final String spanId;

  /// Trace flags. Bit 0 is `sampled`.
  final int flags;

  /// Whether the sampled flag is set.
  bool get sampled => flags & 1 == 1;
}
