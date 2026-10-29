import 'dart:async';
import 'dart:math';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:fixnum/fixnum.dart';

import 'app_context.dart';
import 'pipeline.dart';
import 'semantics.dart';
import 'session.dart';
import 'span_errors.dart';

/// How an action or a flow run ended. See `docs/specs/journey.md`.
///
/// [completed] means the code finished and the app did not say whether that
/// was a success: finishing is not the same as succeeding.
enum JourneyOutcome {
  /// The app says it worked.
  success,

  /// It failed: an exception, or the app says it did not work.
  failure,

  /// The user or the app cancelled it.
  cancelled,

  /// It finished, with no business result given.
  completed,
}

/// A screen of the app. Mix it into an enum:
///
/// ```dart
/// enum AppScreen with JourneyScreen { home, cart }
/// ```
///
/// [code] defaults to the enum value's name. Override [label] to give the
/// dashboard a readable name (`cart('Carrinho')`).
mixin JourneyScreen on Enum {
  /// Stable code sent as `app.screen.name`.
  String get code => name;

  /// Readable label sent as `app.screen.label`, or null.
  String? get label => null;
}

/// A flow: a journey across screens, such as login or checkout. Mix it into
/// an enum, like [JourneyScreen].
mixin JourneyFlow on Enum {
  /// Stable code sent as `app.flow.name`.
  String get code => name;

  /// Readable label sent as `app.flow.label`, or null.
  String? get label => null;
}

/// Something the user does that matters: choose, send, confirm, cancel,
/// retry. Mix it into an enum, like [JourneyScreen].
mixin JourneyAction on Enum {
  /// Stable code sent as `app.action.name`, and the span name of
  /// `Journey.track`.
  String get code => name;

  /// Readable label sent as `app.action.label`, or null.
  String? get label => null;
}

/// Extra attributes of a journey event. Keys should be under `app.` (they
/// pass through redaction like any other attribute). Values may be strings,
/// booleans, numbers or enums (sent as their name); anything else is
/// dropped.
typedef JourneyAttributes = Map<String, Object?>;

/// One run of a flow, from `Journey.startFlow` to [end].
class JourneyFlowRun {
  JourneyFlowRun._(this.code, this.label, this.instanceId, this._start);

  /// The flow's code.
  final String code;

  /// The flow's label, or null.
  final String? label;

  /// Random id of this run, sent as `app.flow.instance_id`.
  final String instanceId;

  final DateTime _start;
  bool _ended = false;

  /// Whether [end] was called.
  bool get isEnded => _ended;

  /// Ends the run with [outcome]. Only the first call counts. When this is
  /// the current flow, the app context leaves it.
  void end([
    JourneyOutcome outcome = JourneyOutcome.completed,
    JourneyAttributes attributes = const {},
  ]) {
    if (_ended) return;
    _ended = true;
    Journey._emit(
      eventFlowEnd,
      {
        appFlowKey: code,
        appFlowLabelKey: label,
        appFlowInstanceKey: instanceId,
        appOutcomeKey: outcome.name,
        appDurationKey: DateTime.now().difference(_start).inMilliseconds,
        ...attributes,
      },
    );
    if (AppContext.flowInstanceId == instanceId) {
      AppContext.flow = null;
      AppContext.flowInstanceId = null;
      if (identical(Journey._currentFlow, this)) Journey._currentFlow = null;
    }
  }
}

/// The journey API: screens, flows, actions and the user, recorded as
/// OpenTelemetry log events and spans. See `docs/specs/journey.md`.
///
/// ```dart
/// Journey.screen(AppScreen.login);
/// final login = Journey.startFlow(AppFlow.login);
/// Journey.event(AppAction.chooseBiometric);
/// final ok = await Journey.track(AppAction.confirmLogin, auth.login,
///     outcome: (ok) => ok ? JourneyOutcome.success : JourneyOutcome.failure);
/// login.end(ok ? JourneyOutcome.success : JourneyOutcome.failure);
/// ```
///
/// Never throws because of telemetry. Before `OtelFlutterBridge.initialize`
/// the app context is still updated, but nothing is recorded.
abstract final class Journey {
  static JourneyRecorder? _recorder;
  static JourneyFlowRun? _currentFlow;
  static final _random = Random.secure();

  /// The current user id, or null.
  static String? get userId => AppContext.userId;

  /// Sets the user (`user.id`) of what happens from now on; null clears it
  /// (logout). Use an opaque id, never an e-mail or a document number.
  static void setUser(String? id) =>
      AppContext.userId = id == null || id.isEmpty ? null : id;

  /// The flow run started last and not ended, or null.
  static JourneyFlowRun? get currentFlow => _currentFlow;

