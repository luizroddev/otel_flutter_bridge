import XCTest
@testable import OtelBridgeCore

final class PendingSpanQueueTests: XCTestCase {
  private func span(_ i: Int) -> BridgeSpan {
    BridgeSpan(traceId: String(repeating: "a", count: 32),
               spanId: String(format: "%016x", i + 1),
               name: "span \(i)", startTimeUnixNano: 1, endTimeUnixNano: 2)
  }

  private func names(_ batches: [[String: Any]]) -> [String] {
    batches.flatMap { ($0["spans"] as! [[String: Any]]).map { $0["name"] as! String } }
  }

  func testHoldsSpansUntilDartIsReady() {
    let queue = PendingSpanQueue()
    var sent: [[String: Any]] = []
    queue.setSink { sent.append($0) }
    queue.enqueue([span(0), span(1)])
    XCTAssertTrue(sent.isEmpty)
    XCTAssertEqual(queue.count, 2)

    queue.markReady(enabled: true, maxBatchSize: 64)
    XCTAssertEqual(names(sent), ["span 0", "span 1"])
    XCTAssertEqual(queue.count, 0)

    queue.enqueue([span(2)])
    XCTAssertEqual(names(sent), ["span 0", "span 1", "span 2"])
  }

  func testDropsOldestWhenFull() {
    let queue = PendingSpanQueue(capacity: 3)
    queue.enqueue((0..<5).map(span))
    XCTAssertEqual(queue.count, 3)
    XCTAssertEqual(queue.droppedCount, 2)
    var sent: [[String: Any]] = []
    queue.setSink { sent.append($0) }
    queue.markReady(enabled: true, maxBatchSize: 64)
    XCTAssertEqual(names(sent), ["span 2", "span 3", "span 4"])
  }

  func testSplitsIntoBatches() {
    let queue = PendingSpanQueue()
    var sent: [[String: Any]] = []
    queue.setSink { sent.append($0) }
    queue.enqueue((0..<5).map(span))
    queue.markReady(enabled: true, maxBatchSize: 2)
    XCTAssertEqual(sent.map { ($0["spans"] as! [Any]).count }, [2, 2, 1])
    XCTAssertTrue(sent.allSatisfy { $0["v"] as? Int == 1 })
  }

  func testDisabledDiscards() {
    let queue = PendingSpanQueue()
    var sent: [[String: Any]] = []
    queue.setSink { sent.append($0) }
    queue.enqueue([span(0)])
    queue.markReady(enabled: false, maxBatchSize: 64)
    queue.enqueue([span(1)])
    XCTAssertTrue(sent.isEmpty)
    queue.setEnabled(true)
    queue.enqueue([span(2)])
    XCTAssertEqual(names(sent), ["span 2"])
  }

  func testConcurrentEnqueueIsSafe() {
    let queue = PendingSpanQueue(capacity: 10_000)
    DispatchQueue.concurrentPerform(iterations: 1000) { queue.enqueue([span($0)]) }
    XCTAssertEqual(queue.count, 1000)
  }
}

final class BridgeFormatTests: XCTestCase {
  func testWireFormat() {
    let s = BridgeSpan(
      traceId: String(repeating: "a", count: 32), spanId: String(repeating: "b", count: 16),
      parentSpanId: String(repeating: "c", count: 16), name: "op", kind: .client,
      startTimeUnixNano: 10, endTimeUnixNano: 20, statusCode: .error, statusMessage: "x",
      attributes: ["app.n": .int(1), "app.l": .array([.string("a"), .bool(true)])],
      events: [.init(name: "e", timeUnixNano: 15)], scopeName: "Lib", scopeVersion: "1")
    let w = s.wireValue
    XCTAssertEqual(w["kind"] as? String, "client")
    XCTAssertEqual(w["parentSpanId"] as? String, String(repeating: "c", count: 16))
    XCTAssertEqual((w["status"] as? [String: Any])?["code"] as? String, "error")
    XCTAssertEqual((w["attributes"] as? [String: Any])?["app.n"] as? Int, 1)
    XCTAssertEqual((w["events"] as? [[String: Any]])?.count, 1)
    XCTAssertNil(w["links"])
    XCTAssertEqual((w["scope"] as? [String: Any])?["name"] as? String, "Lib")
  }

  func testTraceparent() {
    let v = TraceparentCodec.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
    XCTAssertEqual(v?.traceId, "4bf92f3577b34da6a3ce929d0e0e4736")
    XCTAssertEqual(v?.sampled, true)
    for bad in ["", "x", "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
                "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01"] {
      XCTAssertNil(TraceparentCodec.parse(bad), bad)
    }
    XCTAssertEqual(TraceparentCodec.format(traceId: "a", spanId: "b", sampled: true), "00-a-b-01")
    let args: [String: Any] = ["_otel": ["traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"]]
    XCTAssertEqual(TraceparentCodec.fromChannelArguments(args)?.sampled, false)
    XCTAssertNil(TraceparentCodec.fromChannelArguments(["a": 1]))
  }
}
