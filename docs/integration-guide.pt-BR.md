# Guia de integração em um app existente (pt-BR)

Passo a passo para adicionar a biblioteca a um app add-to-app que já existe
(host iOS nativo com módulo Flutter) e ver o resultado rápido: o Inspetor na
tela e o Jaeger no computador. Tudo que é específico do seu app fica no seu
app; a biblioteca não precisa de nenhuma alteração.

## 1. Ver a biblioteca funcionando sozinha (15 min)

```bash
make up          # Jaeger em http://localhost:16686
make backend     # backend de demonstração em :8080
make example-ios # app de exemplo no simulador
```

No app de exemplo, rode os cenários e abra a aba **Inspetor**. O cenário 5
mostra o trace completo: ação Flutter → canal → nativo → HTTP nativo →
backend. O cenário 6 mostra a redação: o CPF some, e cartão e token viram
`[REDACTED]`.

## 2. Dependência

Enquanto os pacotes não estão no pub.dev, use o git com uma referência fixa
(tag ou commit), nunca uma branch:

```yaml
dependencies:
  otel_flutter_bridge:
    git:
      url: https://github.com/luizroddev/otel_flutter_bridge
      path: packages/otel_flutter_bridge
      ref: v0.1.0-dev.1
  otel_flutter_bridge_dio:            # só se o app usa dio
    git:
      url: https://github.com/luizroddev/otel_flutter_bridge
      path: packages/otel_flutter_bridge_dio
      ref: v0.1.0-dev.1

# Necessário enquanto o núcleo não está no pub.dev: o pacote dio o pede de lá.
dependency_overrides:
  otel_flutter_bridge:
    git:
      url: https://github.com/luizroddev/otel_flutter_bridge
      path: packages/otel_flutter_bridge
      ref: v0.1.0-dev.1
```

No iOS a biblioteca usa CocoaPods (`OpenTelemetry-Swift-Api` e `-Sdk` 2.5.1).

## 3. Inicialização

### Nativo (host iOS)

No `application(_:didFinishLaunchingWithOptions:)`, antes de subir a engine
Flutter:

```swift
import otel_flutter_bridge

OtelFlutterBridge.shared.start(resourceAttributes: [
  "os.name": .string("iOS"),
  "os.version": .string(UIDevice.current.systemVersion),
])
```

Se o app já registra um `TracerProvider` próprio, use
`registerGlobal: false` e adicione `OtelFlutterBridge.shared.makeSpanProcessor()`
ao provider existente.

### Dart (módulo Flutter)

No `main()` do módulo:

```dart
await OtelFlutterBridge.initialize(
  OtelBridgeConfig(
    serviceName: 'meu-app',
    serviceVersion: '1.0.0',
    deploymentEnvironment: 'dev',
    endpoint: Uri.parse('http://IP-DO-SEU-MAC:4318'),
    redaction: const RedactionConfig(
      extraPatterns: [/* identificadores próprios, ex.: r'ORD-\d{4}' */],
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

## 4. Instrumentar um fluxo

Escolha **um** fluxo de ponta a ponta. Três pontos de contato bastam:

1. **Ação no Flutter**: um span em volta da ação do usuário.

   ```dart
   final tracer = OTel.tracer();
   final span = tracer.startSpan('fluxo.acao');
   await tracer.withSpanAsync(span, () async { /* ... */ });
   span.end();
   ```

2. **Chamada ao nativo**: troque `invokeMethod` por `invokeTraced` só nessa
   chamada. Os argumentos precisam ser um `Map`.

   ```dart
   await meuCanal.invokeTraced('metodo', arguments: {...});
   ```

   No handler nativo correspondente:

   ```swift
   let span = OtelFlutterBridge.shared.startSpan("Feature.metodo", arguments: call.arguments)
   defer { span.end() }
   ```

3. **HTTP**: no Dart, com dio adicione `OtelDioInterceptor(propagateTo: {'host-da-sua-api'})`;
   com `package:http`, envolva o client do app em
   `OtelHttpClient(http.Client(), propagateTo: {'host-da-sua-api'})`.
   No nativo, troque a chamada do `URLSession` desse fluxo por
   `TracedURLSession.dataTask(with:parent: span.context)`.

Para apps com Bloc ou Cubit, e para decidir onde encaixar cada peça, siga o
[guia de instrumentação do app](app-instrumentation-guide.pt-BR.md).

## 5. Mostrar na tela

Coloque o Inspetor num menu de debug:

```dart
import 'package:otel_flutter_bridge/inspector.dart';

Navigator.push(context,
  MaterialPageRoute(builder: (_) => const TelemetryInspectorPage()));
```

Ele mostra, em árvore, cada span que saiu do aparelho, já redigido: a
origem (dart ou native), a duração, os atributos e quantos atributos a
redação removeu. O botão de copiar leva o trace id para buscar no Jaeger.

## 6. Customizações

Os pontos de extensão estão em [extension-points.md](extension-points.md).
Os mais usados:

| Preciso de… | Use |
|---|---|
| Atributo em todo span (ex.: fluxo, tela) | `enrichers:` com chaves `app.*` |
| Mascarar um identificador próprio | `RedactionConfig(extraPatterns: [...])` |
| Permitir um atributo novo | `RedactionConfig(allowedAttributes: {...})` |
| Enviar pelo cliente HTTP do app (pinning, proxy) | `transport:` com um `TraceTransport` próprio |
| Ver erros internos no log do app | `onDiagnostic:` |
| Desligar remotamente | `OtelFlutterBridge.setEnabled(false)` via configuração remota |
| Usar uma sessão que o app já tem | `sessionIdProvider:` (sem identificar o usuário) |

## 7. Checklist de validação

- [ ] O trace do fluxo aparece no Jaeger com ação Flutter, chamada nativa e
      HTTP na hierarquia certa.
- [ ] Spans nativos criados antes do Flutter subir chegam na mesma sessão.
- [ ] Nenhum dado pessoal nos spans (confira no Inspetor os atributos e o
      contador de removidos).
- [ ] O app funciona igual com o Jaeger desligado (o Inspetor mostra
      "failed"; o app não percebe).
- [ ] O liga-desliga em tempo de execução funciona dos dois lados.
- [ ] Builds com ferramentas de proteção em tempo de execução rodam com a
      biblioteca.
- [ ] Tempo de inicialização e fluidez sem regressão perceptível (medir em
      aparelho físico, em Release).

## 8. Próximos passos

- Registre os números de desempenho no [ADR 0005](adr/0005-where-the-pipeline-lives.md).
- Troque o Jaeger local por um collector que repasse ao seu backend de
  observabilidade, com o token guardado no servidor.
- Repita a redação no collector, como segunda barreira.
