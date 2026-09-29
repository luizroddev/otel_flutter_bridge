import 'dart:async';
import 'dart:collection';

import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;

import 'config.dart';
import 'diagnostics.dart';
import 'redaction.dart';
import 'semantics.dart';
import 'transport.dart';

/// Where a batch of spans came from.
enum SpanOrigin {
  /// Created by the Dart SDK.
  dart,

  /// Created by native code and received through the bridge.
  native,
}

/// Anything that provides the current `session.id`.
///
/// Extension point: replace it to reuse a session id the app already has,
/// as long as that id does not identify the user.
abstract interface class SessionIdProvider {
  /// The current session id.
  String get currentId;
}

/// Adds or changes attributes of a span before redaction.
///
/// Runs at export time, in batches, seconds after the span started: use it
/// for values that do not change during the session (tenant, build flavor).
/// For the current screen or flow use `AppContext`, which is read when the
/// span starts.
///
/// Extension point. Whatever an enricher adds must still be allowed by the
/// redaction config (for example under the `app.` prefix), or it is dropped.
typedef SpanEnricher = void Function(pb.Span span, SpanOrigin origin);

/// One request that left the pipeline, after redaction.
class ExportRecord {
  /// Creates a record.
  ExportRecord({
    required this.request,
    required this.origin,
    required this.success,
    required this.time,
  });

  /// The request exactly as it was sent.
  final pb.ExportTraceServiceRequest request;

  /// Where its spans came from.
  final SpanOrigin origin;

  /// Whether the transport accepted it.
  final bool success;

  /// When it was sent.
  final DateTime time;

  /// Its spans, flattened.
  Iterable<pb.Span> get spans => request.resourceSpans
      .expand((rs) => rs.scopeSpans)
      .expand((ss) => ss.spans);
}

/// The single path every span takes before leaving the device:
/// enrich, stamp the session, redact, queue, send.
///
/// Never throws to its callers. Any error drops the data and is reported to
/// [onDiagnostic]. See `docs/specs/failure-and-limits.md`.
class TelemetryPipeline {
  /// Creates a pipeline.
  TelemetryPipeline({
    required TraceTransport transport,
    required Redactor redactor,
    required SessionIdProvider session,
    required BridgeLimits limits,
    List<pb.KeyValue> commonResource = const [],
    List<SpanEnricher> enrichers = const [],
    this.onDiagnostic,
    bool enabled = true,
  })  : _transport = transport,
        _redactor = redactor,
        _session = session,
        _limits = limits,
        _commonResource = commonResource,
        _enrichers = enrichers,
        _enabled = enabled;

  final TraceTransport _transport;
  final Redactor _redactor;
  final SessionIdProvider _session;
  final BridgeLimits _limits;
  final List<pb.KeyValue> _commonResource;
  final List<SpanEnricher> _enrichers;
  final _queue = ListQueue<(pb.ExportTraceServiceRequest, SpanOrigin)>();
  final _records = StreamController<ExportRecord>.broadcast();
  Future<void>? _draining;
  bool _enabled;

  /// Receives every internal problem. Never called with personal data.
  final DiagnosticListener? onDiagnostic;

  /// Every request sent, after redaction. Used by the in-app inspector.
  Stream<ExportRecord> get records => _records.stream;

  /// Whether data flows. When false, everything submitted is discarded.
  bool get enabled => _enabled;
  set enabled(bool value) {
    _enabled = value;
    if (!value) _queue.clear();
  }

  /// Submits spans created by the Dart SDK.
  void submitDart(pb.ExportTraceServiceRequest request) =>
      _submit(request, SpanOrigin.dart);

  /// Submits spans that came from native code.
  void submitNative(pb.ResourceSpans resourceSpans) {
    _guard(() {
      final attrs = resourceSpans.resource.attributes;
      final present = attrs.map((kv) => kv.key).toSet();
      for (final kv in _commonResource) {
        if (!present.contains(kv.key)) attrs.add(kv.deepCopy());
      }
    });
    _submit(
      pb.ExportTraceServiceRequest(resourceSpans: [resourceSpans]),
      SpanOrigin.native,
    );
  }

