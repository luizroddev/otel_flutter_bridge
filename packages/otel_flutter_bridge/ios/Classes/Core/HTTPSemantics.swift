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
  /// A `URLError` keeps its code, so a timeout, no connection and a failed
  /// certificate check are told apart: `URLError.timedOut`,
  /// `URLError.notConnectedToInternet`, `URLError.-1234` for a code without
  /// a name here. Other errors bridged from Objective-C report their
  /// dynamic type as `NSError`, so they use their domain, which is low
  /// cardinality.
  public static func errorType(statusCode: Int?, error: Error?) -> String? {
    if let statusCode, statusCode >= 400 { return String(statusCode) }
    guard let error else { return nil }
    if let urlError = error as? URLError {
      let code = urlError.code.rawValue
      return "URLError." + (urlErrorNames[code] ?? String(code))
    }
    let name = String(describing: type(of: error))
    if name == "NSError" || name.hasPrefix("__") { return (error as NSError).domain }
    return name
  }

  /// Names of the `URLError` codes an app meets in practice.
  static let urlErrorNames: [Int: String] = [
    URLError.Code.cancelled.rawValue: "cancelled",
    URLError.Code.badURL.rawValue: "badURL",
    URLError.Code.timedOut.rawValue: "timedOut",
    URLError.Code.unsupportedURL.rawValue: "unsupportedURL",
    URLError.Code.cannotFindHost.rawValue: "cannotFindHost",
    URLError.Code.cannotConnectToHost.rawValue: "cannotConnectToHost",
    URLError.Code.networkConnectionLost.rawValue: "networkConnectionLost",
    URLError.Code.dnsLookupFailed.rawValue: "dnsLookupFailed",
    URLError.Code.httpTooManyRedirects.rawValue: "httpTooManyRedirects",
    URLError.Code.resourceUnavailable.rawValue: "resourceUnavailable",
    URLError.Code.notConnectedToInternet.rawValue: "notConnectedToInternet",
    URLError.Code.badServerResponse.rawValue: "badServerResponse",
    URLError.Code.userCancelledAuthentication.rawValue: "userCancelledAuthentication",
    URLError.Code.userAuthenticationRequired.rawValue: "userAuthenticationRequired",
    URLError.Code.zeroByteResource.rawValue: "zeroByteResource",
    URLError.Code.cannotDecodeRawData.rawValue: "cannotDecodeRawData",
    URLError.Code.cannotDecodeContentData.rawValue: "cannotDecodeContentData",
    URLError.Code.cannotParseResponse.rawValue: "cannotParseResponse",
    URLError.Code.appTransportSecurityRequiresSecureConnection.rawValue:
      "appTransportSecurityRequiresSecureConnection",
    URLError.Code.internationalRoamingOff.rawValue: "internationalRoamingOff",
    URLError.Code.callIsActive.rawValue: "callIsActive",
    URLError.Code.dataNotAllowed.rawValue: "dataNotAllowed",
    URLError.Code.secureConnectionFailed.rawValue: "secureConnectionFailed",
    URLError.Code.serverCertificateHasBadDate.rawValue: "serverCertificateHasBadDate",
    URLError.Code.serverCertificateUntrusted.rawValue: "serverCertificateUntrusted",
    URLError.Code.serverCertificateHasUnknownRoot.rawValue: "serverCertificateHasUnknownRoot",
    URLError.Code.serverCertificateNotYetValid.rawValue: "serverCertificateNotYetValid",
    URLError.Code.clientCertificateRejected.rawValue: "clientCertificateRejected",
    URLError.Code.clientCertificateRequired.rawValue: "clientCertificateRequired",
    URLError.Code.cannotLoadFromNetwork.rawValue: "cannotLoadFromNetwork",
    URLError.Code.backgroundSessionWasDisconnected.rawValue: "backgroundSessionWasDisconnected",
  ]
}
