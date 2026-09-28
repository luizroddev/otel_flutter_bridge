import 'dart:async';
import 'dart:collection';

import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../otel_flutter_bridge_base.dart';
import '../pipeline.dart';
import '../semantics.dart';

/// Keeps the most recent exports so they can be shown on screen.
///
/// Everything it holds already went through redaction: it shows exactly
/// what left the device. Meant for debug builds and proofs of concept.
class TelemetryInspectorController extends ChangeNotifier {
  TelemetryInspectorController._();

  /// The shared controller.
  static final instance = TelemetryInspectorController._();

  /// Maximum exports kept in memory.
  int capacity = 200;

  final _records = ListQueue<ExportRecord>();
  StreamSubscription<ExportRecord>? _sub;

  /// Exports, newest first.
  List<ExportRecord> get records => _records.toList().reversed.toList();

  /// Exports the transport accepted.
  int get sentCount => _records.where((r) => r.success).length;

  /// Exports the transport rejected.
  int get failedCount => _records.where((r) => !r.success).length;

  /// Starts collecting from [pipeline] (defaults to the bridge's). Call it
  /// right after `OtelFlutterBridge.initialize` to catch early spans.
  void attach([TelemetryPipeline? pipeline]) {
    final p = pipeline ?? OtelFlutterBridge.pipeline;
    if (p == null) return;
    unawaited(_sub?.cancel());
    _sub = p.records.listen((r) {
      _records.add(r);
      while (_records.length > capacity) {
        _records.removeFirst();
      }
      notifyListeners();
    });
  }

  /// Forgets everything collected.
  void clear() {
    _records.clear();
    notifyListeners();
  }

  /// Spans grouped by trace id, newest trace first.
  List<InspectedTrace> get traces {
    final byTrace = <String, List<InspectedSpan>>{};
    for (final r in _records) {
      for (final rs in r.request.resourceSpans) {
        for (final ss in rs.scopeSpans) {
          for (final s in ss.spans) {
            final span = InspectedSpan(s, r, ss.scope.name);
            byTrace.putIfAbsent(span.traceId, () => []).add(span);
          }
        }
      }
    }
    final traces = byTrace.entries
        .map((e) => InspectedTrace(e.key, e.value))
        .toList()
      ..sort((a, b) => b.start.compareTo(a.start));
    return traces;
  }
}

/// A span as the inspector shows it.
class InspectedSpan {
  /// Wraps a sent span.
  InspectedSpan(this.span, this.record, this.scope);

  /// The span as sent.
  final pb.Span span;

  /// The export that carried it.
  final ExportRecord record;

  /// Instrumentation scope name.
  final String scope;

  /// Trace id, hex.
  String get traceId => _hex(span.traceId);

  /// Span id, hex.
  String get spanId => _hex(span.spanId);

  /// Parent span id, hex, or empty.
  String get parentSpanId => _hex(span.parentSpanId);

  /// Start time.
  DateTime get start => DateTime.fromMicrosecondsSinceEpoch(
        span.startTimeUnixNano.toInt() ~/ 1000,
      );

  /// Duration.
  Duration get duration => Duration(
        microseconds:
            (span.endTimeUnixNano - span.startTimeUnixNano).toInt() ~/ 1000,
      );

  /// `dart` or `native`.
  String get source => attribute(bridgeSourceKey) ?? '?';

  /// Whether the status is error.
  bool get isError =>
      span.status.code == pb.Status_StatusCode.STATUS_CODE_ERROR;

  /// A string form of an attribute value, or null.
  String? attribute(String key) {
    for (final a in span.attributes) {
      if (a.key == key) return _valueText(a.value);
    }
    return null;
  }
}

/// All spans of one trace.
class InspectedTrace {
  /// Groups [spans] of [traceId].
  InspectedTrace(this.traceId, List<InspectedSpan> spans)
      : spans = spans..sort((a, b) => a.start.compareTo(b.start));

  /// Trace id, hex.
  final String traceId;

  /// Spans, by start time.
  final List<InspectedSpan> spans;

  /// Earliest start.
  DateTime get start => spans.first.start;

  /// Spans in tree order with their depth. Spans whose parent was not
  /// received are roots.
  List<(InspectedSpan, int)> get tree {
    final ids = spans.map((s) => s.spanId).toSet();
    final children = <String, List<InspectedSpan>>{};
    final roots = <InspectedSpan>[];
    for (final s in spans) {
      if (s.parentSpanId.isEmpty || !ids.contains(s.parentSpanId)) {
        roots.add(s);
      } else {
        children.putIfAbsent(s.parentSpanId, () => []).add(s);
      }
    }
    final out = <(InspectedSpan, int)>[];
    void walk(InspectedSpan s, int depth) {
      out.add((s, depth));
      for (final c in children[s.spanId] ?? const <InspectedSpan>[]) {
        walk(c, depth + 1);
      }
    }

    for (final r in roots) {
      walk(r, 0);
    }
    return out;
  }
}

/// A full-screen page that shows what the bridge sent, live.
///
/// Drop it into a debug menu:
/// `Navigator.push(context, MaterialPageRoute(builder: (_) => const TelemetryInspectorPage()))`.
class TelemetryInspectorPage extends StatelessWidget {
  /// Creates the page.
  const TelemetryInspectorPage({super.key, this.controller});

