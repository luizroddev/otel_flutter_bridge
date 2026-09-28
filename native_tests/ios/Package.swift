// swift-tools-version:5.9
// Unit tests for the Foundation-only core of the iOS plugin. The sources are
// a symlink to packages/otel_flutter_bridge/ios/Classes/Core, so the tests
// run with `swift test` on any Mac, without Flutter or a simulator.
import PackageDescription

let package = Package(
  name: "OtelBridgeCore",
  platforms: [.macOS(.v12), .iOS(.v13)],
  targets: [
    .target(name: "OtelBridgeCore", path: "Sources/OtelBridgeCore"),
    .testTarget(name: "OtelBridgeCoreTests", dependencies: ["OtelBridgeCore"]),
  ]
)
