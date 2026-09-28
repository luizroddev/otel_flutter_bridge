import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/services.dart';

import 'semantics.dart';
import 'traceparent.dart';

/// Returns a copy of [arguments] carrying the trace context of [context]
/// (defaults to the current one) under [channelContextKey].
///
/// The native side reads it with `OtelFlutterBridge.shared.extractContext`.
/// When there is no active span, [arguments] is returned unchanged.
Map<String, Object?> withTraceContext(
  Map<String, Object?>? arguments, [
  Context? context,
]) {
  final args = <String, Object?>{...?arguments};
  final traceparent = Traceparent.fromContext(context);
  if (traceparent != null) {
    args[channelContextKey] = {Traceparent.header: traceparent};
  }
  return args;
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
    } catch (e, st) {
      span
        ..recordException(e, stackTrace: st)
        ..setStatus(SpanStatusCode.Error, e.runtimeType.toString())
        ..setStringAttribute('error.type', e.runtimeType.toString());
      rethrow;
    } finally {
      span.end();
    }
  }
}
