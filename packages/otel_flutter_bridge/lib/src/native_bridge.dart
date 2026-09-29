import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter/services.dart';

import 'diagnostics.dart';
import 'native_batch.dart';
import 'pipeline.dart';
import 'semantics.dart';

/// Dart end of the native bridge. See `docs/specs/native-bridge.md`.
///
/// Receives span batches from native code and tells native code when Dart is
/// ready, so spans created before that are queued natively, not lost.
class NativeBridge {
  /// Creates the bridge. [channel] exists for tests.
  ///
  /// [sampleRatio] is applied to native spans by trace id, with the same
  /// sampler as Dart spans. A trace sampled in Dart keeps its native spans;
  /// a trace that starts in native code is kept or dropped at the same
  /// rate as one that starts in Dart.
  NativeBridge(
    this._pipeline, {
    MethodChannel? channel,
    this.onDiagnostic,
    double sampleRatio = 1.0,
  })  : _channel = channel ?? const MethodChannel(bridgeChannelName),
        _sampler = sampleRatio >= 1.0 ? null : TraceIdRatioSampler(sampleRatio);

  final TelemetryPipeline _pipeline;
  final MethodChannel _channel;
  final TraceIdRatioSampler? _sampler;

  /// Receives rejected batches.
  final DiagnosticListener? onDiagnostic;

  /// Starts listening and signals native code that Dart is ready.
  /// Returns false when there is no native side (tests, unsupported
  /// platforms); Dart telemetry still works.
  Future<bool> connect(
      {required bool enabled, required int maxBatchSize}) async {
    _channel.setMethodCallHandler(_handle);
    try {
      await _channel.invokeMethod<void>('ready', {
        'v': nativeBatchFormatVersion,
        'enabled': enabled,
        'maxBatchSize': maxBatchSize,
      });
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

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
  void disconnect() => _channel.setMethodCallHandler(null);

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
    if (call.method != 'exportSpans') return null;
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