  /// Defaults to [TelemetryInspectorController.instance].
  final TelemetryInspectorController? controller;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Telemetry inspector')),
        body: TelemetryInspectorView(controller: controller),
      );
}

/// The inspector without a scaffold, to embed in a tab.
class TelemetryInspectorView extends StatelessWidget {
  /// Creates the view.
  const TelemetryInspectorView({super.key, this.controller});

  /// Defaults to [TelemetryInspectorController.instance].
  final TelemetryInspectorController? controller;

  @override
  Widget build(BuildContext context) {
    final c = controller ?? TelemetryInspectorController.instance;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final traces = c.traces;
        return Column(
          children: [
            _Header(controller: c),
            const Divider(height: 1),
            Expanded(
              child: traces.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Nothing sent yet.\nSpans appear here after each '
                          'export, already redacted.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: traces.length,
                      itemBuilder: (context, i) => _TraceTile(traces[i]),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});
  final TelemetryInspectorController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = OtelFlutterBridge.sessionId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'session.id ${session == null ? '-' : _short(session)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [
                    _Chip('${controller.sentCount} sent', Colors.green),
                    _Chip('${controller.failedCount} failed', Colors.red),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Send pending now',
            icon: const Icon(Icons.send),
            onPressed: OtelFlutterBridge.flush,
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: controller.clear,
          ),
        ],
      ),
    );
  }
}

class _TraceTile extends StatelessWidget {
  const _TraceTile(this.trace);
  final InspectedTrace trace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final root = trace.tree.first.$1;
    final sources = trace.spans.map((s) => s.source).toSet();
    return ExpansionTile(
      initiallyExpanded: true,
      title: Text(root.span.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        'trace ${_short(trace.traceId)} · ${trace.spans.length} span(s) · '
        '${sources.join(' + ')}',
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
      trailing: IconButton(
        tooltip: 'Copy trace id (search it in Jaeger)',
        icon: const Icon(Icons.copy, size: 18),
        onPressed: () {
          unawaited(Clipboard.setData(ClipboardData(text: trace.traceId)));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Trace id copied')),
          );
        },
      ),
      children: [
        for (final (span, depth) in trace.tree) _SpanRow(span, depth),
      ],
    );
  }
}

class _SpanRow extends StatelessWidget {
  const _SpanRow(this.span, this.depth);
  final InspectedSpan span;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final native = span.source == bridgeSourceNative;
    return InkWell(
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _SpanDetails(span),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16.0 + depth * 18, 6, 16, 6),
        child: Row(
          children: [
            Icon(
              span.isError ? Icons.error : Icons.subdirectory_arrow_right,
              size: 16,
              color: span.isError ? Colors.red : Colors.grey,
            ),
            const SizedBox(width: 6),
            _Chip(native ? 'native' : 'dart',
                native ? Colors.deepPurple : Colors.blue),
            const SizedBox(width: 6),
            Expanded(
              child: Text(span.span.name, overflow: TextOverflow.ellipsis),
            ),
            Text('${span.duration.inMilliseconds} ms'),
          ],
        ),
      ),
    );
  }
}

class _SpanDetails extends StatelessWidget {
  const _SpanDetails(this.span);
  final InspectedSpan span;

  @override
  Widget build(BuildContext context) {
    final s = span.span;
    final mono = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(fontFamily: 'monospace');
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: SelectableText.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$k  ',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(text: v),
              ],
            ),
            style: mono,
          ),
        );
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.all(16),
        children: [
          Text(s.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          row('trace', span.traceId),
          row('span', span.spanId),
          row('parent', span.parentSpanId.isEmpty ? '-' : span.parentSpanId),
          row('kind', s.kind.name),
          row('scope', span.scope),
          row('duration', '${span.duration.inMicroseconds / 1000} ms'),
          row('status', '${s.status.code.name} ${s.status.message}'),
          if (s.droppedAttributesCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '${s.droppedAttributesCount} attribute(s) removed by redaction '
                '(not in the allowlist).',
                style: const TextStyle(color: Colors.orange),
              ),
            ),
          const Divider(),
          Text('Attributes', style: Theme.of(context).textTheme.titleSmall),
          for (final a in s.attributes) row(a.key, _valueText(a.value)),
          if (s.events.isNotEmpty) ...[
            const Divider(),
            Text('Events', style: Theme.of(context).textTheme.titleSmall),
            for (final e in s.events) ...[
              row('event', e.name),
              for (final a in e.attributes)
                row('  ${a.key}', _valueText(a.value)),
            ],
          ],
          const Divider(),
          Text(
            'Export: ${span.record.success ? 'accepted' : 'FAILED'} at '
            '${span.record.time.toIso8601String()}',
            style: mono,
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 11)),
      );
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _short(String id) => id.length > 12
    ? '${id.substring(0, 8)}…${id.substring(id.length - 4)}'
    : id;

String _valueText(pb.AnyValue v) => switch (v.whichValue()) {
      pb.AnyValue_Value.stringValue => v.stringValue,
      pb.AnyValue_Value.boolValue => '${v.boolValue}',
      pb.AnyValue_Value.intValue => '${v.intValue}',
      pb.AnyValue_Value.doubleValue => '${v.doubleValue}',
      pb.AnyValue_Value.arrayValue =>
        '[${v.arrayValue.values.map(_valueText).join(', ')}]',
      _ => '(${v.whichValue().name})',
    };
