# otel_flutter_bridge

OpenTelemetry for add-to-app Flutter apps: Dart and native (iOS) spans in one
trace and one session, with allowlist redaction on the device and no
swizzling.

See the [repository README](https://github.com/luizroddev/otel_flutter_bridge)
for the full guide, specs and the example app.

```dart
await OtelFlutterBridge.initialize(
  OtelBridgeConfig(
    serviceName: 'my-app',
    endpoint: Uri.parse('https://otel-collector.example.com'),
  ),
);
final span = OTel.tracer().startSpan('checkout.confirm');
// ...
span.end();
```

In-app inspector for debug builds:

```dart
import 'package:otel_flutter_bridge/inspector.dart';

TelemetryInspectorController.instance.attach(); // after initialize
Navigator.push(context, MaterialPageRoute(builder: (_) => const TelemetryInspectorPage()));
```
