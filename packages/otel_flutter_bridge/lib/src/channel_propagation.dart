import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/services.dart';

import 'app_context.dart';
import 'semantics.dart';
import 'span_errors.dart';
import 'traceparent.dart';

/// Returns a copy of [arguments] carrying the trace context of [context]
/// (defaults to the current one) under [channelContextKey], with the
/// span's `app.screen` / `app.flow` so native children carry them too.
///
/// The native side reads it with `OtelFlutterBridge.shared.startSpan` or
/// `extractContext`. When there is no active span, [arguments] is returned
/// unchanged.
Map<String, Object?> withTraceContext(
  Map<String, Object?>? arguments, [
  Context? context,
]) {
  final args = <String, Object?>{...?arguments};
  final ctx = context ?? Context.current;
  final traceparent = Traceparent.fromContext(ctx);
  if (traceparent != null) {
    final app = appContextOf(ctx.span);
    args[channelContextKey] = {
      Traceparent.header: traceparent,
      if (app?.screen != null) appScreenKey: app!.screen,
      if (app?.flow != null) appFlowKey: app!.flow,
    };
  }
  return args;
}

/// Runs [fn] as a continuation of the trace native code sent in
/// [arguments] (see `OtelFlutterBridge.shared.withTraceContext` on iOS), so
/// spans started in [fn] become children of the native span and take its
/// `app.screen` / `app.flow`.
///
/// Use it at the top of a Dart `MethodChannel` handler that native code
/// calls. Without trace context in [arguments], [fn] just runs.
///
/// A Bloc runs event handlers in the zone where it was created, so the
/// context does not reach handlers of events added inside [fn]; link them
/// instead (see the app instrumentation guide, case J).
Future<T> runWithTraceContext<T>(
  Object? arguments,
  Future<T> Function() fn,
) {
  Context? ctx;
  AppContextValues? app;
  try {
    final otel = arguments is Map ? arguments[channelContextKey] : null;
    if (otel is Map) {
      final tp = Traceparent.parse(otel[Traceparent.header] as String?);
      if (tp != null) {
        ctx = Context.current.withSpanContext(
          OTel.spanContext(
            traceId: OTel.traceIdFrom(tp.traceId),
            spanId: OTel.spanIdFrom(tp.spanId),
            traceFlags: OTel.traceFlags(tp.flags),
            isRemote: true,
          ),
        );
        final screen = otel[appScreenKey];
        final flow = otel[appFlowKey];
        app = (
          screen: screen is String ? screen : null,
          flow: flow is String ? flow : null,
        );
      }
    }
  } catch (_) {
    // Telemetry never breaks the app: run without context.
  }
  final context = ctx;
  if (context == null) return fn();
  return context.run(() => runWithRemoteAppContext(app!, fn));
}

/// Traced calls through a platform channel.
extension TracedMethodChannel on MethodChannel {
  /// Calls [method] inside a client span and passes its trace context to the
  /// native side, so native spans become its children.
  ///
  /// [arguments] must be a map (or null), because the context travels as an
  /// extra key in it.
  Future<T?> invokeTraced<T>(
    String method, {
    Map<String, Object?>? arguments,
    Tracer? tracer,
  }) async {
    final t = tracer ?? OTel.tracer();
    final span = t.startSpan(
      '$name/$method',
      kind: SpanKind.client,
      attributes: OTel.attributesFromMap({
        'rpc.system': rpcSystemFlutterChannel,
        'rpc.service': name,
        'rpc.method': method,
      }),
    );
    try {
      return await t.withSpanAsync(
        span,
        () => invokeMethod<T>(method, withTraceContext(arguments)),
      );
    } catch (e) {
      markSpanError(span, e);
      rethrow;
    } finally {
      span.end();
    }
  }
}
