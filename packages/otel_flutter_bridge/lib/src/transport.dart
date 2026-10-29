import 'dart:async';
import 'dart:io' show gzip;

import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'semantics.dart';

Map<String, String> _otlpHeaders(Map<String, String> headers, bool gzip) => {
      ...headers,
      'Content-Type': 'application/x-protobuf',
      if (gzip) 'Content-Encoding': 'gzip',
    };

List<int> _body(List<int> bytes, bool compress) =>
    compress ? gzip.encode(bytes) : bytes;

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
  /// Creates a transport that posts to [url]. With [gzip], bodies are
  /// compressed (`Content-Encoding: gzip`, part of OTLP/HTTP).
  OtlpHttpTransport(
    this.url, {
    Map<String, String> headers = const {},
    this.timeout = const Duration(seconds: 10),
    this.gzip = false,
    http.Client? client,
  })  : _headers = _otlpHeaders(headers, gzip),
        _client = client ?? http.Client();

  /// Full `/v1/traces` URL.
  final Uri url;

  /// Timeout of each request.
  final Duration timeout;

  /// Whether bodies are gzip compressed.
  final bool gzip;

  final Map<String, String> _headers;
  final http.Client _client;

  @override
  Future<bool> send(pb.ExportTraceServiceRequest request) async {
    try {
      final response = await _client
          .post(
            url,
            headers: _headers,
            body: _body(request.writeToBuffer(), gzip),
          )
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

/// Sends redacted OTLP log requests (journey events) somewhere.
///
/// Same contract as [TraceTransport]: implementations must not throw.
abstract interface class LogTransport {
  /// Sends [request]. Returns true when it was accepted.
  Future<bool> send(pb.ExportLogsServiceRequest request);

  /// Releases resources.
  Future<void> close();
}

/// Default log transport: OTLP over HTTP with protobuf encoding.
class OtlpHttpLogTransport implements LogTransport {
  /// Creates a transport that posts to [url], the full `/v1/logs` URL.
  /// With [gzip], bodies are compressed.
  OtlpHttpLogTransport(
    this.url, {
    Map<String, String> headers = const {},
    this.timeout = const Duration(seconds: 10),
    this.gzip = false,
    http.Client? client,
  })  : _headers = _otlpHeaders(headers, gzip),
        _client = client ?? http.Client();

  /// Full `/v1/logs` URL.
  final Uri url;

  /// Timeout of each request.
  final Duration timeout;

  /// Whether bodies are gzip compressed.
  final bool gzip;

  final Map<String, String> _headers;
  final http.Client _client;

  @override
  Future<bool> send(pb.ExportLogsServiceRequest request) async {
    try {
      final response = await _client
          .post(
            url,
            headers: _headers,
            body: _body(request.writeToBuffer(), gzip),
          )
          .timeout(timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> close() async => _client.close();
}

/// Keeps every log request in memory. For tests and for in-app inspection.
class InMemoryLogTransport implements LogTransport {
  /// Everything sent so far, oldest first.
  final List<pb.ExportLogsServiceRequest> requests = [];

  /// All log records sent so far, flattened.
  List<pb.LogRecord> get records => [
        for (final r in requests)
          for (final rl in r.resourceLogs)
            for (final sl in rl.scopeLogs) ...sl.logRecords,
      ];

  /// Whether [send] reports success.
  bool succeed = true;

  @override
  Future<bool> send(pb.ExportLogsServiceRequest request) async {
    requests.add(request.deepCopy());
    return succeed;
  }

  @override
  Future<void> close() async {}
}

/// Sends OTLP requests through the native app's own network stack
/// (certificate pinning, gateway headers, mutual TLS), over the bridge
/// channel: the Swift side calls `OtelFlutterBridge.shared.exportHandler`.
/// Turned on with `OtelBridgeConfig.sendThroughNative`. See
/// `docs/specs/native-bridge.md`.
///
/// Native code receives the encoded body, the URL derived from the
/// endpoint and the headers, and replies whether the server accepted it.
/// No reply within [timeout], no native side or no handler count as a
/// failure. Never throws.
class NativeExport {
  /// Creates a sender for one signal (`traces` or `logs`). [channel] exists
  /// for tests.
  NativeExport(
    this.signal,
    this.url, {
    this.headers = const {},
    this.timeout = const Duration(seconds: 10),
    this.gzip = false,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(bridgeChannelName);

  /// `traces` or `logs`.
  final String signal;

  /// Where the request should go, from `OtelBridgeConfig.endpoint`. The
  /// native side may use it or its own.
  final Uri url;

  /// Extra headers from the config.
  final Map<String, String> headers;

  /// How long to wait for the native side.
  final Duration timeout;

  /// Whether bodies are gzip compressed.
  final bool gzip;

  final MethodChannel _channel;

  /// Sends one encoded request. Returns true when the server accepted it.
  Future<bool> send(List<int> body) async {
    try {
      final ok = await _channel.invokeMethod<bool>('export', {
        'signal': signal,
        'url': url.toString(),
        'headers': _otlpHeaders(headers, gzip),
        'body': Uint8List.fromList(_body(body, gzip)),
      }).timeout(timeout);
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// [TraceTransport] through the native app's network stack. See
/// [NativeExport].
class NativeTraceTransport implements TraceTransport {
  /// Creates a transport that hands requests to [export].
  NativeTraceTransport(this.export);

  /// The native sender.
  final NativeExport export;

  @override
  Future<bool> send(pb.ExportTraceServiceRequest request) =>
      export.send(request.writeToBuffer());

  @override
  Future<void> close() async {}
}

/// [LogTransport] through the native app's network stack. See
/// [NativeExport].
class NativeLogTransport implements LogTransport {
  /// Creates a transport that hands requests to [export].
  NativeLogTransport(this.export);

  /// The native sender.
  final NativeExport export;

  @override
  Future<bool> send(pb.ExportLogsServiceRequest request) =>
      export.send(request.writeToBuffer());

  @override
  Future<void> close() async {}
}
