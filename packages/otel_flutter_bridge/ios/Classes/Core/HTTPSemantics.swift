import Foundation

/// OpenTelemetry HTTP semantic conventions shared by every native HTTP
/// integration, with the same rules as the Dart side (`OtelHttpClient`).
public enum HTTPSemantics {
  static let knownMethods: Set<String> = [
    "CONNECT", "DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT", "TRACE",
  ]

  /// A known method in upper case, or `_OTHER`, so custom methods do not
  /// create unbounded span names. A missing method is `GET`, as in
  /// `URLRequest`.
  public static func method(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "GET" }
    let upper = raw.uppercased()
    return knownMethods.contains(upper) ? upper : "_OTHER"
  }

  /// The span name for `method`: the method itself, or `HTTP` for `_OTHER`.
  public static func spanName(forMethod method: String) -> String {
    method == "_OTHER" ? "HTTP" : method
  }

  /// `url.path`: the path, or `/` when empty. Query and fragment are never
  /// recorded; ids in the path are normalized by the Dart redaction.
  public static func path(of url: URL?) -> String {
    guard let path = url?.path, !path.isEmpty else { return "/" }
    return path
  }

  /// `error.type`: the status code when it is 400 or more (it wins over a
  /// validation error, such as Alamofire's `validate()`), otherwise the
  /// error's type, otherwise nil.
  ///
  /// Errors bridged from Objective-C (every `URLSession` error) report their
  /// dynamic type as `NSError`, so `URLError` is named explicitly and other
  /// bridged errors use their domain, which is low cardinality.
  public static func errorType(statusCode: Int?, error: Error?) -> String? {
    if let statusCode, statusCode >= 400 { return String(statusCode) }
    guard let error else { return nil }
    if error is URLError { return "URLError" }
    let name = String(describing: type(of: error))
    if name == "NSError" || name.hasPrefix("__") { return (error as NSError).domain }
    return name
  }
}
