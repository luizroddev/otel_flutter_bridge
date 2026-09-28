import 'dart:async';

import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:http/http.dart' as http;

/// Sends redacted OTLP requests somewhere.
///
/// Extension point: implement it to send through the app's own HTTP stack
/// (certificate pinning, proxy, custom auth), or to tee data elsewhere.
/// Implementations must not throw; return false on failure.
abstract interface class TraceTransport {
  /// Sends [request]. Returns true when it was accepted.
  Future<bool> send(pb.ExportTraceServiceRequest request);

  /// Releases resources.
  Future<void> close();
}

/// Default transport: OTLP over HTTP with protobuf encoding.
class OtlpHttpTransport implements TraceTransport {
  /// Creates a transport that posts to [url].
  OtlpHttpTransport(
    this.url, {
    Map<String, String> headers = const {},
    this.timeout = const Duration(seconds: 10),
    http.Client? client,
  })  : _headers = {
          ...headers,
          'Content-Type': 'application/x-protobuf',
        },
        _client = client ?? http.Client();

  /// Full `/v1/traces` URL.
  final Uri url;

  /// Timeout of each request.
  final Duration timeout;

  final Map<String, String> _headers;
  final http.Client _client;

  @override
  Future<bool> send(pb.ExportTraceServiceRequest request) async {
    try {
      final response = await _client
          .post(url, headers: _headers, body: request.writeToBuffer())
          .timeout(timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> close() async => _client.close();
}

/// Keeps every request in memory. For tests and for in-app inspection.
class InMemoryTransport implements TraceTransport {
  /// Everything sent so far, oldest first.
  final List<pb.ExportTraceServiceRequest> requests = [];

  /// All spans sent so far, flattened.
  List<pb.Span> get spans => [
        for (final r in requests)
          for (final rs in r.resourceSpans)
            for (final ss in rs.scopeSpans) ...ss.spans,
      ];

  /// Whether [send] reports success.
  bool succeed = true;

  @override
  Future<bool> send(pb.ExportTraceServiceRequest request) async {
    requests.add(request.deepCopy());
    return succeed;
  }

  @override
  Future<void> close() async {}
}

/// Sends to several transports. Succeeds when the first one does; the others
/// are best effort. Useful to keep the real destination and add an inspector.
class TeeTransport implements TraceTransport {
  /// Creates a tee with [primary] and [secondary] transports.
  TeeTransport(this.primary, this.secondary);

  /// The transport whose result counts.
  final TraceTransport primary;

  /// Transports that also receive every request.
  final List<TraceTransport> secondary;

  @override
  Future<bool> send(pb.ExportTraceServiceRequest request) async {
    for (final t in secondary) {
      unawaited(t.send(request).catchError((_) => false));
    }
    return primary.send(request);
  }

  @override
  Future<void> close() async {
    await primary.close();
    for (final t in secondary) {
      await t.close();
    }
  }
}
