import Foundation

/// One OTLP request Dart hands to native code when
/// `OtelBridgeConfig.sendThroughNative` is on, for the app to send through
/// its own network stack (certificate pinning, gateway headers, mutual
/// TLS). See `OtelFlutterBridge.exportHandler`.
public struct TelemetryExport {
  /// `traces` or `logs`.
  public let signal: String
  /// Where Dart would send it (`{endpoint}/v1/traces`), or nil.
  public let url: URL?
  /// `Content-Type`, `Content-Encoding` when compressed, and the headers of
  /// the Dart config.
  public let headers: [String: String]
  /// The encoded OTLP request, ready to send as is.
  public let body: Data

  public init(signal: String, url: URL?, headers: [String: String], body: Data) {
    self.signal = signal
    self.url = url
    self.headers = headers
    self.body = body
  }

  /// A `POST` to `url`, or to `endpoint` + `/v1/{signal}` when given, with
  /// the body and headers, marked as telemetry so `HTTPClientSpan` never
  /// traces it. Nil when there is no URL.
  public func urlRequest(endpoint: URL? = nil) -> URLRequest? {
    guard let target = endpoint.map({ $0.appendingPathComponent("v1/\(signal)") }) ?? url else {
      return nil
    }
    var request = URLRequest(url: target)
    request.httpMethod = "POST"
    request.httpBody = body
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    request.markAsTelemetry()
    return request
  }
}

public extension URLRequest {
  /// Key of the `URLProtocol` property that marks the library's own
  /// requests. Properties are never sent.
  static let telemetryPropertyKey = "otel_flutter_bridge.telemetry"

  /// Marks the request as the library's own telemetry, so `HTTPClientSpan`
  /// never traces it: a span per export would be exported in turn, without
  /// end. `TelemetryExport.urlRequest` already does it.
  mutating func markAsTelemetry() {
    guard let mutable = (self as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
    URLProtocol.setProperty(true, forKey: URLRequest.telemetryPropertyKey, in: mutable)
    self = mutable as URLRequest
  }

  /// Whether `markAsTelemetry` was called on this request or the one it was
  /// copied from.
  var isTelemetry: Bool {
    URLProtocol.property(forKey: URLRequest.telemetryPropertyKey, in: self) as? Bool == true
  }
}
