import 'redaction.dart';

/// Everything the bridge needs to know, passed once to
/// `OtelFlutterBridge.initialize`.
///
/// Nothing here is specific to any company: names, extra redaction rules and
/// the endpoint all come from the app. See `docs/specs/configuration.md`.
class OtelBridgeConfig {
  /// Creates a configuration. Only [serviceName] and [endpoint] are required.
  const OtelBridgeConfig({
    required this.serviceName,
    required this.endpoint,
    this.serviceVersion,
    this.deploymentEnvironment,
    this.enabled = true,
    this.sampleRatio = 1.0,
    this.headers = const {},
    this.resourceAttributes = const {},
    this.redaction = const RedactionConfig(),
    this.session = const SessionConfig(),
    this.limits = const BridgeLimits(),
    this.exportTimeout = const Duration(seconds: 10),
  });

  /// Builds a configuration from a JSON-like map, typically fetched from a
  /// remote config service. Unknown keys are ignored; invalid values fall
  /// back to the defaults instead of throwing.
  factory OtelBridgeConfig.fromMap(Map<String, Object?> map) {
    final endpoint = Uri.tryParse(_string(map['endpoint']) ?? '');
    return OtelBridgeConfig(
      serviceName: _string(map['serviceName']) ?? 'unknown_service',
      endpoint: endpoint ?? Uri(),
      serviceVersion: _string(map['serviceVersion']),
      deploymentEnvironment: _string(map['deploymentEnvironment']),
      enabled: _bool(map['enabled']) ?? true,
      sampleRatio: (_num(map['sampleRatio']) ?? 1.0).toDouble().clamp(0, 1),
      headers: _stringMap(map['headers']),
      resourceAttributes: _stringMap(map['resourceAttributes']),
      redaction: RedactionConfig.fromMap(_map(map['redaction'])),
      session: SessionConfig.fromMap(_map(map['session'])),
      limits: BridgeLimits.fromMap(_map(map['limits'])),
      exportTimeout: Duration(
        milliseconds: _num(map['exportTimeoutMs'])?.toInt() ?? 10000,
      ),
    );
  }

  /// `service.name`. Identifies the app in the tracing backend.
  final String serviceName;

  /// `service.version`, usually the app version.
  final String? serviceVersion;

  /// `deployment.environment.name`, for example `staging` or `production`.
  final String? deploymentEnvironment;

  /// Base OTLP/HTTP endpoint, for example `https://collector.example.com`.
  /// `/v1/traces` is appended when missing. This is the only host the
  /// library ever connects to.
  final Uri endpoint;

  /// Master switch. When false, nothing is recorded or sent.
  final bool enabled;

  /// Fraction of new traces that are sampled, between 0 and 1.
  final double sampleRatio;

  /// Extra HTTP headers sent to [endpoint]. Never put a backend vendor token
  /// here: point the app at a collector that holds the token server side.
  final Map<String, String> headers;

  /// Extra resource attributes. They still pass through redaction, so each
  /// key must be allowed by [redaction].
  final Map<String, String> resourceAttributes;

  /// Allowed attributes and value scrubbing rules.
  final RedactionConfig redaction;

  /// When a session starts and ends.
  final SessionConfig session;

  /// Queue and batch sizes.
  final BridgeLimits limits;

  /// Timeout of each export request.
  final Duration exportTimeout;

  /// The full traces URL derived from [endpoint].
  Uri get tracesEndpoint {
    final path = endpoint.path;
    if (path.endsWith('/v1/traces')) return endpoint;
    final base = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    return endpoint.replace(path: '$base/v1/traces');
  }
}

/// Session rules. See `docs/specs/session.md`.
class SessionConfig {
  /// Creates the session rules.
  const SessionConfig({
    this.inactivityTimeout = const Duration(minutes: 30),
    this.maxDuration = const Duration(hours: 4),
  });

  /// Reads the rules from a map with `inactivityTimeoutMs` and
  /// `maxDurationMs`.
  factory SessionConfig.fromMap(Map<String, Object?> map) {
    const defaults = SessionConfig();
    return SessionConfig(
      inactivityTimeout: _duration(
        map['inactivityTimeoutMs'],
        defaults.inactivityTimeout,
      ),
      maxDuration: _duration(map['maxDurationMs'], defaults.maxDuration),
    );
  }

  /// A new session starts after this long without any span.
  final Duration inactivityTimeout;

  /// A session never lasts longer than this.
  final Duration maxDuration;
}

/// Size limits. When a queue is full the oldest item is dropped first.
/// See `docs/specs/failure-and-limits.md`.
class BridgeLimits {
  /// Creates the limits.
  const BridgeLimits({
    this.maxQueuedBatches = 32,
    this.maxSpansPerExport = 512,
    this.maxNativeBatchSize = 64,
    this.maxAttributeValueLength = 256,
  });

  /// Reads the limits from a map with the same keys as the fields.
  factory BridgeLimits.fromMap(Map<String, Object?> map) {
    const d = BridgeLimits();
    int read(String key, int fallback) {
      final v = _num(map[key])?.toInt();
      return v == null || v <= 0 ? fallback : v;
    }

    return BridgeLimits(
      maxQueuedBatches: read('maxQueuedBatches', d.maxQueuedBatches),
      maxSpansPerExport: read('maxSpansPerExport', d.maxSpansPerExport),
      maxNativeBatchSize: read('maxNativeBatchSize', d.maxNativeBatchSize),
      maxAttributeValueLength: read(
        'maxAttributeValueLength',
        d.maxAttributeValueLength,
      ),
    );
  }

  /// Export requests waiting to be sent. Beyond this the oldest is dropped.
  final int maxQueuedBatches;

  /// Spans in one export request.
  final int maxSpansPerExport;

  /// Spans in one native to Dart batch, sent to the native side.
  final int maxNativeBatchSize;

  /// String attribute values longer than this are truncated.
  final int maxAttributeValueLength;
}

String? _string(Object? v) => v is String && v.isNotEmpty ? v : null;
bool? _bool(Object? v) => v is bool ? v : null;
num? _num(Object? v) => v is num ? v : null;

Map<String, Object?> _map(Object? v) =>
    v is Map ? v.map((k, v) => MapEntry(k.toString(), v)) : const {};

Map<String, String> _stringMap(Object? v) {
  if (v is! Map) return const {};
  return {
    for (final e in v.entries)
      if (e.value is String) e.key.toString(): e.value as String,
  };
}

Duration _duration(Object? ms, Duration fallback) {
  final v = _num(ms)?.toInt();
  return v == null || v <= 0 ? fallback : Duration(milliseconds: v);
}
