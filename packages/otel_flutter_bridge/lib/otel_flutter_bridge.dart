/// OpenTelemetry for add-to-app Flutter apps: one pipeline for Dart and
/// native spans, W3C trace context across the platform channel, and
/// privacy-by-default redaction.
library;

export 'src/app_context.dart'
    show AppContext, AppContextSpanProcessor, AppContextValues;
export 'src/channel_propagation.dart';
export 'src/config.dart';
export 'src/diagnostics.dart';
export 'src/exporter.dart';
export 'src/http_client.dart';
export 'src/native_batch.dart' show DecodedNativeBatch, decodeNativeBatch;
export 'src/native_bridge.dart';
export 'src/otel_flutter_bridge_base.dart';
export 'src/pipeline.dart';
export 'src/redaction.dart';
export 'src/semantics.dart';
export 'src/session.dart';
export 'src/traced_handler.dart';
export 'src/traceparent.dart';
export 'src/transport.dart';
