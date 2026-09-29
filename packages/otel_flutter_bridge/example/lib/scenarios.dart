import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';
import 'package:otel_flutter_bridge_dio/otel_flutter_bridge_dio.dart';

import 'poc_config.dart';

/// The host app's own native channel. In a real app this already exists.
const nativeChannel = MethodChannel('poc/native');

final _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 3)))
  ..interceptors.add(OtelDioInterceptor());

/// The app's single `package:http` client, traced.
final _http = OtelHttpClient(http.Client());

Tracer get _tracer => OTel.tracer();

/// Runs [body] inside a span named [name], recording errors.
Future<String> _inSpan(String name, Future<String> Function(Span) body) async {
  final span = _tracer.startSpan(name);
  try {
    return await _tracer.withSpanAsync(span, () => body(span));
  } catch (e, st) {
    span
      ..recordException(e, stackTrace: st)
      ..setStatus(SpanStatusCode.Error, e.runtimeType.toString());
    return 'Erro: ${e.runtimeType}';
  } finally {
    span.end();
  }
}

/// One tappable scenario.
class Scenario {
  const Scenario(this.title, this.description, this.run);
  final String title;
  final String description;
  final Future<String> Function() run;
}

final scenarios = <Scenario>[
  Scenario(
    '1. Span simples (Dart)',
    'Um span com atributo app.*. Critério do M0.',
    () => _inSpan('poc.simple', (span) async {
      span.setStringAttribute('app.screen', 'home');
      return 'Span criado';
    }),
  ),
  Scenario(
    '2. Pai e filhos (Dart)',
    'checkout → validate + price. Hierarquia no Inspetor e no Jaeger.',
    () => _inSpan('checkout', (_) async {
      await _inSpan('checkout.validate', (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return '';
      });
      await _inSpan('checkout.price', (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        return '';
      });
      return 'Trace com 3 spans';
    }),
  ),
  Scenario(
    '3. Flutter → nativo',
    'Chamada de canal com traceparent; o nativo cria spans filhos.',
    () => _inSpan('cart.open', (_) async {
      final r = await nativeChannel.invokeTraced<String>('loadCart');
      return r ?? '';
    }),
  ),
  Scenario(
    '4. HTTP pelo dio',
    'Span de cliente + traceparent para o backend de demonstração.',
    () => _inSpan('orders.load', (_) async {
      final r =
          await _dio.get<Object?>('${PocConfig.demoBackend}/api/orders/12345');
      return 'HTTP ${r.statusCode}';
    }),
  ),
  Scenario(
    '5. Trace completo (M4)',
    'Ação Flutter → nativo → HTTP nativo → backend, tudo num trace.',
    () => _inSpan('checkout.confirm.tap', (_) async {
      final r = await nativeChannel.invokeTraced<String>(
        'loadCart',
        arguments: {'url': '${PocConfig.demoBackend}/api/cart'},
      );
      final h = await _dio.get<Object?>('${PocConfig.demoBackend}/api/stock');
      return '$r · dio ${h.statusCode}';
    }),
  ),
  Scenario(
    '6. Teste de redação',
    'Coloca CPF, e-mail, cartão e token no span. Veja o que sai.',
    () => _inSpan('login for ana@example.com', (span) async {
      span
        ..setStringAttribute('user.cpf', '123.456.789-09')
        ..setStringAttribute('app.note', 'cartao 4111 1111 1111 1111, ORD-1234')
        ..setStringAttribute('app.auth', 'Bearer eyJhbGciOiJIUzI1NiJ9.e30.x')
        ..setStringAttribute('url.path', '/v1/customers/98765/cards');
      return 'Abra o span no Inspetor';
    }),
  ),
  Scenario(
    '7. Erro no nativo',
    'O nativo marca erro com dados sensíveis na mensagem; saem limpos.',
    () => _inSpan('payment.tap', (_) async {
      await nativeChannel.invokeTraced<void>('nativeFailure');
      return 'ok';
    }),
  ),
  Scenario(
    '8. HTTP pelo package:http',
    'OtelHttpClient: span de cliente + traceparent, igual ao dio.',
    () => _inSpan('orders.load.http', (_) async {
      final r = await _http
          .get(Uri.parse('${PocConfig.demoBackend}/api/orders/12345'));
      return 'HTTP ${r.statusCode}';
    }),
  ),
];

/// Kill switch, as remote config would drive it.
Future<void> setTelemetryEnabled(bool value) =>
    OtelFlutterBridge.setEnabled(value);
