import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/services.dart';

import 'app_context.dart';
import 'semantics.dart';
import 'span_errors.dart';
import 'traceparent.dart';

/// Returns a copy of [arguments] carrying the trace context of [context]
/// (defaults to the current one) under [channelContextKey], with the
/// span's screen and flow so native children carry them too.
///
/// The native side reads it with `OtelFlutterBridge.shared.startSpan` or
/// `extractContext`. When there is no active span, [arguments] is returned
/// unchanged.
Map<String, Object?> withTraceContext(
  Map<String, Object?>? arguments, [
  Context? context,
]) {
  final args = <String, Object?>{...?arguments};
  try {
    final ctx = context ?? Context.current;
    final traceparent = Traceparent.fromContext(ctx);
    if (traceparent != null) {
      final app = appContextOf(ctx.span);
      args[channelContextKey] = {
        Traceparent.header: traceparent,
        if (app?.screen != null) appScreenKey: app!.screen,
        if (app?.flow != null) appFlowKey: app!.flow,
        if (app?.flowId != null) appFlowInstanceKey: app!.flowId,
      };
    }
  } catch (_) {
    // Telemetry never breaks the app: send the arguments as they are.
  }
  return args;
}

/// Runs [fn] as a continuation of the trace native code sent in
/// [arguments] (see `OtelFlutterBridge.shared.withTraceContext` on iOS), so
/// spans started in [fn] become children of the native span and take its
/// `app.screen.name` / `app.flow.name`.
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
        final flowId = otel[appFlowInstanceKey];
        app = (
          screen: screen is String ? screen : null,
          flow: flow is String ? flow : null,
          flowId: flowId is String ? flowId : null,
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
  ///
  /// Never fails because of telemetry: before `OtelFlutterBridge.initialize`,
  /// or if the SDK fails, the call goes out untraced with [arguments] as
  /// they are. Errors of the call itself mark the span and are rethrown with
  /// their original stack trace.
  Future<T?> invokeTraced<T>(
    String method, {
    Map<String, Object?>? arguments,
    Tracer? tracer,
  }) async {
    Tracer? t;
    Span? span;
    try {
      t = tracer ?? OTel.tracer();
      span = t.startSpan(
        '$name/$method',
        kind: SpanKind.client,
        attributes: OTel.attributesFromMap({
          'rpc.system': rpcSystemFlutterChannel,
          'rpc.service': name,
          'rpc.method': method,
        }),
      );
    } catch (_) {
      // Telemetry never breaks the app: call untraced.
    }
    if (t == null || span == null) return invokeMethod<T>(method, arguments);

    final s = span;
    // The call's error is caught inside the span and rethrown outside it, so
    // a telemetry failure around the call can never replace or hide it.
    Object? error;
    StackTrace? stackTrace;
    T? result;
    var ran = false;
    try {
      await t.withSpanAsync(s, () async {
        ran = true;
        try {
          result = await invokeMethod<T>(method, withTraceContext(arguments));
        } catch (e, st) {
          error = e;
          stackTrace = st;
        }
      });
    } catch (_) {
      if (!ran) {
        _endQuietly(s);
        return invokeMethod<T>(method, arguments);
      }
    }
    final e = error;
    if (e != null) markSpanError(s, e);
    _endQuietly(s);
    if (e != null) Error.throwWithStackTrace(e, stackTrace!);
    return result;
  }

  /// [setMethodCallHandler] where each call from native code is a server
  /// span named `channel/method` that continues the native trace (sent by
  /// `channel.invokeTraced` in Swift) with its screen and flow. Spans
  /// started while [handler] runs are its children. Errors mark the span
  /// and reach native code unchanged.
  ///
  /// A Bloc runs event handlers in the zone where it was created, so events
  /// added here start their own trace; link them if needed (see the app
  /// instrumentation guide, case J).
  void setTracedMethodCallHandler(
    Future<Object?> Function(MethodCall call)? handler, {
    Tracer? tracer,
  }) {
    if (handler == null) return setMethodCallHandler(null);
    setMethodCallHandler(
      (call) => runWithTraceContext(call.arguments, () async {
        Tracer? t;
        Span? span;
        try {
          t = tracer ?? OTel.tracer();
          span = t.startSpan(
            '$name/${call.method}',
            kind: SpanKind.server,
            attributes: OTel.attributesFromMap({
              'rpc.system': rpcSystemFlutterChannel,
              'rpc.service': name,
              'rpc.method': call.method,
            }),
          );
        } catch (_) {
          // Telemetry never breaks the app: run untraced.
        }
        if (t == null || span == null) return handler(call);
        final s = span;
        try {
          return await t.withSpanAsync(s, () => handler(call));
        } catch (e) {
          markSpanError(s, e);
          rethrow;
        } finally {
          try {
            s.end();
          } catch (_) {
            // Telemetry never breaks the app.
          }
        }
      }),
    );
  }
}

void _endQuietly(Span span) {
  try {
    span.end();
  } catch (_) {
    // Telemetry never breaks the app.
  }
}
