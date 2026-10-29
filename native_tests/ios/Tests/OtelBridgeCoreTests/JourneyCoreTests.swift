import XCTest
@testable import OtelBridgeCore

private func flowRun(_ id: String, code: String = "login", parent: String? = nil) -> JourneyFlowState {
  JourneyFlowState(code: code, label: nil, instanceId: id, parentInstanceId: parent, startUnixNano: 1_000)
}

final class JourneyStateTests: XCTestCase {
  func testNestedRunsAndCurrentFlow() {
    let store = AppContextStore()
    store.pushFlow(flowRun("outer"))
    store.pushFlow(flowRun("inner", code: "activation", parent: "outer"))
    XCTAssertEqual(store.flow, "activation")
    XCTAssertEqual(store.flowId, "inner")
    XCTAssertEqual(store.openFlow(code: "login")?.instanceId, "outer")

    XCTAssertEqual(store.removeFlow(instanceId: "inner")?.code, "activation")
    XCTAssertEqual(store.flowId, "outer")
    // Ending twice, here or after Dart ended it, does nothing.
    XCTAssertNil(store.removeFlow(instanceId: "inner"))
    // A run already known is not added again.
    store.pushFlow(flowRun("outer"))
    XCTAssertEqual(store.openFlows.count, 1)
  }

  func testRemovingAnotherRunKeepsAValueSetByHand() {
    let store = AppContextStore()
    store.pushFlow(flowRun("a"))
    store.flow = "manual"
    store.flowId = "manual-id"
    store.pushFlow(flowRun("b"))
    store.flowId = "manual-id"
    store.removeFlow(instanceId: "b")
    XCTAssertEqual(store.flowId, "manual-id")
  }

  func testAppliesChangesFromDart() {
    let store = AppContextStore()
    JourneySync.apply(["op": "screen", "code": "password"], to: store)
    JourneySync.apply(["op": "user", "id": "u-1"], to: store)
    JourneySync.apply(["op": "flowStart", "run": flowRun("d1").wireValue], to: store)
    XCTAssertEqual(store.screen, "password")
    XCTAssertEqual(store.userId, "u-1")
    XCTAssertEqual(store.flowId, "d1")
    JourneySync.apply(["op": "flowEnd", "instanceId": "d1"], to: store)
    XCTAssertNil(store.flowId)
    JourneySync.apply(["op": "user", "id": ""], to: store)
    XCTAssertNil(store.userId)
    JourneySync.apply(["op": "screen"], to: store)
    XCTAssertNil(store.screen)
    // Malformed or unknown changes are ignored.
    JourneySync.apply("x", to: store)
    JourneySync.apply(["op": "flowStart", "run": ["code": "login"]], to: store)
    JourneySync.apply(["op": "other"], to: store)
    XCTAssertTrue(store.openFlows.isEmpty)
  }

  func testReadyMergeKeepsNativeValuesAndAddsDartRuns() {
    let store = AppContextStore()
    store.screen = "Login.document"
    store.pushFlow(flowRun("n1"))
    let dart: [String: Any] = [
      "screen": "home", "userId": "u-2",
      "flows": [flowRun("n1").wireValue, flowRun("d1", code: "checkout").wireValue],
    ]
    JourneySync.merge(dart, into: store)
    XCTAssertEqual(store.screen, "Login.document")
    XCTAssertEqual(store.userId, "u-2")
    XCTAssertEqual(store.openFlows.map(\.instanceId), ["n1", "d1"])

    store.setSession("s-1")
    let state = JourneySync.state(of: store)
    XCTAssertEqual(state["screen"] as? String, "Login.document")
    XCTAssertEqual(state["userId"] as? String, "u-2")
    XCTAssertEqual(state["sessionId"] as? String, "s-1")
    XCTAssertEqual((state["flows"] as? [[String: Any]])?.count, 2)
  }

  func testFlowRunRoundTrip() {
    let wire = JourneyFlowState(code: "login", label: "Entrar", instanceId: "i", parentInstanceId: "p",
                                startUnixNano: 1_700_000_000_000_000_000).wireValue
    XCTAssertEqual(JourneyFlowState(wire: wire),
                   JourneyFlowState(code: "login", label: "Entrar", instanceId: "i", parentInstanceId: "p",
                                    startUnixNano: 1_700_000_000_000_000_000))
    XCTAssertNil(JourneyFlowState(wire: ["code": "login", "instanceId": "", "startUnixNano": 1]))
  }

  func testSessionChangesOnlyOnNewId() {
    let store = AppContextStore()
    XCTAssertNil(store.sessionId)
    XCTAssertTrue(store.setSession("s-1"))
    XCTAssertFalse(store.setSession("s-1"))
    XCTAssertEqual(store.snapshot.sessionId, "s-1")
    store.clear()
    XCTAssertNil(store.sessionId)
  }
}

