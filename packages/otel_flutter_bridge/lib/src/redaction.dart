import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;

import 'semantics.dart';

/// Text that replaces anything a scrubbing rule matches.
const redactedMarker = '[REDACTED]';

/// Placeholder for an identifier inside a URL path.
const pathIdMarker = '{id}';

/// Redaction settings. See `docs/specs/redaction.md`.
///
/// Redaction is an allowlist: an attribute whose key is not allowed is
/// dropped, never sent. Allowed string values are then scrubbed.
class RedactionConfig {
  /// Creates the redaction settings.
  const RedactionConfig({
    this.allowedAttributes = const {},
    this.allowedPrefixes = const {'app.'},
    this.extraPatterns = const [],
    this.useDefaultAllowlist = true,
    this.useDefaultScrubbers = true,
  });

  /// Reads settings from a map. Invalid regular expressions are ignored.
  factory RedactionConfig.fromMap(Map<String, Object?> map) {
    const d = RedactionConfig();
    Set<String> strings(Object? v, Set<String> fallback) =>
        v is List ? v.whereType<String>().toSet() : fallback;
    return RedactionConfig(
      allowedAttributes: strings(map['allowedAttributes'], d.allowedAttributes),
      allowedPrefixes: strings(map['allowedPrefixes'], d.allowedPrefixes),
      extraPatterns: map['extraPatterns'] is List
          ? (map['extraPatterns'] as List).whereType<String>().toList()
          : d.extraPatterns,
      useDefaultAllowlist: map['useDefaultAllowlist'] is bool
          ? map['useDefaultAllowlist'] as bool
          : d.useDefaultAllowlist,
      useDefaultScrubbers: map['useDefaultScrubbers'] is bool
          ? map['useDefaultScrubbers'] as bool
          : d.useDefaultScrubbers,
    );
  }

  /// Attribute keys allowed on top of the default allowlist.
  final Set<String> allowedAttributes;

  /// Key prefixes whose attributes are allowed. Defaults to `app.`, the
  /// namespace reserved for the app's own attributes.
  final Set<String> allowedPrefixes;

  /// Extra regular expressions. Every match in a string value is replaced by
  /// [redactedMarker].
  final List<String> extraPatterns;

  /// Whether [defaultAllowedAttributes] is part of the allowlist.
  final bool useDefaultAllowlist;

  /// Whether [defaultScrubPatterns] are applied.
  final bool useDefaultScrubbers;
}

/// Attribute keys allowed by default: OpenTelemetry semantic conventions that
/// describe the app, the device and the operation, never the person.
const defaultAllowedAttributes = <String>{
  // Resource.
  'service.name',
  'service.version',
  'service.namespace',
  'deployment.environment.name',
  'telemetry.sdk.name',
  'telemetry.sdk.language',
  'telemetry.sdk.version',
  'os.type',
  'os.name',
  'os.version',
  'device.model.identifier',
  'device.manufacturer',
  // Session and app context.
  sessionIdKey,
  appScreenKey,
  appFlowKey,
  // HTTP client.
  'http.request.method',
  'http.response.status_code',
  'http.route',
  'url.scheme',
  'url.path',
  'server.address',
  'server.port',
  'network.protocol.version',
  // Errors.
  'error.type',
  'exception.type',
  'exception.message',
  // Flutter <-> native calls.
  'rpc.system',
  'rpc.service',
  'rpc.method',
  // Library's own attributes.
  bridgeSourceKey,
};

/// Allowed attributes that are never scrubbed: values the library generates
/// itself and resource attributes that describe the app and the device,
/// which come from configuration or the OS, never from the user. Scrubbing
/// would only corrupt them (a version or build number is a digit run).
const trustedAttributes = <String>{
  sessionIdKey,
  bridgeSourceKey,
  'service.name',
  'service.version',
  'service.namespace',
  'deployment.environment.name',
  'telemetry.sdk.name',
  'telemetry.sdk.language',
  'telemetry.sdk.version',
  'os.type',
  'os.name',
  'os.version',
  'device.model.identifier',
  'device.manufacturer',
};

/// Default scrubbing rules, applied in order.
final defaultScrubPatterns = <RegExp>[
  // JSON Web Tokens.
  RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*'),
  // Authorization header values.
  RegExp(r'(bearer|basic)\s+[A-Za-z0-9\-._~+/]+=*', caseSensitive: false),
  // E-mail addresses.
  RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
  // UUIDs.
  RegExp(
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
  ),
  // Query strings of URLs, which often carry identifiers and tokens.
  RegExp(r'(?<=[A-Za-z0-9/])\?[^\s#"]*'),
  // Six or more digits, optionally split by one separator: document
  // numbers, card numbers, phone numbers, account numbers, IP addresses.
  RegExp(r'\d(?:[ .\-/]?\d){5,}'),
];

