import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

// A small Bloc shaped like the ones in real apps. `bloc` is only a dev
// dependency: tracedHandler does not import it.

sealed class OrdersEvent {}

enum OrderFilter { open, closed }

class LoadOrders extends OrdersEvent {
  LoadOrders(this.filter, this.customerEmail);
  final OrderFilter filter;
  final String customerEmail;

  @override
  String toString() => 'LoadOrders($filter, $customerEmail)';
}

class FailOrders extends OrdersEvent {}

class SyncEvent extends OrdersEvent {}

class OrdersBloc extends Bloc<OrdersEvent, String> {
  OrdersBloc(this._client) : super('initial') {
    on<LoadOrders>(tracedHandler(
      'orders.load',
      _onLoad,
      enrich: (span, event) =>
          span.setStringAttribute('app.orders.filter', event.filter.name),
    ));
    on<FailOrders>(tracedHandler('orders.fail', _onFail));
    on<SyncEvent>(tracedHandler('orders.sync', _onSync));
  }

  final http.Client _client;
  final errors = <Object>[];

  Future<void> _onLoad(LoadOrders event, Emitter<String> emit) async {
    emit('loading');
    await _client.get(Uri.parse('https://api.example.com/v1/orders'));
    emit('loaded');
  }

  Future<void> _onFail(FailOrders event, Emitter<String> emit) async {
    emit('loading');
    throw const OrdersFailure();
  }

  void _onSync(SyncEvent event, Emitter<String> emit) => emit('sync');

  @override
  void onError(Object error, StackTrace stackTrace) {
    errors.add(error);
    super.onError(error, stackTrace);
  }
}

class OrdersFailure implements Exception {
  const OrdersFailure();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InMemoryTransport transport;
  final okClient = OtelHttpClient(
    MockClient((_) async => http.Response('[]', 200)),
  );

  Future<void> init() => OtelFlutterBridge.initialize(
        OtelBridgeConfig(serviceName: 't', endpoint: Uri.parse('http://x')),
        transport: transport,
        connectNative: false,
        scheduleDelay: const Duration(milliseconds: 10),
      );

  setUp(() => transport = InMemoryTransport());

  tearDown(() async {
    await OtelFlutterBridge.shutdown();
    await OTel.reset();
  });

  pb.Span named(String name) =>
      transport.spans.singleWhere((s) => s.name == name);

  test('handler span is the parent of the HTTP span', () async {
    await init();
    final bloc = OrdersBloc(okClient);
    final states = bloc.stream.take(2).toList();
    bloc.add(LoadOrders(OrderFilter.open, 'ana@example.com'));
    expect(await states, ['loading', 'loaded']);
    await bloc.close();
    await OtelFlutterBridge.flush();

    final handler = named('orders.load');
    final request = named('GET');
    expect(request.traceId, handler.traceId);
    expect(request.parentSpanId, handler.spanId);
    expect(handler.parentSpanId, isEmpty);
    expect(handler.status.code, isNot(pb.Status_StatusCode.STATUS_CODE_ERROR));
  });

  test('records only enrich values, never the event', () async {
    await init();
    final bloc = OrdersBloc(okClient);
    final done = bloc.stream.firstWhere((s) => s == 'loaded');
    bloc.add(LoadOrders(OrderFilter.closed, 'ana@example.com'));
    await done;
    await bloc.close();
    await OtelFlutterBridge.flush();

    final attrs = {
      for (final a in named('orders.load').attributes)
        a.key: a.value.stringValue,
    };
    expect(attrs, containsPair('app.orders.filter', 'closed'));
    final everything = transport.requests.map((r) => r.toString()).join();
    expect(everything, isNot(contains('ana@example.com')));
    expect(everything, isNot(contains('LoadOrders')));
  });

  test('handler error: span marked, same error reaches onError', () async {
    await init();
    final uncaught = <Object>[];
    late OrdersBloc bloc;
    await runZonedGuarded(() async {
      bloc = OrdersBloc(okClient);
      bloc.add(FailOrders());
      await bloc.stream.first;
      await pumpEventQueue();
    }, (e, _) => uncaught.add(e));
    await bloc.close();
    await OtelFlutterBridge.flush();

    expect(bloc.errors.single, isA<OrdersFailure>());
    expect(uncaught.single, same(bloc.errors.single));
    final span = named('orders.fail');
    expect(span.status.code, pb.Status_StatusCode.STATUS_CODE_ERROR);
    final attrs = {
      for (final a in span.attributes) a.key: a.value.stringValue,
    };
    expect(attrs, containsPair('error.type', 'OrdersFailure'));
  });

  test('sync handlers keep working', () async {
    await init();
    final bloc = OrdersBloc(okClient);
    final state = bloc.stream.first;
    bloc.add(SyncEvent());
    expect(await state, 'sync');
    await bloc.close();
    await OtelFlutterBridge.flush();
    expect(named('orders.sync').name, 'orders.sync');
  });

  test('handler errors keep their stack trace and are not printed', () async {
    await init();
    final printed = <String>[];
    final original = StackTrace.current;
    final handler = tracedHandler<String, int>(
      'x.fails',
      (a, b) => Error.throwWithStackTrace(
        StateError('customer ana@example.com'),
        original,
      ),
    );
    Object? caught;
    StackTrace? caughtStack;
    await runZoned(
      () async {
        try {
          await handler('a', 1);
        } catch (e, st) {
          caught = e;
          caughtStack = st;
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (_, __, ___, line) => printed.add(line),
      ),
    );
    await OtelFlutterBridge.flush();

    expect(caught, isA<StateError>());
    expect(caughtStack.toString(), original.toString());
    expect(printed.join('\n'), isNot(contains('ana@example.com')));
    expect(
      named('x.fails').status.code,
      pb.Status_StatusCode.STATUS_CODE_ERROR,
    );
  });

  test('a handled error can still mark the active span', () async {
    await init();
    final handler = tracedHandler<String, int>('x.handled', (a, b) async {
      try {
        throw const OrdersFailure();
      } on OrdersFailure {
        Context.current.span
          ?..setStringAttribute('error.type', 'OrdersFailure')
          ..setStatus(SpanStatusCode.Error);
      }
    });
    await handler('a', 1);
    await OtelFlutterBridge.flush();
    expect(
      named('x.handled').status.code,
      pb.Status_StatusCode.STATUS_CODE_ERROR,
    );
  });

  test('without initialize, the handler runs untraced', () async {
    final calls = <String>[];
    final handler = tracedHandler<String, int>(
      'x.y',
      (a, b) => calls.add('$a$b'),
    );
    await handler('a', 1);
    expect(calls, ['a1']);
  });

  test('a throwing enricher never breaks the handler', () async {
    await init();
    var ran = false;
    final handler = tracedHandler<String, int>(
      'x.y',
      (a, b) async => ran = true,
      enrich: (_, __) => throw StateError('bug'),
    );
    await handler('a', 1);
    await OtelFlutterBridge.flush();
    expect(ran, isTrue);
    expect(named('x.y').name, 'x.y');
  });
}