  /// The user entered [screen]. Sets the current screen and records an
  /// `app.screen.view` event.
  static void screen(
    JourneyScreen screen, {
    JourneyAttributes attributes = const {},
  }) =>
      screenNamed(screen.code, label: screen.label, attributes: attributes);

  /// Like [screen], with a plain code. For route names and native screens.
  static void screenNamed(
    String code, {
    String? label,
    JourneyAttributes attributes = const {},
  }) {
    AppContext.screen = code;
    _emit(eventScreenView, {appScreenLabelKey: label, ...attributes});
  }

  /// Starts a run of [flow] and makes it the current flow. Records an
  /// `app.flow.start` event. End it with [JourneyFlowRun.end]; a run never
  /// ended shows as "no conclusion", not as abandoned.
  static JourneyFlowRun startFlow(
    JourneyFlow flow, {
    JourneyAttributes attributes = const {},
  }) {
    final run = JourneyFlowRun._(
      flow.code,
      flow.label,
      newSessionId(_random),
      DateTime.now(),
    );
    AppContext.flow = run.code;
    AppContext.flowInstanceId = run.instanceId;
    _currentFlow = run;
    _emit(eventFlowStart, {appFlowLabelKey: run.label, ...attributes});
    return run;
  }

  /// Records an instant [action], such as choosing an option. No span and
  /// no duration. [outcome] is optional: an instant choice has none.
  static void event(
    JourneyAction action, {
    JourneyOutcome? outcome,
    JourneyAttributes attributes = const {},
  }) {
    _emit(eventAction, {
      appActionKey: action.code,
      appActionLabelKey: action.label,
      appActionInstanceKey: newSessionId(_random),
      appOutcomeKey: outcome?.name,
      ...attributes,
    });
  }

  /// Runs [body] once as [action]: a span named after the action (active
  /// while [body] runs, so HTTP and channel calls inside become its
  /// children) and an `app.action` event with duration and outcome, linked
  /// to the span's trace.
  ///
  /// The outcome is [outcome] applied to the result, or
  /// [JourneyOutcome.completed] when not given. When [body] throws, the
  /// outcome is [JourneyOutcome.failure] with `error.type` (from
  /// [errorType] or a fixed name for common types), never the error text,
  /// and the same error is rethrown with its stack trace.
  static Future<T> track<T>(
    JourneyAction action,
    FutureOr<T> Function() body, {
    JourneyOutcome Function(T result)? outcome,
    JourneyAttributes attributes = const {},
    String Function(Object error)? errorType,
  }) async {
    final recorder = _recorder;
    Tracer? tracer;
    Span? span;
    if (recorder != null) {
      try {
        tracer = OTel.tracer();
        span = tracer.startSpan(action.code);
      } catch (_) {
        // Telemetry never breaks the app: run untraced.
      }
    }
    if (tracer == null || span == null) return await body();

    final instanceId = newSessionId(_random);
    final start = DateTime.now();
    final attrs = <String, Object?>{
      appActionKey: action.code,
      appActionLabelKey: action.label,
      appActionInstanceKey: instanceId,
      ...attributes,
    };
    _setAll(span, attrs);

    // The error is caught inside the span and rethrown outside it, so it
    // does not go through the SDK's error path (see `tracedHandler`).
    Object? error;
    StackTrace? stackTrace;
    late T result;
    var ran = false;
    try {
      await tracer.withSpanAsync(span, () async {
        ran = true;
        try {
          result = await body();
        } catch (e, st) {
          error = e;
          stackTrace = st;
        }
      });
    } catch (_) {
      if (!ran) {
        _end(span);
        return await body();
      }
    }

    final e = error;
    var result0 = JourneyOutcome.completed;
    String? type;
    if (e != null) {
      result0 = JourneyOutcome.failure;
      try {
        type = errorType?.call(e);
      } catch (_) {
        // Telemetry never breaks the app.
      }
      type ??= errorTypeOf(e);
      markSpanError(span, e, type: type);
    } else if (outcome != null) {
      try {
        result0 = outcome(result);
      } catch (_) {
        // Telemetry never breaks the app.
      }
      if (result0 == JourneyOutcome.failure) {
        try {
          span.setStatus(SpanStatusCode.Error, 'failure');
        } catch (_) {
          // Telemetry never breaks the app.
        }
      }
    }
    try {
      span.setStringAttribute(appOutcomeKey, result0.name);
    } catch (_) {
      // Telemetry never breaks the app.
    }
    _end(span);
    _emit(
      eventAction,
      {
        ...attrs,
        appOutcomeKey: result0.name,
        appDurationKey: DateTime.now().difference(start).inMilliseconds,
        if (type != null) 'error.type': type,
      },
      span: span,
      time: start,
    );
    if (e != null) Error.throwWithStackTrace(e, stackTrace!);
    return result;
  }

