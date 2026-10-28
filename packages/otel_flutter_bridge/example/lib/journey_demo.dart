import 'package:http/http.dart' as http;
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

import 'poc_config.dart';

// A fictional shop. A real app declares its own enums like these.

enum ShopScreen with JourneyScreen {
  home('Início'),
  login('Login'),
  catalog('Catálogo'),
  cart('Carrinho');

  const ShopScreen(this.label);

  @override
  final String label;
}

enum ShopFlow with JourneyFlow {
  login('Login'),
  checkout('Compra');

  const ShopFlow(this.label);

  @override
  final String label;
}

enum ShopAction with JourneyAction {
  chooseSavedLogin('Escolheu login salvo'),
  chooseBiometric('Escolheu biometria'),
  confirmLogin('Confirmou o login'),
  addToCart('Adicionou ao carrinho'),
  pay('Pagou');

  const ShopAction(this.label);

  @override
  final String label;
}

enum LoginMethod { biometric, password }

final _http = OtelHttpClient(http.Client());

/// A synthetic session: login fails once, the retry works, then a purchase.
/// Nothing here calls a real service except the demo backend.
Future<String> runShopJourney() async {
  Journey.screen(ShopScreen.home);
  Journey.screen(ShopScreen.login);

  final login = Journey.startFlow(ShopFlow.login);
  Journey.event(ShopAction.chooseSavedLogin);
  Journey.event(
    ShopAction.chooseBiometric,
    attributes: {'app.login.method': LoginMethod.biometric},
  );

  for (var attempt = 1; attempt <= 2; attempt++) {
    final ok = await Journey.track(
      ShopAction.confirmLogin,
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return attempt > 1; // the first attempt fails
      },
      attributes: {'app.login.attempt': attempt},
      outcome: (ok) => ok ? JourneyOutcome.success : JourneyOutcome.failure,
    );
    if (ok) break;
  }
  login.end(JourneyOutcome.success);
  Journey.setUser('demo-user-1');

  Journey.screen(ShopScreen.catalog);
  final checkout = Journey.startFlow(ShopFlow.checkout);
  Journey.event(ShopAction.addToCart, attributes: {'app.cart.items': 2});
  Journey.screen(ShopScreen.cart);
  final status = await Journey.track(
    ShopAction.pay,
    () async {
      try {
        final r =
            await _http.post(Uri.parse('${PocConfig.demoBackend}/api/pay'));
        return r.statusCode;
      } catch (_) {
        return 0; // demo backend not running
      }
    },
    outcome: (s) => s == 200 ? JourneyOutcome.success : JourneyOutcome.failure,
  );
  checkout.end(status == 200 ? JourneyOutcome.success : JourneyOutcome.failure);

  await OtelFlutterBridge.flush();
  return status == 200
      ? 'Jornada enviada (login com nova tentativa + compra)'
      : 'Jornada enviada (pagamento falhou: rode make backend)';
}