  void _submit(pb.ExportTraceServiceRequest request, SpanOrigin origin) {
    if (!_enabled) return;
    _guard(() {
      final sessionId = _session.currentId;
      final source =
          origin == SpanOrigin.dart ? bridgeSourceDart : bridgeSourceNative;
      for (final rs in request.resourceSpans) {
        for (final ss in rs.scopeSpans) {
          for (final span in ss.spans) {
            for (final enrich in _enrichers) {
              enrich(span, origin);
            }
            _put(span.attributes, sessionIdKey, sessionId);
            _put(span.attributes, bridgeSourceKey, source);
          }
        }
      }
      _redactor.redactRequest(request);
      for (final part in _split(request)) {
        if (_queue.length >= _limits.maxQueuedBatches) {
          _queue.removeFirst();
          _report(BridgeDiagnosticKind.queueFull);
        }
        _queue.add((part, origin));
      }
      _draining ??= _drain().whenComplete(() => _draining = null);
    });
  }

  /// Waits until everything queued was sent or dropped.
  Future<void> flush() async {
    while (_draining != null) {
      await _draining;
    }
  }

  /// Sends what is queued and closes the transport.
  Future<void> shutdown() async {
    await flush();
    await _transport.close();
    await _records.close();
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty) {
      final (request, origin) = _queue.removeFirst();
      var ok = false;
      try {
        ok = await _transport.send(request);
      } catch (_) {
        ok = false;
      }
      if (!ok) _report(BridgeDiagnosticKind.exportFailed);
      if (!_records.isClosed && _records.hasListener) {
        _records.add(
          ExportRecord(
            request: request,
            origin: origin,
            success: ok,
            time: DateTime.now(),
          ),
        );
      }
    }
  }

  /// Splits a request so no part has more than `maxSpansPerExport` spans.
  Iterable<pb.ExportTraceServiceRequest> _split(
    pb.ExportTraceServiceRequest request,
  ) sync* {
    final max = _limits.maxSpansPerExport;
    var current = pb.ExportTraceServiceRequest();
    var count = 0;
    for (final rs in request.resourceSpans) {
      for (final ss in rs.scopeSpans) {
        for (final span in ss.spans) {
          if (count == max) {
            yield current;
            current = pb.ExportTraceServiceRequest();
            count = 0;
          }
          _bucket(current, rs, ss).spans.add(span);
          count++;
        }
      }
    }
    if (count > 0) yield current;
  }

  pb.ScopeSpans _bucket(
    pb.ExportTraceServiceRequest target,
    pb.ResourceSpans rs,
    pb.ScopeSpans ss,
  ) {
    var outRs = target.resourceSpans.isEmpty ? null : target.resourceSpans.last;
    if (outRs == null || outRs.resource != rs.resource) {
      outRs = pb.ResourceSpans(resource: rs.resource, schemaUrl: rs.schemaUrl);
      target.resourceSpans.add(outRs);
    }
    var outSs = outRs.scopeSpans.isEmpty ? null : outRs.scopeSpans.last;
    if (outSs == null || outSs.scope != ss.scope) {
      outSs = pb.ScopeSpans(scope: ss.scope, schemaUrl: ss.schemaUrl);
      outRs.scopeSpans.add(outSs);
    }
    return outSs;
  }

  void _guard(void Function() body) {
    try {
      body();
    } catch (e) {
      _report(BridgeDiagnosticKind.internalError, e.runtimeType.toString());
    }
  }

  void _report(BridgeDiagnosticKind kind, [String? detail]) {
    try {
      onDiagnostic?.call(BridgeDiagnostic(kind, detail));
    } catch (_) {
      // A faulty listener must not break the pipeline.
    }
  }
}

void _put(List<pb.KeyValue> attrs, String key, String value) {
  attrs.removeWhere((kv) => kv.key == key);
  attrs.add(pb.KeyValue(key: key, value: pb.AnyValue(stringValue: value)));
}