  /// Installs the recorder. Library use (`OtelFlutterBridge.initialize`).
  static void install(JourneyRecorder? recorder) {
    _recorder?.dispose();
    _recorder = recorder;
  }

  /// Sends buffered events to the pipeline. Library use.
  static void flushBuffer() => _recorder?.flush();

  /// Forgets the current flow. Library use (shutdown and tests).
  static void reset() => _currentFlow = null;

  static void _emit(
    String eventName,
    JourneyAttributes attributes, {
    APISpan? span,
    DateTime? time,
  }) {
    final recorder = _recorder;
    if (recorder == null) return;
    try {
      recorder.record(eventName, attributes, span: span, time: time);
    } catch (_) {
      // Telemetry never breaks the app.
    }
  }

  static void _setAll(Span span, JourneyAttributes attrs) {
    try {
      for (final MapEntry(:key, :value) in attrs.entries) {
        switch (value) {
          case final String v:
            span.setStringAttribute(key, v);
          case final bool v:
            span.setBoolAttribute(key, v);
          case final int v:
            span.setIntAttribute(key, v);
          case final double v:
            span.setDoubleAttribute(key, v);
          case final Enum v:
            span.setStringAttribute(key, v.name);
          default:
            break;
        }
      }
    } catch (_) {
      // Telemetry never breaks the app.
    }
  }

  static void _end(Span span) {
    try {
      span.end();
    } catch (_) {
      // Telemetry never breaks the app.
    }
  }
}

/// Builds journey log records and hands them to the pipeline in batches.
/// Library use; created by `OtelFlutterBridge.initialize`.
class JourneyRecorder {
  /// Creates a recorder that feeds [pipeline], reading `session.id` from
  /// [session] when each event happens.
  JourneyRecorder(
    this.pipeline,
    this.session, {
    this.scheduleDelay = const Duration(seconds: 2),
    this.maxBatchSize = 512,
  });

  /// Where records go.
  final TelemetryPipeline pipeline;

  /// Where `session.id` comes from.
  final SessionIdProvider session;

  /// How long events wait before being sent together.
  final Duration scheduleDelay;

  /// Events in one batch; a full batch is sent at once.
  final int maxBatchSize;

  final _buffer = <pb.LogRecord>[];
  Timer? _timer;

  /// Records one event with the current app context.
  void record(
    String eventName,
    JourneyAttributes attributes, {
    APISpan? span,
    DateTime? time,
  }) {
    if (!pipeline.enabled || !pipeline.exportsLogs) return;
    final when = time ?? DateTime.now();
    final nanos = Int64(when.microsecondsSinceEpoch) * 1000;
    final record = pb.LogRecord(
      timeUnixNano: nanos,
      observedTimeUnixNano: Int64(DateTime.now().microsecondsSinceEpoch) * 1000,
      severityNumber: pb.SeverityNumber.SEVERITY_NUMBER_INFO,
      severityText: 'INFO',
    );
    final ctx = AppContext.values;
    final values = <String, Object?>{
      eventNameKey: eventName,
      sessionIdKey: session.currentId,
      userIdKey: AppContext.userId,
      appScreenKey: ctx.screen,
      appFlowKey: ctx.flow,
      appFlowInstanceKey: ctx.flowId,
      bridgeSourceKey: bridgeSourceDart,
      ...attributes,
    };
    for (final MapEntry(:key, :value) in values.entries) {
      final v = _anyValue(value);
      if (v != null) record.attributes.add(pb.KeyValue(key: key, value: v));
    }
    final sc = (span ?? Context.current.span)?.spanContext;
    if (sc != null && sc.isValid) {
      record
        ..traceId = sc.traceId.bytes
        ..spanId = sc.spanId.bytes
        ..flags = sc.traceFlags.asByte;
    }
    _buffer.add(record);
    if (_buffer.length >= maxBatchSize) {
      flush();
    } else {
      _timer ??= Timer(scheduleDelay, flush);
    }
  }

  /// Hands everything buffered to the pipeline.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_buffer.isEmpty) return;
    final batch = List.of(_buffer);
    _buffer.clear();
    pipeline.submitLogs(batch);
  }

  /// Drops the buffer and stops the timer.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _buffer.clear();
  }
}

pb.AnyValue? _anyValue(Object? value) => switch (value) {
      final String v => pb.AnyValue(stringValue: v),
      final bool v => pb.AnyValue(boolValue: v),
      final int v => pb.AnyValue(intValue: Int64(v)),
      final double v => pb.AnyValue(doubleValue: v),
      final Enum v => pb.AnyValue(stringValue: v.name),
      _ => null,
    };
