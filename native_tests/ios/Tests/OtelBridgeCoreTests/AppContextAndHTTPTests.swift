import XCTest
@testable import OtelBridgeCore

final class AppContextStoreTests: XCTestCase {
  func testNewSpanTakesCurrentValuesWithoutParent() {
    let store = AppContextStore()
    store.screen = "Statement.list"
    store.flow = "statement"
    XCTAssertEqual(store.valuesForNewSpan(parentSpanId: nil),
                   AppContextValues(screen: "Statement.list", flow: "statement"))
  }

  func testChildCopiesParentEvenAfterNavigation() {
    let store = AppContextStore()
    store.screen = "Statement.list"
    let parent = store.valuesForNewSpan(parentSpanId: nil)
    store.register(parent, forSpanId: "p")
    store.screen = "Statement.detail"
    XCTAssertEqual(store.valuesForNewSpan(parentSpanId: "p").screen, "Statement.list")
    XCTAssertEqual(store.valuesForNewSpan(parentSpanId: "unknown").screen, "Statement.detail")
  }

  func testIsBounded() {
    let store = AppContextStore(capacity: 2)
    store.register(AppContextValues(screen: "a"), forSpanId: "1")
    store.register(AppContextValues(screen: "b"), forSpanId: "2")
    store.register(AppContextValues(screen: "c"), forSpanId: "3")
    XCTAssertNil(store.values(forSpanId: "1"))
    XCTAssertEqual(store.values(forSpanId: "3")?.screen, "c")
    // Re-registering a known span does not grow the store.
    store.register(AppContextValues(screen: "c2"), forSpanId: "3")
    XCTAssertEqual(store.values(forSpanId: "2")?.screen, "b")
  }

  func testClear() {
    let store = AppContextStore()
    store.screen = "x"
    store.register(AppContextValues(screen: "x"), forSpanId: "1")
    store.clear()
    XCTAssertNil(store.screen)
    XCTAssertNil(store.values(forSpanId: "1"))
  }
}

final class ChannelContextTests: XCTestCase {
  private let traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

  func testReadsScreenAndFlowFromDart() {
    let args: [String: Any] = ["_otel": ["traceparent": traceparent,
                                         "app.screen": "checkout.review",
                                         "app.flow": "purchase"]]
    XCTAssertEqual(TraceparentCodec.appContext(fromChannelArguments: args),
                   AppContextValues(screen: "checkout.review", flow: "purchase"))
  }

  func testNoTraceContextMeansNoAppContext() {
    XCTAssertNil(TraceparentCodec.appContext(fromChannelArguments: ["a": 1]))
    XCTAssertNil(TraceparentCodec.appContext(fromChannelArguments: ["_otel": ["app.screen": "x"]]))
    XCTAssertEqual(TraceparentCodec.appContext(fromChannelArguments: ["_otel": ["traceparent": traceparent]]),
                   AppContextValues())
  }

  func testBuildsContextForDart() {
    let ctx = TraceparentCodec.channelContext(traceparent: traceparent,
                                              app: AppContextValues(screen: "Statement.list"))
    XCTAssertEqual(ctx["traceparent"] as? String, traceparent)
    XCTAssertEqual(ctx["app.screen"] as? String, "Statement.list")
    XCTAssertNil(ctx["app.flow"])
    // Round trip through the reader used by native handlers.
    XCTAssertEqual(TraceparentCodec.appContext(fromChannelArguments: ["_otel": ctx])?.screen,
                   "Statement.list")
  }
}

final class HTTPSemanticsTests: XCTestCase {
  func testMethod() {
    XCTAssertEqual(HTTPSemantics.method("get"), "GET")
    XCTAssertEqual(HTTPSemantics.method(nil), "GET")
    XCTAssertEqual(HTTPSemantics.method("PURGE"), "_OTHER")
    XCTAssertEqual(HTTPSemantics.spanName(forMethod: "_OTHER"), "HTTP")
    XCTAssertEqual(HTTPSemantics.spanName(forMethod: "POST"), "POST")
  }

  func testPath() {
    XCTAssertEqual(HTTPSemantics.path(of: URL(string: "https://a.com")), "/")
    XCTAssertEqual(HTTPSemantics.path(of: URL(string: "https://a.com/v1/x?cpf=1")), "/v1/x")
    XCTAssertEqual(HTTPSemantics.path(of: nil), "/")
  }

  func testErrorType() {
    struct Validation: Error {}
    XCTAssertEqual(HTTPSemantics.errorType(statusCode: 404, error: Validation()), "404")
    XCTAssertEqual(HTTPSemantics.errorType(statusCode: 200, error: nil), nil)
    XCTAssertEqual(HTTPSemantics.errorType(statusCode: nil, error: URLError(.timedOut)), "URLError")
    XCTAssertEqual(HTTPSemantics.errorType(statusCode: nil, error: Validation()), "Validation")
  }
}