final class JourneyRecordTests: XCTestCase {
  func testEventCarriesTheContextItHappenedIn() {
    let ctx = JourneyContext(values: AppContextValues(screen: "Login.document", flow: "login", flowId: "r1"),
                             userId: "u-1", sessionId: "s-1")
    let record = BridgeLogRecord.journey("journey.screen.view",
                                         attributes: ["journey.screen.label": .string("Documento"),
                                                      "app.screen.name": .string("override")],
                                         context: ctx, timeUnixNano: 10)
    let a = record.attributes
    XCTAssertEqual(a["event.name"], .string("journey.screen.view"))
    XCTAssertEqual(a["session.id"], .string("s-1"))
    XCTAssertEqual(a["user.id"], .string("u-1"))
    XCTAssertEqual(a["journey.flow.instance_id"], .string("r1"))
    XCTAssertEqual(a["otel_flutter_bridge.source"], .string("native"))
    // The app's attributes win, as in Dart.
    XCTAssertEqual(a["app.screen.name"], .string("override"))
    if case let .string(uid)? = a["log.record.uid"] {
      XCTAssertEqual(uid.count, 32)
    } else {
      XCTFail("no log.record.uid")
    }
    XCTAssertNil(record.wireValue["traceId"])
  }

  func testWithoutHostSessionDartStampsIt() {
    let record = BridgeLogRecord.journey("journey.action", attributes: [:], context: JourneyContext(),
                                         timeUnixNano: 10)
    XCTAssertNil(record.attributes["session.id"])
    XCTAssertNil(record.attributes["user.id"])
  }

  func testLinkedToItsSpan() {
    let record = BridgeLogRecord.journey("journey.action", attributes: [:], context: JourneyContext(),
                                         timeUnixNano: 10, traceId: String(repeating: "a", count: 32),
                                         spanId: String(repeating: "b", count: 16), sampled: false)
    let wire = record.wireValue
    XCTAssertEqual(wire["traceId"] as? String, String(repeating: "a", count: 32))
    XCTAssertEqual(wire["spanId"] as? String, String(repeating: "b", count: 16))
    XCTAssertEqual(wire["flags"] as? Int, 0)
    XCTAssertEqual(wire["observedTimeUnixNano"] as? Int, 10)
  }

  func testIdsAreRandomHex() {
    let a = JourneyIds.new()
    XCTAssertEqual(a.count, 32)
    XCTAssertTrue(a.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    XCTAssertNotEqual(a, JourneyIds.new())
  }

  func testBatches() {
    let records = (0..<5).map { BridgeLogRecord(name: "e\($0)", timeUnixNano: $0) }
    let batches = BridgeLogBatchEncoder.encode(records, maxBatchSize: 2)
    XCTAssertEqual(batches.count, 3)
    XCTAssertEqual(batches[0]["v"] as? Int, 1)
    XCTAssertEqual((batches[2]["events"] as? [[String: Any]])?.count, 1)
  }
}

final class PendingEventQueueTests: XCTestCase {
  func testWaitsForDartThenSends() {
    let queue = PendingEventQueue(capacity: 3, maxBatchSize: 10)
    var sent: [[String: Any]] = []
    queue.setSink { sent.append($0) }
    queue.enqueue((0..<4).map { BridgeLogRecord(name: "e\($0)", timeUnixNano: $0) })
    XCTAssertTrue(sent.isEmpty)
    XCTAssertEqual(queue.count, 3)
    XCTAssertEqual(queue.droppedCount, 1)

    queue.markReady(enabled: true, maxBatchSize: 2)
    XCTAssertEqual(sent.count, 2)
    let first = (sent[0]["events"] as? [[String: Any]])?.first
    XCTAssertEqual(first?["name"] as? String, "e1") // the oldest was dropped
    queue.enqueue([BridgeLogRecord(name: "late", timeUnixNano: 9)])
    XCTAssertEqual(sent.count, 3)
  }

  func testDisabledDropsEverything() {
    let queue = PendingEventQueue()
    queue.enqueue([BridgeLogRecord(name: "e", timeUnixNano: 1)])
    queue.setEnabled(false)
    XCTAssertEqual(queue.count, 0)
    queue.enqueue([BridgeLogRecord(name: "e", timeUnixNano: 1)])
    XCTAssertEqual(queue.droppedCount, 2)
  }
}

final class DeviceInfoTests: XCTestCase {
  func testResourceAttributes() {
    let attrs = DeviceInfo.resourceAttributes
    XCTAssertEqual(attrs["device.manufacturer"], "Apple")
    XCTAssertEqual(attrs["os.type"], "darwin")
    XCTAssertNotNil(attrs["os.version"])
    XCTAssertFalse(attrs["device.model.identifier"]?.isEmpty ?? true)
  }

  func testOSVersionFormat() {
    XCTAssertEqual(DeviceInfo.osVersion(OperatingSystemVersion(majorVersion: 17, minorVersion: 5, patchVersion: 0)),
                   "17.5")
    XCTAssertEqual(DeviceInfo.osVersion(OperatingSystemVersion(majorVersion: 17, minorVersion: 5, patchVersion: 1)),
                   "17.5.1")
  }
}
