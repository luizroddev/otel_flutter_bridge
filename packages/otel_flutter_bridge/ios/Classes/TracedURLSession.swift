import Foundation
import OpenTelemetryApi

/// Explicit HTTP instrumentation for `URLSession` completion-handler and
/// async calls. For any other stack (Alamofire, delegate-based sessions,
/// the app's own client) use `HTTPClientSpan` directly. No swizzling: only
/// calls that go through here are traced.
public enum TracedURLSession {
  /// Hosts that receive `traceparent`. Empty means all. Same setting as
  /// `HTTPClientSpan.propagateTo`.
  public static var propagateTo: Set<String> {
    get { HTTPClientSpan.propagateTo }
    set { HTTPClientSpan.propagateTo = newValue }
  }

  @available(iOS 15.0, macOS 12.0, *)
  public static func data(for request: URLRequest, session: URLSession = .shared,
                          parent: SpanContext? = nil) async throws -> (Data, URLResponse) {
    let (span, traced) = HTTPClientSpan.start(request, parent: parent)
    do {
      let (data, response) = try await session.data(for: traced)
      HTTPClientSpan.finish(span, response: response, error: nil)
      return (data, response)
    } catch {
      HTTPClientSpan.finish(span, response: nil, error: error)
      throw error
    }
  }

  @discardableResult
  public static func dataTask(with request: URLRequest, session: URLSession = .shared,
                              parent: SpanContext? = nil,
                              completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
    let (span, traced) = HTTPClientSpan.start(request, parent: parent)
    let task = session.dataTask(with: traced) { data, response, error in
      HTTPClientSpan.finish(span, response: response, error: error)
      completion(data, response, error)
    }
    task.resume()
    return task
  }
}
