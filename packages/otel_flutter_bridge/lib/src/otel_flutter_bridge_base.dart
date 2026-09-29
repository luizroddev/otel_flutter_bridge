import 'dart:async';
import 'dart:io' show Platform;

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter/foundation.dart';

import 'app_context.dart';
import 'config.dart';
import 'diagnostics.dart';
import 'exporter.dart';
import 'native_bridge.dart';
import 'pipeline.dart';
import 'redaction.dart';
import 'session.dart';
import 'span_errors.dart';
import 'transport.dart';

/// Entry point. Configures the OpenTelemetry Dart SDK and connects the
/// native side. After [initialize], use the standard OTel API
/// (`OTel.tracer()`) as usual.
abstract final class OtelFlutterBridge {
  static TelemetryPipeline? _pipeline;
  static NativeBridge? _native;
  static SessionIdProvider? _session;

  /// Whether [initialize] completed.
  static bool get isInitialized => _pipeline != null;

  /// The pipeline, for inspection (`records`) and advanced use.
  static TelemetryPipeline? get pipeline => _pipeline;

  /// The current `session.id`, or null before [initialize].
  static String? get sessionId => _session?.currentId;

  /// Configures everything. Safe to call once, early in `main()`.
  ///
  /// Never throws: on failure the bridge stays disabled, the app keeps
  /// running and [onDiagnostic] receives `initFailed`.
  ///
  /// Exceptions recorded by the SDK (`withSpanAsync`,
  /// `startActiveSpanAsync`) keep only their type: the message and stack
  /// trace are free text and may carry personal data. Outside debug mode the
  /// SDK's console log (`OTelLog`) is turned off for the same reason; it
  /// prints exception text. Use [onDiagnostic] for internal problems.
  ///
  /// Extension points:
  /// - [transport] replaces the default OTLP/HTTP sender.
  /// - [enrichers] add attributes to every span before redaction.
  /// - [sessionIdProvider] replaces the built-in session rules.
  /// - [onDiagnostic] receives internal problems (no span data).
  /// - [spanProcessors] are extra SDK processors, for example to mirror
  ///   spans somewhere during development. They see spans before redaction.
  static Future<void> initialize(
    OtelBridgeConfig config, {
    TraceTransport? transport,
    List<SpanEnricher> enrichers = const [],
    SessionIdProvider? sessionIdProvider,
    DiagnosticListener? onDiagnostic,
    List<SpanProcessor> spanProcessors = const [],
    bool connectNative = true,
    Duration scheduleDelay = const Duration(seconds: 2),
  }) async {
    if (isInitialized) return;
    try {
      final session = sessionIdProvider ?? SessionManager(config.session);
      final resource = <String, Object>{
        'service.name': config.serviceName,
        if (config.serviceVersion != null)
          'service.version': config.serviceVersion!,
        if (config.deploymentEnvironment != null)
          'deployment.environment.name': config.deploymentEnvironment!,
        ..._platformAttributes(),
        ...config.resourceAttributes,
      };
      final pipeline = TelemetryPipeline(
        transport: transport ??
            OtlpHttpTransport(
              config.tracesEndpoint,
              headers: config.headers,
              timeout: config.exportTimeout,
            ),
        redactor: Redactor(
          config.redaction,
          maxValueLength: config.limits.maxAttributeValueLength,
        ),
        session: session,
        limits: config.limits,
        commonResource: [
          for (final e in resource.entries)
            if (e.value is String)
              pb.KeyValue(
                key: e.key,
                value: pb.AnyValue(stringValue: e.value as String),
              ),
        ],
        enrichers: enrichers,
        onDiagnostic: onDiagnostic,
        enabled: config.enabled,
      );

      final batch = BatchSpanProcessor(
        BridgeSpanExporter(pipeline),
        BatchSpanProcessorConfig(
          scheduleDelay: scheduleDelay,
          maxExportBatchSize: config.limits.maxSpansPerExport,
        ),
      );

      await OTel.initialize(
        serviceName: config.serviceName,
        serviceVersion: config.serviceVersion,
        resourceAttributes: OTel.attributesFromMap(resource),
        spanProcessor: batch,
        sampler: ParentBasedSampler(TraceIdRatioSampler(config.sampleRatio)),
        spanKind: SpanKind.internal,
        enableMetrics: false,
        enableLogs: false,
        detectPlatformResources: false,
        spanExceptionOptions: const SpanExceptionOptions(
          exceptionSanitizer: sanitizeSpanException,
        ),
      );
      if (!kDebugMode) OTelLog.logFunction = null;
      OTel.tracerProvider().addSpanProcessor(AppContextSpanProcessor());
      for (final p in spanProcessors) {
        OTel.tracerProvider().addSpanProcessor(p);
      }

      _pipeline = pipeline;
      _session = session;

      if (connectNative) {
        _native = NativeBridge(
          pipeline,
          onDiagnostic: onDiagnostic,
          sampleRatio: config.sampleRatio,
        );
        await _native!.connect(
          enabled: config.enabled,
          maxBatchSize: config.limits.maxNativeBatchSize,
        );
      }
    } catch (e) {
      _pipeline = null;
      _session = null;
      onDiagnostic?.call(
        BridgeDiagnostic(BridgeDiagnosticKind.initFailed, '${e.runtimeType}'),
      );
    }
  }

  /// Turns data collection on or off at runtime, on both sides. Meant to be
  /// driven by remote config, so it can be switched off without a release.
  static Future<void> setEnabled(bool enabled) async {
    _pipeline?.enabled = enabled;
    await _native?.setEnabled(enabled);
  }

  /// Sends everything pending.
  static Future<void> flush() async {
    try {
      await OTel.tracerProvider().forceFlush();
      await _pipeline?.flush();
    } catch (_) {
      // Telemetry never breaks the app.
    }
  }

  /// Flushes and releases everything. Mostly for tests.
  static Future<void> shutdown() async {
    try {
      await flush();
      _native?.disconnect();
      await _pipeline?.shutdown();
      await OTel.shutdown();
    } catch (_) {
      // Telemetry never breaks the app.
    } finally {
      AppContext.clear();
      _pipeline = null;
      _native = null;
      _session = null;
    }
  }

  static Map<String, Object> _platformAttributes() {
    if (kIsWeb) return const {};
    try {
      return {
        'os.type': Platform.operatingSystem == 'macos'
            ? 'darwin'
            : Platform.operatingSystem,
        'os.name': Platform.operatingSystem,
      };
    } catch (_) {
      return const {};
    }
  }
}
