# otel_flutter_bridge_dio

`dio` interceptor for
[otel_flutter_bridge](https://pub.dev/packages/otel_flutter_bridge): one
OpenTelemetry client span per request (HTTP semantic conventions) and the
W3C `traceparent` header, so the backend continues the trace.

```dart
final dio = Dio()
  ..interceptors.add(OtelDioInterceptor(
    propagateTo: {'api.example.com'}, // do not send trace ids to third parties
  ));
```

Records only method, host, port, scheme and path (normalized by redaction).
Never the full URL, query string, headers or bodies.
