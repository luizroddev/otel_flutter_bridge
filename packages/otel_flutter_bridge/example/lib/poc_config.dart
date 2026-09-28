import 'dart:io';

import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

/// Everything specific to one app lives here, never in the library.
/// Values can be overridden at build time:
///
///   flutter run --dart-define=OTEL_ENDPOINT=http://192.168.0.10:4318
///               --dart-define=DEMO_BACKEND=http://192.168.0.10:8080
///
/// An empty OTEL_ENDPOINT keeps data in memory only (inspector only).
abstract final class PocConfig {
  static const _endpoint = String.fromEnvironment('OTEL_ENDPOINT');
  static const _backend = String.fromEnvironment('DEMO_BACKEND');

  /// The Android emulator reaches the host machine at 10.0.2.2.
  static String get _host => Platform.isAndroid ? '10.0.2.2' : 'localhost';

  static String get endpoint => const bool.hasEnvironment('OTEL_ENDPOINT')
      ? _endpoint
      : 'http://$_host:4318';

  static String get demoBackend =>
      _backend.isNotEmpty ? _backend : 'http://$_host:8080';

  static OtelBridgeConfig bridgeConfig() => OtelBridgeConfig(
        serviceName: 'otel-bridge-poc',
        serviceVersion: '0.1.0',
        deploymentEnvironment: 'local',
        endpoint: Uri.parse(endpoint.isEmpty ? 'http://unused' : endpoint),
        redaction: const RedactionConfig(
          // Extension point: extra patterns for this app's own identifiers.
          extraPatterns: [r'ORD-\d{4}'],
        ),
      );

  /// Adds `app.poc = true` to every span, Dart or native.
  static void appEnricher(pb.Span span, SpanOrigin origin) {
    span.attributes.add(
      pb.KeyValue(key: 'app.poc', value: pb.AnyValue(boolValue: true)),
    );
  }
}
