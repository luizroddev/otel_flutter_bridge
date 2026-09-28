import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

Map<String, Object?> nativeSpan({
  String traceId = '4bf92f3577b34da6a3ce929d0e0e4736',
  String spanId = '00f067aa0ba902b7',
  String? parent,
  String name = 'native.op',
}) =>
    {
      'traceId': traceId,
      'spanId': spanId,
      if (parent != null) 'parentSpanId': parent,
      'name': name,
      'kind': 'client',
      'startTimeUnixNano': 1000,
      'endTimeUnixNano': 2000,
      'status': {'code': 'error', 'message': 'boom'},
      'attributes': {
        'app.step': 'x',
        'app.count': 3,
        'app.ratio': 0.5,
        'app.ok': true,
        'app.list': ['a', 1],
        'app.bad': {'nested': 1},
      },
      'events': [
        {
          'name': 'e',
          'timeUnixNano': 1500,
          'attributes': {'app.k': 'v'}
        },
        {'name': 'no time'},
      ],
      'links': [
        {'traceId': traceId, 'spanId': '1111111111111111'},
      ],
      'scope': {'name': 'MyNativeLib', 'version': '1.0'},
    };

void main() {
  test('decodes a valid batch', () {
    final batch = decodeNativeBatch({
      'v': 1,
      'resource': {'os.version': '17.5'},
      'spans': [nativeSpan(parent: 'aaaaaaaaaaaaaaaa')],
    });
    expect(batch.accepted, 1);
    expect(batch.rejected, 0);
    final rs = batch.resourceSpans!;
    expect(rs.resource.attributes.single.key, 'os.version');
    final ss = rs.scopeSpans.single;
    expect(ss.scope.name, 'MyNativeLib');
    final span = ss.spans.single;
    expect(span.name, 'native.op');
    expect(span.kind, pb.Span_SpanKind.SPAN_KIND_CLIENT);
    expect(span.traceId.length, 16);
    expect(span.parentSpanId.length, 8);
    expect(span.status.code, pb.Status_StatusCode.STATUS_CODE_ERROR);
    expect(span.attributes.map((a) => a.key),
        ['app.step', 'app.count', 'app.ratio', 'app.ok', 'app.list']);
    expect(span.events, hasLength(1));
    expect(span.links, hasLength(1));
  });

  test('skips malformed spans and counts them', () {
    final batch = decodeNativeBatch({
      'v': 1,
      'spans': [
        nativeSpan(),
        nativeSpan(traceId: 'xyz'),
        nativeSpan(spanId: '0000000000000000'),
        {'name': 'no ids'},
        'not a map',
        {...nativeSpan(), 'endTimeUnixNano': 1},
      ],
    });
    expect(batch.accepted, 1);
    expect(batch.rejected, 5);
  });

  test('rejects unknown versions and non-map payloads', () {
    expect(
        decodeNativeBatch({
          'v': 2,
          'spans': [nativeSpan()]
        }).rejected,
        1);
    expect(decodeNativeBatch(null).resourceSpans, isNull);
    expect(decodeNativeBatch('x').resourceSpans, isNull);
    expect(decodeNativeBatch({'v': 1}).resourceSpans, isNull);
  });

  test('groups spans by scope', () {
    final batch = decodeNativeBatch({
      'v': 1,
      'spans': [
        nativeSpan(),
        {
          ...nativeSpan(spanId: '2222222222222222'),
          'scope': {'name': 'Other'}
        },
        nativeSpan(spanId: '3333333333333333'),
      ],
    });
    expect(batch.resourceSpans!.scopeSpans.map((s) => s.spans.length), [2, 1]);
  });
}
