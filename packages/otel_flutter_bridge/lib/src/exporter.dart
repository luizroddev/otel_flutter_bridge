import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

import 'pipeline.dart';

/// Hands spans finished by the Dart SDK to the [TelemetryPipeline].
class BridgeSpanExporter implements SpanExporter {
  /// Creates an exporter that feeds [pipeline].
  BridgeSpanExporter(this.pipeline);

  /// Where spans go.
  final TelemetryPipeline pipeline;

  @override
  Future<void> export(List<Span> spans) async {
    if (spans.isEmpty) return;
    try {
      pipeline.submitDart(OtlpSpanTransformer.transformSpans(spans));
    } catch (_) {
      // Never let telemetry break the app; the pipeline reports its own errors.
    }
  }

  @override
  Future<void> forceFlush() => pipeline.flush();

  @override
  Future<void> shutdown() => pipeline.flush();
}
