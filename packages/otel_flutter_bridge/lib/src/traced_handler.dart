import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

/// Adds attributes to a [tracedHandler] span from the handler's first
/// argument (for a Bloc, the event). Keys must be allowed by the redaction
/// config (for example `app.*`), or they are dropped before export.
typedef TracedHandlerEnricher<A> = void Function(Span span, A first);

/// Wraps a two-argument callback so each call runs inside a span named
/// [name]. Made for Bloc event handlers, without depending on `bloc`:
///
/// ```dart
/// on<LoadOrders>(tracedHandler('orders.load', _onLoadOrders));
/// ```
///
/// The span is active while [handler] runs, so spans created inside it
/// (HTTP through `OtelHttpClient` or dio, `invokeTraced`, manual spans)
/// become its children. A Bloc runs handlers in the zone where the Bloc was
/// created, not where `add` was called, so the handler span is usually the
/// root of its trace.
///
/// [name] must be a fixed, low-cardinality string such as `orders.load`.
/// Do not derive it from `runtimeType`: it is obfuscated in release builds
/// built with `--obfuscate`.
///
/// The arguments are never read or recorded. Use [enrich] to add safe,
/// low-cardinality values from the first argument (enums, booleans).
///
/// When [handler] throws, the span records the exception and gets
/// `error.type`, and the same error is rethrown, so the caller (for a Bloc,
/// `onError`) sees exactly what it would without tracing. When telemetry is
/// not initialized, [handler] runs untraced.
Future<void> Function(A, B) tracedHandler<A, B>(
  String name,
  FutureOr<void> Function(A, B) handler, {
  TracedHandlerEnricher<A>? enrich,
  Tracer? tracer,
}) {
  return (a, b) async {
    Tracer? t;
    Span? span;
    try {
      t = tracer ?? OTel.tracer();
      span = t.startSpan(name);
    } catch (_) {
      // Telemetry never breaks the app: run untraced.
    }
    if (t == null || span == null) {
      await handler(a, b);
      return;
    }
    try {
      enrich?.call(span, a);
    } catch (_) {
      // Telemetry never breaks the app.
    }
    // The handler error is caught inside the span and rethrown outside it,
    // so it does not go through the SDK's own error path, which prints the
    // exception text (possibly personal data) to the device log.
    Object? error;
    StackTrace? stackTrace;
    var ran = false;
    try {
      await t.withSpanAsync(span, () async {
        ran = true;
        try {
          await handler(a, b);
        } catch (e, st) {
          error = e;
          stackTrace = st;
        }
      });
    } catch (_) {
      // Telemetry never breaks the app: if the span could not be activated,
      // the handler still runs, untraced.
      if (!ran) {
        _end(span);
        await handler(a, b);
        return;
      }
    }
    final e = error;
    if (e != null) _markError(span, e, stackTrace!);
    _end(span);
    if (e != null) Error.throwWithStackTrace(e, stackTrace!);
  };
}

void _markError(Span span, Object error, StackTrace stackTrace) {
  try {
    final type = error.runtimeType.toString();
    span
      ..recordException(error, stackTrace: stackTrace)
      ..setStringAttribute('error.type', type)
      ..setStatus(SpanStatusCode.Error, type);
  } catch (_) {
    // Telemetry never breaks the app.
  }
}

void _end(Span span) {
  try {
    span.end();
  } catch (_) {
    // Telemetry never breaks the app.
  }
}
