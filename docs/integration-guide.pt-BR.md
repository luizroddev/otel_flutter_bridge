# Guia de integração em um app existente (pt-BR)

Passo a passo para adicionar a biblioteca a um app add-to-app que já existe
(host iOS nativo com módulo Flutter) e ver o resultado rápido. Tudo que é
específico do seu app fica no seu app; a biblioteca não precisa de nenhuma
alteração.

O caminho tem duas camadas, nesta ordem:

1. **Jornada**: telas, fluxos, ações e o usuário, como eventos (logs OTLP).
   É o que responde "o que o cliente fez e onde parou".
2. **Traces**: o detalhe técnico de cada ação (Flutter → canal → nativo →
   HTTP → backend), para abrir a partir da jornada.

## 1. Ver a biblioteca funcionando sozinha (15 min)

Para ver a jornada, suba o
[otel-journey-dashboard](https://github.com/luizroddev/otel-journey-dashboard)
(`docker compose up`: painel em http://localhost:8686, OTLP em `:4318`).
Para ver só traces, o Jaeger do repositório serve:

```bash
make up          # Jaeger em http://localhost:16686 (só traces)
make backend     # backend de demonstração em :8080
make example-ios # app de exemplo no simulador
```

No app de exemplo, rode os cenários e abra a aba **Inspetor**:

- cenário 5: o trace completo, ação Flutter → canal → nativo → HTTP nativo →
  backend;
- cenário 6: a redação (o documento some; cartão e token viram
  `[REDACTED]`);
- cenário 10: uma jornada de loja (login com nova tentativa, depois compra);
- cenário 11: uma compra que começa no Flutter e termina numa tela nativa.

O Jaeger só recebe traces: com ele, use `exportLogs: false` (a jornada não
aparece lá).

## 2. Dependência

Enquanto os pacotes não estão no pub.dev, use o git com uma referência fixa
(tag ou commit), nunca uma branch. A jornada exige uma versão posterior à
`v0.1.0-dev.3`:

```yaml
dependencies:
  otel_flutter_bridge:
    git:
      url: https://github.com/luizroddev/otel_flutter_bridge
      path: packages/otel_flutter_bridge
      ref: <tag ou commit validado>
  otel_flutter_bridge_dio:            # só se o app usa dio
    git:
      url: https://github.com/luizroddev/otel_flutter_bridge
      path: packages/otel_flutter_bridge_dio
      ref: <mesma referência>

# Necessário enquanto o núcleo não está no pub.dev: o pacote dio o pede de lá.
dependency_overrides:
  otel_flutter_bridge:
    git:
      url: https://github.com/luizroddev/otel_flutter_bridge
      path: packages/otel_flutter_bridge
      ref: <mesma referência>
```

No iOS a biblioteca usa CocoaPods (`OpenTelemetry-Swift-Api` e `-Sdk` 2.5.1).

## 3. Inicialização

### Nativo (host iOS)

No `application(_:didFinishLaunchingWithOptions:)`, antes de subir a engine
Flutter:

```swift
import otel_flutter_bridge

OtelFlutterBridge.shared.start()
HTTPClientSpan.propagateTo = ["api.meuapp.com"]   // traceparent só para a sua API
```

Modelo do aparelho, versão do iOS e tipo de conexão entram sozinhos. Dois
opcionais:

- **O app já tem uma sessão** (nasce no nativo e tem regras próprias de
  renovação): informe-a ao iniciar e a cada sessão nova, e use
  `SessionConfig(fromHost: true)` no Dart.

  ```swift
  OtelFlutterBridge.shared.setSession(id: sessao.id, previousId: anterior?.id)
  ```

- **A telemetria precisa sair pela rede do app** (pinning, headers do
  gateway, TLS mútuo): use `sendThroughNative: true` no Dart e envie aqui.
  O pedido vem marcado e nunca é rastreado.

  ```swift
  OtelFlutterBridge.shared.exportHandler = { export, completion in
    guard let request = export.urlRequest() else { return completion(false) }
    apiClient.send(request) { response in completion(response.isSuccess) }
  }
  ```

Se o app já registra um `TracerProvider` próprio, use
`registerGlobal: false` e adicione `makeAppContextProcessor()` e
`makeSpanProcessor()` ao provider existente.

### Dart (módulo Flutter)

No `main()` do módulo, depois de `WidgetsFlutterBinding.ensureInitialized()`:

```dart
await OtelFlutterBridge.initialize(
  OtelBridgeConfig(
    serviceName: 'meu-app',
    serviceVersion: '1.0.0',
    deploymentEnvironment: 'dev',
    endpoint: Uri.parse('http://IP-DO-SEU-MAC:4318'),
    installationId: idDaInstalacao,          // iOS: identifierForVendor
    // session: const SessionConfig(fromHost: true),  // sessão do nativo
    // sendThroughNative: true,                       // rede do app
    // gzip: true,                                    // se o receptor aceita
    redaction: const RedactionConfig(
      extraPatterns: [/* identificadores próprios, ex.: r'PED-\d+' */],
    ),
  ),
  onDiagnostic: (d) => debugPrint('[otel] $d'),
);
TelemetryInspectorController.instance.attach();
```

Em aparelho físico, `localhost` não funciona: use o IP do Mac na rede
(`ipconfig getifaddr en0`) e, só em builds de desenvolvimento, libere HTTP
local no `Info.plist` do host (`NSAppTransportSecurity >
NSAllowsLocalNetworking = YES`).

O que estiver pendente é enviado quando o app sai do primeiro plano (no
iOS, dentro de uma tarefa em segundo plano). Nada a configurar.

## 4. Instrumentar a jornada

Declare as telas, fluxos, ações e motivos do app como enums comuns. O código
de cada valor é o nome do enum e nunca deve mudar de sentido depois de
publicado.

```dart
enum AppScreen with JourneyScreen { home, login, cart }
enum AppFlow with JourneyFlow { login, checkout }
enum AppAction with JourneyAction { chooseBiometric, confirmLogin, pay }
enum LoginReason with JourneyReason { invalidPassword, blockedAccount }
```

Uma linha onde importa:

```dart
MaterialApp(navigatorObservers: [JourneyNavigatorObserver()]); // telas

final login = Journey.startFlow(AppFlow.login);       // começo do fluxo
Journey.event(AppAction.chooseBiometric);             // escolha pontual
final r = await Journey.track(AppAction.confirmLogin, auth.login,  // ação medida
    outcome: (r) => r.ok ? JourneyOutcome.success : JourneyOutcome.failure,
    reason: (r) => r.reason);
login.end(r.ok ? JourneyOutcome.success : JourneyOutcome.failure,
    reason: r.reason);
Journey.setUser(usuario.idOpaco);                     // depois do login; null no logout
```

- `Journey.track` cria o span da ação: o HTTP e as chamadas ao nativo feitas
  dentro dela viram filhos (seção 5).
- Sem resultado informado, vale `completed`, nunca `success`.
- O motivo vem de uma lista fixa: nunca texto de erro nem ids.
- `setUser` recebe um id opaco, nunca e-mail ou documento.

### Telas nativas

A mesma API existe no Swift, e a jornada é uma só nos dois lados: tela
atual, fluxos abertos e usuário são compartilhados. Um fluxo pode começar
numa tela nativa e terminar numa tela Flutter, ou o contrário.

```swift
enum AppScreen: String, JourneyScreen { case document }
enum AppFlow: String, JourneyFlow { case login }    // mesmo código do Dart
enum AppAction: String, JourneyAction { case confirmDocument }

Journey.screen(AppScreen.document)                  // no viewDidAppear
let acao = Journey.begin(AppAction.confirmDocument)
TraceContext.with(acao.span) {
  api.validate { result in acao.end(result.ok ? .success : .failure) }
}
Journey.flowRun(AppFlow.login)?.end(.success)       // termina o fluxo, venha de onde vier
```

## 5. Traces das ações

Com a jornada no lugar, ligue o detalhe técnico nas fronteiras:

1. **Chamada ao nativo**: troque `invokeMethod` por `invokeTraced`. Os
   argumentos precisam ser um `Map`.

   ```dart
   await meuCanal.invokeTraced('metodo', arguments: {...});
   ```

   No nativo, registre o canal (mesmo nome do Dart) com `traced`: cada
   chamada continua o trace e termina quando o `result` é chamado.

   ```swift
   canal.setMethodCallHandler(OtelFlutterBridge.shared.traced(channel: "meu/canal") { call, result in
     // o handler de sempre
   })
   ```

2. **HTTP**: no Dart, com dio adicione `OtelDioInterceptor(propagateTo: {'host-da-sua-api'})`;
   com `package:http`, envolva o client do app em
   `OtelHttpClient(http.Client(), propagateTo: {'host-da-sua-api'})`.
   No nativo, use `HTTPClientSpan.start` / `finish` no ponto único de rede
   (Alamofire ou client próprio) ou `TracedURLSession` com `URLSession`
   direto (veja o guia de instrumentação do app, seção 4).

Para apps com Bloc ou Cubit, e para decidir onde encaixar cada peça, siga o
[guia de instrumentação do app](app-instrumentation-guide.pt-BR.md).

## 6. Mostrar na tela

Coloque o Inspetor num menu de debug:

```dart
import 'package:otel_flutter_bridge/inspector.dart';

Navigator.push(context,
  MaterialPageRoute(builder: (_) => const TelemetryInspectorPage()));
```

Ele mostra, em árvore, cada span que saiu do aparelho, já redigido: a
origem (dart ou native), a duração, os atributos e quantos atributos a
redação removeu. O botão de copiar leva o trace id para a ferramenta de
traces.

No dashboard de jornada, a sessão aparece com as telas, os fluxos e as
ações em ordem, e cada ação abre o seu trace.

## 7. Customizações

Os pontos de extensão estão em [extension-points.md](extension-points.md).
Os mais usados:

| Preciso de… | Use |
|---|---|
| Telas, fluxos, ações e usuário | `Journey` (Dart e Swift), `JourneyNavigatorObserver` |
| Atributo fixo da sessão em todo span (ex.: tenant) | `enrichers:` com chaves `app.*` |
| Mascarar um identificador próprio | `RedactionConfig(extraPatterns: [...])` |
| Permitir um atributo novo | `RedactionConfig(allowedAttributes: {...})` |
| Enviar pela rede do app (pinning, gateway) | `sendThroughNative: true` + `exportHandler` no Swift |
| Usar a sessão que o app nativo já tem | `SessionConfig(fromHost: true)` + `setSession` no Swift |
| Ver erros internos no log do app | `onDiagnostic:` |
| Desligar remotamente | `OtelFlutterBridge.setEnabled(false)` via configuração remota |

## 8. Checklist de validação

- [ ] A sessão aparece no dashboard com as telas, os fluxos e as ações na
      ordem certa, e o usuário só depois do login.
- [ ] Um fluxo que passa por telas nativas e Flutter aparece como uma
      execução só, com começo e fim.
- [ ] O trace de uma ação tem ação Flutter, chamada nativa e HTTP na
      hierarquia certa.
- [ ] Spans e eventos nativos criados antes do Flutter subir chegam na mesma
      sessão.
- [ ] Ao mandar o app para segundo plano no meio do fluxo, os últimos
      eventos chegam.
- [ ] Nenhum dado pessoal nos spans e eventos (confira no Inspetor os
      atributos e o contador de removidos).
- [ ] O app funciona igual com o receptor desligado (o Inspetor mostra
      "failed"; o app não percebe).
- [ ] O liga-desliga em tempo de execução funciona dos dois lados.
- [ ] Builds com ferramentas de proteção em tempo de execução rodam com a
      biblioteca.
- [ ] Tempo de inicialização e fluidez sem regressão perceptível (medir em
      aparelho físico, em Release).

## 9. Próximos passos

- Registre os números de desempenho no [ADR 0005](adr/0005-where-the-pipeline-lives.md).
- Aponte o `endpoint` para o receptor de produção (um collector ou o seu
  backend), com o token guardado no servidor. Ele deve seguir a seção
  "Receivers" de [specs/journey.md](specs/journey.md).
- Repita a redação no receptor, como segunda barreira.
