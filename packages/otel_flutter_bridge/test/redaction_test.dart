import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

pb.KeyValue kv(String key, Object value) => pb.KeyValue(
      key: key,
      value: switch (value) {
        final String s => pb.AnyValue(stringValue: s),
        final int i => pb.AnyValue(intValue: Int64(i)),
        final bool b => pb.AnyValue(boolValue: b),
        final double d => pb.AnyValue(doubleValue: d),
        _ => throw ArgumentError(value),
      },
    );

pb.Span spanWith(List<pb.KeyValue> attrs, {String name = 'op'}) =>
    pb.Span(name: name, attributes: attrs);

Map<String, Object?> attrsOf(pb.Span span) => {
      for (final a in span.attributes)
        a.key: a.value.hasStringValue()
            ? a.value.stringValue
            : a.value.hasIntValue()
                ? a.value.intValue.toInt()
                : a.value.hasBoolValue()
                    ? a.value.boolValue
                    : a.value,
    };

void main() {
  final redactor = Redactor(const RedactionConfig());

  group('allowlist', () {
    test('drops attributes that are not allowed and counts them', () {
      final span = spanWith([
        kv('user.email', 'ana@example.com'),
        kv('customer.id', '123'),
        kv('http.request.method', 'GET'),
      ]);
      redactor.redactSpan(span);
      expect(attrsOf(span).keys, ['http.request.method']);
      expect(span.droppedAttributesCount, 2);
    });

    test('allows the app. prefix by default', () {
      final span = spanWith([kv('app.screen', 'home')]);
      redactor.redactSpan(span);
      expect(attrsOf(span), {'app.screen': 'home'});
    });

    test('custom prefixes and keys come from config', () {
      final r = Redactor(
        const RedactionConfig(
          allowedPrefixes: {'poc.'},
          allowedAttributes: {'feature.flag'},
        ),
      );
      final span = spanWith([
        kv('poc.step', 'login'),
        kv('feature.flag', 'on'),
        kv('app.note', 'x'),
      ]);
      r.redactSpan(span);
      expect(attrsOf(span).keys, unorderedEquals(['poc.step', 'feature.flag']));
    });

    test('default allowlist can be turned off', () {
      final r = Redactor(const RedactionConfig(useDefaultAllowlist: false));
      final span = spanWith([kv('http.request.method', 'GET')]);
      r.redactSpan(span);
      expect(span.attributes, isEmpty);
    });

    test('keeps numbers and booleans of allowed keys', () {
      final span = spanWith([
        kv('http.response.status_code', 200),
        kv('app.cached', true),
      ]);
      redactor.redactSpan(span);
      expect(attrsOf(span), {
        'http.response.status_code': 200,
        'app.cached': true,
      });
    });

    test('drops nested maps and bytes even under allowed keys', () {
      final span = pb.Span(
        attributes: [
          pb.KeyValue(
            key: 'app.nested',
            value: pb.AnyValue(kvlistValue: pb.KeyValueList()),
          ),
          pb.KeyValue(key: 'app.raw', value: pb.AnyValue(bytesValue: [1, 2])),
        ],
      );
      redactor.redactSpan(span);
      expect(span.attributes, isEmpty);
    });

    test('applies to resource, events and links', () {
      final request = pb.ExportTraceServiceRequest(
        resourceSpans: [
          pb.ResourceSpans(
            resource: pb.Resource(
              attributes: [kv('service.name', 'a'), kv('host.name', 'mbp')],
            ),
            scopeSpans: [
              pb.ScopeSpans(
                spans: [
                  pb.Span(
                    events: [
                      pb.Span_Event(
                        name: 'exception',
                        attributes: [
                          kv('exception.type', 'StateError'),
                          kv('exception.stacktrace', 'secret frames'),
                        ],
                      ),
                    ],
                    links: [
                      pb.Span_Link(attributes: [kv('user.id', '42')]),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      redactor.redactRequest(request);
      final rs = request.resourceSpans.single;
      expect(rs.resource.attributes.map((a) => a.key), ['service.name']);
      expect(rs.resource.droppedAttributesCount, 1);
      final span = rs.scopeSpans.single.spans.single;
      expect(span.events.single.attributes.map((a) => a.key), [
        'exception.type',
      ]);
      expect(span.links.single.attributes, isEmpty);
    });
  });

  group('scrubbing', () {
    String scrub(String v) => redactor.scrub(v);

    final cases = <String, String>{
      'e-mail': 'falha para ana.silva+test@example.com.br',
      'JWT': 'token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc-DEF_123',
      'bearer': 'Authorization: Bearer abc.DEF-123~xyz',
      'basic': 'basic dXNlcjpwYXNz',
      'UUID': 'conta 123e4567-e89b-12d3-a456-426614174000 bloqueada',
      'CPF with separators': 'cpf 123.456.789-09',
      'CPF digits only': 'cpf 12345678909',
      'CNPJ': '12.345.678/0001-95',
      'card number': 'cartao 4111 1111 1111 1111',
      'phone': 'ligar +55 11 91234-5678',
      'account number': 'conta 0012345-6',
      'IPv4': 'origem 192.168.100.200',
      'query string': 'GET https://api.example.com/v1/x?cpf=1&token=abc',
    };

    for (final e in cases.entries) {
      test('removes ${e.key}', () {
        final out = scrub(e.value);
        expect(out, contains(redactedMarker), reason: out);
        for (final secret in [
          'ana.silva',
          'eyJhbGci',
          'abc.DEF',
          'dXNlcjpw',
          '123e4567',
          '456.789',
          '12345678909',
          '0001-95',
          '1111 1111',
          '91234',
          '0012345',
          '168.100',
          'token=abc',
        ]) {
          expect(out, isNot(contains(secret)), reason: out);
        }
      });
    }

    test('keeps harmless text', () {
      expect(scrub('Tela de extrato carregada'), 'Tela de extrato carregada');
      expect(scrub('17.5.1'), '17.5.1');
      expect(scrub('HTTP 404'), 'HTTP 404');
    });

    test('scrubs span names, event names and status messages', () {
      final span = pb.Span(
        name: 'load ana@example.com',
        events: [pb.Span_Event(name: 'sent to 11912345678')],
        status: pb.Status(message: 'failed for 123.456.789-09'),
      );
      redactor.redactSpan(span);
      expect(span.name, 'load $redactedMarker');
      expect(span.events.single.name, 'sent to $redactedMarker');
      expect(span.status.message, 'failed for $redactedMarker');
    });

    test('scrubs every string in arrays', () {
      final span = pb.Span(
        attributes: [
          pb.KeyValue(
            key: 'app.list',
            value: pb.AnyValue(
              arrayValue: pb.ArrayValue(
                values: [
                  pb.AnyValue(stringValue: 'ok'),
                  pb.AnyValue(stringValue: 'x@y.com'),
                ],
              ),
            ),
          ),
        ],
      );
      redactor.redactSpan(span);
      expect(
        span.attributes.single.value.arrayValue.values
            .map((v) => v.stringValue),
        ['ok', redactedMarker],
      );
    });

    test('extra patterns come from config; invalid ones are ignored', () {
      final r = Redactor(
        const RedactionConfig(extraPatterns: [r'ORD\d{2}', '(unclosed']),
      );
      expect(r.scrub('pedido ORD12'), 'pedido $redactedMarker');
    });

    test('truncates long values', () {
      final r = Redactor(const RedactionConfig(), maxValueLength: 10);
      expect(r.scrub('a' * 50), 'a' * 10);
    });

    test('never scrubs app identity attributes', () {
      final span = spanWith([
        kv('service.name', 'app-build-20260927123456'),
        kv('service.version', '1.2.3+4567890'),
      ]);
      redactor.redactSpan(span);
      expect(attrsOf(span), {
        'service.name': 'app-build-20260927123456',
        'service.version': '1.2.3+4567890',
      });
    });

    test('never scrubs trusted attributes generated by the library', () {
      final id = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
      final span = spanWith([kv(sessionIdKey, id)]);
      redactor.redactSpan(span);
      expect(attrsOf(span)[sessionIdKey], id);
    });
  });

  group('url.path', () {
    test('replaces identifier segments and drops the query', () {
      final span = spanWith([
        kv('url.path',
            '/v1/customers/12345/cards/9f8e7d6c5b4a39281706f5e4?full=1'),
        kv('http.route', '/v1/users/abc123/profile'),
      ]);
      redactor.redactSpan(span);
      expect(attrsOf(span), {
        'url.path': '/v1/customers/{id}/cards/{id}',
        'http.route': '/v1/users/{id}/profile',
      });
    });

    test('url.full is not allowed by default', () {
      final span = spanWith([kv('url.full', 'https://x.com/a?b=c')]);
      redactor.redactSpan(span);
      expect(span.attributes, isEmpty);
    });
  });

  test('config fromMap reads remote values', () {
    final c = RedactionConfig.fromMap({
      'allowedAttributes': ['a.b'],
      'allowedPrefixes': ['x.'],
      'extraPatterns': ['foo'],
      'useDefaultScrubbers': false,
    });
    expect(c.allowedAttributes, {'a.b'});
    expect(c.allowedPrefixes, {'x.'});
    expect(c.extraPatterns, ['foo']);
    expect(c.useDefaultScrubbers, isFalse);
    expect(c.useDefaultAllowlist, isTrue);
  });
}
