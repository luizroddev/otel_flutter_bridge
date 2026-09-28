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
  NativeBridge(this._pipeline, {MethodChannel? channel, this.onDiagnostic})
      : _channel = channel ?? const MethodChannel(bridgeChannelName);

  final TelemetryPipeline _pipeline;
  final MethodChannel _channel;

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
      if (batch.resourceSpans != null) {
        _pipeline.submitNative(batch.resourceSpans!);
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
