import 'dart:async';
import 'dart:convert';
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

  /// Readable label sent as `journey.screen.label`, or null.
  String? get label => null;
}

/// A flow: a journey across screens, such as login or checkout. Mix it into
/// an enum, like [JourneyScreen].
mixin JourneyFlow on Enum {
  /// Stable code sent as `journey.flow.name`.
  String get code => name;

  /// Readable label sent as `journey.flow.label`, or null.
  String? get label => null;
}

/// Something the user does that matters: choose, send, confirm, cancel,
/// retry. Mix it into an enum, like [JourneyScreen].
mixin JourneyAction on Enum {
  /// Stable code sent as `journey.action.name`, and the span name of
  /// `Journey.track`.
  String get code => name;

  /// Readable label sent as `journey.action.label`, or null.
  String? get label => null;
}

/// Why an action or a flow run ended the way it did, such as a wrong
/// password or a blocked account. Mix it into an enum, like
/// [JourneyScreen]:
///
/// ```dart
/// enum LoginReason with JourneyReason { invalidPassword, blockedAccount }
/// ```
///
/// Sent as `journey.outcome_reason` next to `journey.outcome`, so the
/// dashboard can count failures by reason. A fixed list keeps it readable;
/// never put error text or ids here.
mixin JourneyReason on Enum {
  /// Stable code sent as `journey.outcome_reason`.
  String get code => name;
}

/// Extra attributes of a journey event. Keys must be allowed by redaction
/// (by default, keys under `app.`); never use the library's `journey.`
/// namespace. Values may be strings, booleans, numbers or enums (sent as
/// their name); anything else is dropped.
typedef JourneyAttributes = Map<String, Object?>;

/// One run of a flow, from `Journey.startFlow` to [end]. A run started in
/// native code (Swift `Journey.startFlow`) is one too: either side can end
/// it.
class JourneyFlowRun {
  JourneyFlowRun._(
    this.code,
    this.label,
    this.instanceId,
    this.parentInstanceId,
    this._start,
  );

  static JourneyFlowRun? _fromWire(Object? wire) {
    if (wire is! Map) return null;
    final code = wire['code'];
    final id = wire['instanceId'];
    final start = wire['startUnixNano'];
    if (code is! String || id is! String || id.isEmpty || start is! int) {
      return null;
    }
    final label = wire['label'];
    final parent = wire['parentInstanceId'];
    return JourneyFlowRun._(
      code,
      label is String ? label : null,
      id,
      parent is String ? parent : null,
      DateTime.fromMicrosecondsSinceEpoch(start ~/ 1000),
    );
  }

  Map<String, Object?> get _wire => {
        'code': code,
        'label': label,
        'instanceId': instanceId,
        'parentInstanceId': parentInstanceId,
        'startUnixNano': _start.microsecondsSinceEpoch * 1000,
      };

  /// The flow's code.
  final String code;

  /// The flow's label, or null.
  final String? label;

  /// Random id of this run, sent as `journey.flow.instance_id`.
  final String instanceId;

  /// The run that was current when this one started, or null. Sent as
  /// `journey.flow.parent_instance_id`.
  final String? parentInstanceId;

  final DateTime _start;
  bool _ended = false;

  /// Whether [end] was called.
  bool get isEnded => _ended;

