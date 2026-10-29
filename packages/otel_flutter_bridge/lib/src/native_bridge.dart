import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter/services.dart';

import 'diagnostics.dart';
import 'journey.dart';
import 'native_batch.dart';
import 'pipeline.dart';
import 'semantics.dart';
import 'session.dart';

/// Dart end of the native bridge. See `docs/specs/native-bridge.md`.
///
/// Receives span and journey event batches from native code and tells
/// native code when Dart is ready, so what was recorded before that is
/// queued natively, not lost. Keeps the journey state (screen, flow runs,
/// user) the same on both sides, and follows the native session when the
/// host owns it.
class NativeBridge {
  /// Creates the bridge. [channel] exists for tests.
  ///
  /// [sampleRatio] is applied to native spans by trace id, with the same
  /// sampler as Dart spans. A trace sampled in Dart keeps its native spans;
  /// a trace that starts in native code is kept or dropped at the same
  /// rate as one that starts in Dart.
  ///
  /// [hostSession] receives the native app's session id, when the host owns
  /// the session (`SessionConfig.fromHost`).
  NativeBridge(
    this._pipeline, {
    MethodChannel? channel,
    this.onDiagnostic,
    this.hostSession,
    double sampleRatio = 1.0,
  })  : _channel = channel ?? const MethodChannel(bridgeChannelName),
        _sampler = sampleRatio >= 1.0 ? null : TraceIdRatioSampler(sampleRatio);

  final TelemetryPipeline _pipeline;
  final MethodChannel _channel;
  final TraceIdRatioSampler? _sampler;

  /// Receives rejected batches.
  final DiagnosticListener? onDiagnostic;

  /// Where the native session id goes, or null when Dart owns the session.
  final HostSession? hostSession;

  /// Starts listening and signals native code that Dart is ready.
  /// Returns false when there is no native side (tests, unsupported
  /// platforms); Dart telemetry still works.
  Future<bool> connect(
      {required bool enabled, required int maxBatchSize}) async {
    _channel.setMethodCallHandler(_handle);
    Object? reply;
    try {
      reply = await _channel.invokeMethod<Object?>('ready', {
        'v': nativeBatchFormatVersion,
        'enabled': enabled,
        'maxBatchSize': maxBatchSize,
        'journey': journeyState(),
      });
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
    try {
      // Native replies with the merged journey state and what it knows
      // about the device; older versions reply null.
      if (reply is Map) {
        final journey = reply['journey'];
        applyJourneyState(journey);
        if (journey is Map) hostSession?.set(_string(journey['sessionId']));
        final resource = reply['resource'];
        if (resource is Map) _pipeline.addResource(resource);
      }
      setJourneySync(_sendJourney);
    } catch (e) {
      onDiagnostic?.call(
        BridgeDiagnostic(
            BridgeDiagnosticKind.internalError, '${e.runtimeType}'),
      );
    }
    return true;
  }

  void _sendJourney(Map<String, Object?> op) {
    _channel.invokeMethod<void>('journey', op).catchError((Object _) {
      // No native side, or it refused: the Dart state is already set.
    });
  }

  static String? _string(Object? v) => v is String && v.isNotEmpty ? v : null;

  /// Turns native recording on or off.
  Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } on MissingPluginException {
      // No native side.
    } on PlatformException {
      // Native side refused; Dart side is already switched.
    }
  }

  /// Stops listening.
  void disconnect() {
    setJourneySync(null);
    _channel.setMethodCallHandler(null);
  }

  void _sample(pb.ResourceSpans resourceSpans) {
    final sampler = _sampler;
    if (sampler == null) return;
    for (final ss in resourceSpans.scopeSpans) {
      ss.spans.retainWhere((span) {
        final result = sampler.shouldSample(
          parentContext: Context.root,
          traceId: _hex(span.traceId),
          name: span.name,
          spanKind: SpanKind.internal,
          attributes: null,
          links: null,
        );
        return result.decision == SamplingDecision.recordAndSample;
      });
    }
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'exportSpans':
        return _exportSpans(call);
      case 'exportEvents':
        return _exportEvents(call);
      case 'journey':
        try {
          final op = call.arguments;
          if (op is Map && op['op'] == 'session') {
            hostSession?.set(_string(op['id']));
          } else {
            applyJourneyOp(op);
          }
        } catch (e) {
          onDiagnostic?.call(
            BridgeDiagnostic(
                BridgeDiagnosticKind.internalError, '${e.runtimeType}'),
          );
        }
        return null;
    }
    return null;
  }

  Object? _exportEvents(MethodCall call) {
    try {
      final batch = decodeNativeEvents(call.arguments);
      if (batch.rejected > 0) {
        onDiagnostic?.call(
          BridgeDiagnostic(
            BridgeDiagnosticKind.nativeBatchRejected,
            '${batch.rejected} event(s)',
          ),
        );
      }
      recordNativeEvents(batch.records);
      return {'accepted': batch.records.length, 'rejected': batch.rejected};
    } catch (e) {
      onDiagnostic?.call(
        BridgeDiagnostic(
            BridgeDiagnosticKind.internalError, '${e.runtimeType}'),
      );
      return {'accepted': 0, 'rejected': 0};
    }
  }

  Object? _exportSpans(MethodCall call) {
    try {
      final batch = decodeNativeBatch(call.arguments);
      if (batch.rejected > 0) {
        onDiagnostic?.call(
          BridgeDiagnostic(
            BridgeDiagnosticKind.nativeBatchRejected,
            '${batch.rejected} span(s)',
          ),
        );
      }
      final resourceSpans = batch.resourceSpans;
      if (resourceSpans != null) {
        _sample(resourceSpans);
        _pipeline.submitNative(resourceSpans);
      }
      return {'accepted': batch.accepted, 'rejected': batch.rejected};
    } catch (e) {
      onDiagnostic?.call(
        BridgeDiagnostic(
            BridgeDiagnosticKind.internalError, '${e.runtimeType}'),
      );
      return {'accepted': 0, 'rejected': 0};
    }
  }
}