/// Applies the allowlist and the scrubbing rules to an OTLP request, in
/// place. This is the last step before anything leaves the device.
class Redactor {
  /// Builds a redactor from [config]. [maxValueLength] truncates long
  /// strings after scrubbing.
  Redactor(RedactionConfig config, {this.maxValueLength = 256})
      : _allowed = {
          if (config.useDefaultAllowlist) ...defaultAllowedAttributes,
          ...config.allowedAttributes,
        },
        _prefixes = config.allowedPrefixes,
        _patterns = [
          if (config.useDefaultScrubbers) ...defaultScrubPatterns,
          for (final p in config.extraPatterns)
            if (_tryRegExp(p) case final r?) r,
        ];

  final Set<String> _allowed;
  final Set<String> _prefixes;
  final List<RegExp> _patterns;

  /// Maximum length of a string value after scrubbing.
  final int maxValueLength;

  /// Whether an attribute with [key] may leave the device.
  bool isAllowed(String key) =>
      _allowed.contains(key) || _prefixes.any(key.startsWith);

  /// Scrubs a free-text value.
  String scrub(String value) {
    var out = value;
    for (final p in _patterns) {
      out = out.replaceAll(p, redactedMarker);
    }
    if (out.length > maxValueLength) {
      out = out.substring(0, maxValueLength);
    }
    return out;
  }

  /// Replaces path segments that look like identifiers with [pathIdMarker].
  /// A segment is an identifier when it has a digit or is a long opaque
  /// token. API version segments such as `v1` are kept.
  String scrubPath(String path) {
    final noQuery = path.split('?').first.split('#').first;
    final segments = noQuery.split('/').map((s) {
      if (s.isEmpty || _apiVersion.hasMatch(s)) return s;
      if (RegExp(r'\d').hasMatch(s) || s.length >= 24) return pathIdMarker;
      return s;
    });
    return scrub(segments.join('/'));
  }

  static final _apiVersion = RegExp(r'^v\d{1,2}$');

  /// Redacts the whole request in place.
  void redactRequest(pb.ExportTraceServiceRequest request) {
    for (final rs in request.resourceSpans) {
      if (rs.hasResource()) {
        rs.resource.droppedAttributesCount +=
            _redactAttributes(rs.resource.attributes);
      }
      for (final ss in rs.scopeSpans) {
        ss.spans.forEach(redactSpan);
      }
    }
  }

  /// Redacts one span in place.
  void redactSpan(pb.Span span) {
    span.name = scrub(span.name);
    span.droppedAttributesCount += _redactAttributes(span.attributes);
    for (final event in span.events) {
      event.name = scrub(event.name);
      event.droppedAttributesCount += _redactAttributes(event.attributes);
    }
    for (final link in span.links) {
      link.droppedAttributesCount += _redactAttributes(link.attributes);
    }
    if (span.hasStatus() && span.status.message.isNotEmpty) {
      span.status.message = scrub(span.status.message);
    }
  }

  /// Returns how many attributes were dropped.
  int _redactAttributes(List<pb.KeyValue> attributes) {
    final before = attributes.length;
    attributes.removeWhere((kv) {
      if (!isAllowed(kv.key)) return true;
      if (trustedAttributes.contains(kv.key)) return false;
      return !_redactValue(kv.key, kv.value);
    });
    return before - attributes.length;
  }

  /// Scrubs [value] in place. Returns false when it must be dropped.
  bool _redactValue(String key, pb.AnyValue value) {
    switch (value.whichValue()) {
      case pb.AnyValue_Value.stringValue:
        value.stringValue = key == 'url.path' || key == 'http.route'
            ? scrubPath(value.stringValue)
            : scrub(value.stringValue);
        return true;
      case pb.AnyValue_Value.arrayValue:
        value.arrayValue.values.removeWhere((v) => !_redactValue(key, v));
        return true;
      case pb.AnyValue_Value.boolValue:
      case pb.AnyValue_Value.intValue:
      case pb.AnyValue_Value.doubleValue:
        return true;
      // Nested maps and raw bytes cannot be checked key by key: drop them.
      case pb.AnyValue_Value.kvlistValue:
      case pb.AnyValue_Value.bytesValue:
      case pb.AnyValue_Value.notSet:
        return false;
    }
  }
}

RegExp? _tryRegExp(String pattern) {
  try {
    return RegExp(pattern);
  } on FormatException {
    return null;
  }
}