  /// Ends the run with [outcome] and, optionally, the [reason] for it. Only
  /// the first call counts. When this is the current flow, the flow it was
  /// nested in (if any, and not ended) becomes current again.
  ///
  /// Use [JourneyOutcome.completed] when the app cannot tell whether the
  /// flow worked.
  void end(
    JourneyOutcome outcome, {
    JourneyReason? reason,
    JourneyAttributes attributes = const {},
  }) {
    if (_ended) return;
    _ended = true;
    Journey._emit(
      eventFlowEnd,
      {
        journeyFlowKey: code,
        journeyFlowLabelKey: label,
        journeyFlowInstanceKey: instanceId,
        journeyFlowParentInstanceKey: parentInstanceId,
        journeyOutcomeKey: outcome.name,
        journeyOutcomeReasonKey: reason?.code,
        journeyDurationKey: DateTime.now().difference(_start).inMilliseconds,
        ...attributes,
      },
    );
    Journey._removeFlow(this);
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
/// login.end(ok ? JourneyOutcome.success : JourneyOutcome.failure,
///     reason: ok ? null : LoginReason.invalidPassword);
/// ```
///
/// Never throws because of telemetry. Before `OtelFlutterBridge.initialize`
/// the app context is still updated, but nothing is recorded.
///
/// With the native side connected, the current screen, the open flow runs
/// and the user are shared with the Swift `Journey`: a flow started on a
/// native screen can end on a Flutter one, and the other way round.
abstract final class Journey {
  static JourneyRecorder? _recorder;
  // Runs not ended, oldest first. The last one is the current flow.
  static final _flows = <JourneyFlowRun>[];
  static final _random = Random.secure();
  // Mirrors each change on the native side. Set by the native bridge.
  static void Function(Map<String, Object?> op)? _sync;

  /// The current user id, or null.
  static String? get userId => AppContext.userId;

  /// Sets the user (`user.id`) of what happens from now on; null clears it
  /// (logout). Use an opaque id, never an e-mail or a document number.
  static void setUser(String? id) {
    final value = id == null || id.isEmpty ? null : id;
    AppContext.userId = value;
    _send({'op': 'user', 'id': value});
  }

  /// The flow run started last and not ended, or null.
  static JourneyFlowRun? get currentFlow => _flows.isEmpty ? null : _flows.last;

  /// The open run of [flow] started last, here or in native code, or null.
  /// Use it to end on this side a run started on the other:
  ///
  /// ```dart
  /// Journey.flowRun(AppFlow.login)?.end(JourneyOutcome.success);
  /// ```
  static JourneyFlowRun? flowRun(JourneyFlow flow) {
    for (final run in _flows.reversed) {
      if (run.code == flow.code) return run;
    }
    return null;
  }

  /// The user entered [screen]. Sets the current screen and records an
  /// `journey.screen.view` event.
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
    _send({'op': 'screen', 'code': code});
    _emit(eventScreenView, {journeyScreenLabelKey: label, ...attributes});
  }

  /// Starts a run of [flow] and makes it the current flow. Records an
  /// `journey.flow.start` event. End it with [JourneyFlowRun.end]; a run never
  /// ended shows as "no conclusion", not as abandoned.
  ///
  /// A flow started while another one is current is nested (for example a
  /// token activation inside a login): its events carry
  /// `journey.flow.parent_instance_id`, and ending it makes the outer flow
  /// current again. Starting a flow never ends the current one.
  static JourneyFlowRun startFlow(
    JourneyFlow flow, {
    JourneyAttributes attributes = const {},
  }) {
    final run = JourneyFlowRun._(
      flow.code,
      flow.label,
      newSessionId(_random),
      currentFlow?.instanceId,
      DateTime.now(),
    );
    _addFlow(run);
    _send({'op': 'flowStart', 'run': run._wire});
    _emit(eventFlowStart, {
      journeyFlowLabelKey: run.label,
      journeyFlowParentInstanceKey: run.parentInstanceId,
      ...attributes,
    });
    return run;
  }

  static void _addFlow(JourneyFlowRun run) {
    _flows.add(run);
    AppContext.flow = run.code;
    AppContext.flowInstanceId = run.instanceId;
  }

  static void _removeFlow(JourneyFlowRun run, {bool send = true}) {
    _flows.remove(run);
    // Only when the app context still points at this run: a value the app
    // set by hand is left alone.
    if (AppContext.flowInstanceId == run.instanceId) {
      final top = currentFlow;
      AppContext.flow = top?.code;
      AppContext.flowInstanceId = top?.instanceId;
    }
    if (send) _send({'op': 'flowEnd', 'instanceId': run.instanceId});
  }

  static void _send(Map<String, Object?> op) {
    try {
      _sync?.call(op);
    } catch (_) {
      // Telemetry never breaks the app.
    }
  }

  /// Records an instant [action], such as choosing an option. No span and
  /// no duration. [outcome] and [reason] are optional: an instant choice has
  /// none.
  static void event(
    JourneyAction action, {
    JourneyOutcome? outcome,
    JourneyReason? reason,
    JourneyAttributes attributes = const {},
  }) {
    _emit(eventAction, {
      journeyActionKey: action.code,
      journeyActionLabelKey: action.label,
      journeyActionInstanceKey: newSessionId(_random),
      journeyOutcomeKey: outcome?.name,
      journeyOutcomeReasonKey: reason?.code,
      ...attributes,
    });
  }

  /// Records a `session.start` event (OpenTelemetry session conventions)
  /// for session [id], following [previousId] when known. The built-in
  /// session rules call it; call it from a custom `SessionIdProvider` when
  /// it starts a session.
  static void sessionStarted(String id, {String? previousId}) {
    _emit(eventSessionStart, {
      sessionIdKey: id,
      if (previousId != id) sessionPreviousIdKey: previousId,
    });
  }

  /// Runs [body] once as [action]: a span named after the action (active
  /// while [body] runs, so HTTP and channel calls inside become its
  /// children) and an `journey.action` event with duration and outcome, linked
  /// to the span's trace.
  ///
  /// The outcome is [outcome] applied to the result, or
  /// [JourneyOutcome.completed] when not given; [reason] applied to the
  /// result gives `journey.outcome_reason`. When [body] throws, the
  /// outcome is [JourneyOutcome.failure] with `error.type` (from
  /// [errorType] or a fixed name for common types), never the error text,
  /// and the same error is rethrown with its stack trace.
  ///
  /// Screen, flow, user and session are those of when [body] started, on
  /// the span and on the event, even if the user navigates or logs in while
  /// it runs.
  static Future<T> track<T>(
    JourneyAction action,
    FutureOr<T> Function() body, {
    JourneyOutcome Function(T result)? outcome,
    JourneyReason? Function(T result)? reason,
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
    final at = recorder?.snapshot();
    final attrs = <String, Object?>{
      journeyActionKey: action.code,
      journeyActionLabelKey: action.label,
      journeyActionInstanceKey: instanceId,
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
    String? why;
    if (e != null) {
      result0 = JourneyOutcome.failure;
      try {
        type = errorType?.call(e);
      } catch (_) {
        // Telemetry never breaks the app.
      }
      type ??= errorTypeOf(e);
      markSpanError(span, e, type: type);
    } else {
      try {
        if (outcome != null) result0 = outcome(result);
        why = reason?.call(result)?.code;
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
      span.setStringAttribute(journeyOutcomeKey, result0.name);
      if (why != null) span.setStringAttribute(journeyOutcomeReasonKey, why);
    } catch (_) {
      // Telemetry never breaks the app.
    }
    _end(span);
    _emit(
      eventAction,
      {
        ...attrs,
        journeyOutcomeKey: result0.name,
        journeyOutcomeReasonKey: why,
        journeyDurationKey: DateTime.now().difference(start).inMilliseconds,
        if (type != null) 'error.type': type,
      },
      span: span,
      time: start,
      at: at,
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

  /// Forgets the open flows. Library use (shutdown and tests).
  static void reset() => _flows.clear();

  static void _emit(
    String eventName,
    JourneyAttributes attributes, {
    APISpan? span,
    DateTime? time,
    JourneySnapshot? at,
  }) {
    final recorder = _recorder;
    if (recorder == null) return;
    try {
      recorder.record(eventName, attributes, span: span, time: time, at: at);
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

/// Mirrors every change of the journey state (screen, flow runs, user) with
/// [send], or stops with null. Library use: the native bridge sends them to
/// the Swift `Journey`. See `docs/specs/native-bridge.md`.
void setJourneySync(void Function(Map<String, Object?> op)? send) =>
    Journey._sync = send;

/// The journey state, as sent to the native side in `ready`. Library use.
Map<String, Object?> journeyState() => {
      'screen': AppContext.screen,
      'userId': AppContext.userId,
      'flows': [for (final run in Journey._flows) run._wire],
    };

/// Applies one change made on the native side, without sending it back.
/// Unknown or malformed changes are ignored. Library use.
void applyJourneyOp(Object? op) {
  if (op is! Map) return;
  switch (op['op']) {
    case 'screen':
      final code = op['code'];
      AppContext.screen = code is String ? code : null;
    case 'user':
      final id = op['id'];
      AppContext.userId = id is String && id.isNotEmpty ? id : null;
    case 'flowStart':
      final run = JourneyFlowRun._fromWire(op['run']);
      if (run != null &&
          !Journey._flows.any((r) => r.instanceId == run.instanceId)) {
        Journey._addFlow(run);
      }
    case 'flowEnd':
      final id = op['instanceId'];
      for (final run in List.of(Journey._flows)) {
        if (run.instanceId == id) {
          run._ended = true;
          Journey._removeFlow(run, send: false);
        }
      }
  }
}

/// Replaces the journey state with [state] from the native side (the reply
/// to `ready`), without sending anything back. Runs missing from [state]
/// count as ended elsewhere. Library use.
void applyJourneyState(Object? state) {
  if (state is! Map) return;
  final screen = state['screen'];
  final user = state['userId'];
  AppContext.screen = screen is String ? screen : null;
  AppContext.userId = user is String && user.isNotEmpty ? user : null;
  final flows = state['flows'];
  final runs = flows is List
      ? flows.map(JourneyFlowRun._fromWire).nonNulls.toList()
      : const <JourneyFlowRun>[];
  final keep = {for (final r in runs) r.instanceId};
  for (final run in List.of(Journey._flows)) {
    if (!keep.contains(run.instanceId)) {
      run._ended = true;
      Journey._removeFlow(run, send: false);
    }
  }
  for (final run in runs) {
    if (!Journey._flows.any((r) => r.instanceId == run.instanceId)) {
      Journey._addFlow(run);
    }
  }
  final top = Journey.currentFlow;
  if (top != null) {
    AppContext.flow = top.code;
    AppContext.flowInstanceId = top.instanceId;
  }
}

/// The context of one moment: app context, user and session. Library use.
typedef JourneySnapshot = ({
  AppContextValues context,
  String? userId,
  String sessionId,
});

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
  final _random = Random.secure();
  Timer? _timer;

  /// The current context, to record an event later as if it happened now.
  JourneySnapshot snapshot() => (
        context: AppContext.values,
        userId: AppContext.userId,
        sessionId: session.currentId,
      );

  /// Records one event with the context [at] (default: now).
  void record(
    String eventName,
    JourneyAttributes attributes, {
    APISpan? span,
    DateTime? time,
    JourneySnapshot? at,
  }) {
    if (!pipeline.enabled || !pipeline.exportsLogs) return;
    final now = at ?? snapshot();
    final when = time ?? DateTime.now();
    final nanos = Int64(when.microsecondsSinceEpoch) * 1000;
    final record = pb.LogRecord(
      timeUnixNano: nanos,
      observedTimeUnixNano: Int64(DateTime.now().microsecondsSinceEpoch) * 1000,
      severityNumber: pb.SeverityNumber.SEVERITY_NUMBER_INFO,
      severityText: 'INFO',
    );
    // OTLP `event_name` (field 12) is newer than the protobuf classes of the
    // SDK: write it as a raw field. Replace with the generated setter when
    // the SDK has it. `event.name` stays as an attribute for older readers.
    record.unknownFields.mergeLengthDelimitedField(12, utf8.encode(eventName));
    final ctx = now.context;
    final values = <String, Object?>{
      eventNameKey: eventName,
      logRecordUidKey: newSessionId(_random),
      sessionIdKey: now.sessionId,
      userIdKey: now.userId,
      appScreenKey: ctx.screen,
      journeyFlowKey: ctx.flow,
      journeyFlowInstanceKey: ctx.flowId,
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
