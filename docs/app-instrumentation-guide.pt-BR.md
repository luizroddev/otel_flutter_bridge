# Guia de instrumentação do app (pt-BR)

Como encaixar a biblioteca num app Flutter que já existe, com `http` ou
`dio`, Bloc ou Cubit e canais nativos: primeiro revisar o projeto, depois
instrumentar caso a caso, com o mínimo de código manual.

Pré-requisito: a biblioteca já inicializada (passos 1 a 3 do
[guia de integração](integration-guide.pt-BR.md)).

## 0. Divisão de responsabilidades

| A biblioteca entrega (genérico, testado, revisado uma vez) | O app decide (domínio) |
|---|---|
| `OtelHttpClient` para `package:http` | Onde o client é criado e injetado |
| `OtelDioInterceptor` para dio | Quais hosts recebem `traceparent` (`propagateTo`) |
| `tracedHandler` para handlers de Bloc | Quais handlers rastrear e o nome de cada span |
| `invokeTraced` para canais | Atributos `app.*` (`enrich`, `enrichers`) |
| Redação, sessão, exportação | Padrões extras de redação para ids próprios |

Nada é automático: só é rastreado o que passa por essas peças. Isso é
intencional ([ADR 0002](adr/0002-no-swizzling-no-hooks.md)).

## 1. Revisão do projeto (antes de escrever código)

Objetivo: descobrir **por onde passam as requisições, onde nascem as ações
do usuário e o que pode vazar**, para decidir o ponto de encaixe de cada
peça. Leva de 1 a 2 horas num app médio. Rode na raiz do módulo Flutter.

### 1.1 HTTP: quantos clients existem e onde nascem

```bash
# Chamadas de nível superior: cada uma cria um client próprio e NÃO será rastreada
grep -rnE "\bhttp\.(get|post|put|patch|delete|head|read|readBytes)\(" lib

# Onde clients são criados
grep -rnE "http\.Client\(\)|IOClient\(|RetryClient\(|extends (http\.)?BaseClient|Dio\(" lib

# Interceptors e wrappers existentes (auth, logging, retry)
grep -rnE "extends Interceptor|interceptors\.add|BaseClient" lib
```

Anote:
- **Composition root**: o lugar único onde o client deveria nascer (DI com
  `get_it`, `provider`, `injectable`, `riverpod`, ou `main.dart`).
- **Chamadas diretas** `http.get(...)`: precisam virar chamadas no client
  injetado. É o principal trabalho de refatoração.
- **Wrappers próprios** (auth, headers, refresh de token, retry): definem a
  ordem de composição (seção 3, casos C e D).
- **Hosts**: quais são da empresa (recebem `traceparent`) e quais são de
  terceiros (analytics, CDN, mapas, pagamentos externos).

### 1.2 Estado: Bloc, Cubit ou os dois

```bash
grep -rnE "extends Bloc<" lib | wc -l
grep -rnE "extends Cubit<" lib | wc -l
grep -rnE "\bon<[A-Za-z_]+>\(" lib
grep -rnE "transformer:|restartable\(|droppable\(|sequential\(|debounce" lib
grep -rnE "BlocObserver|Bloc\.observer" lib
```

Anote:
- Handlers que são **ações do usuário ou carregamentos** (candidatos) e
  handlers de **alta frequência** (digitação, scroll, ticks, streams): estes
  não devem ser rastreados.
- Uso de `bloc_concurrency` (`restartable`, `droppable`): ver caso H.
- Se já existe `BlocObserver`: não é preciso mexer nele.

### 1.3 Canais nativos e HTTP nativo

```bash
grep -rnE "MethodChannel\(|invokeMethod" lib
```
No host iOS: procure os `FlutterMethodChannel` e os `URLSession` usados por
esses handlers.

### 1.4 Riscos de privacidade

```bash
# Eventos e estados com toString que imprime dados (Equatable, freezed, data classes)
grep -rnE "props =>|@freezed|String toString\(\)" lib
# Montagem de URLs: revise os paths que levam ids ou textos
grep -rnE "Uri\.(parse|https|http)\(" lib
```

Anote:
- Formatos de identificadores próprios (ex.: `PED-123456`, `AB12CD`) que não
  são pegos pelos padrões padrão: viram `RedactionConfig(extraPatterns: …)`.
- Paths com ids em segmentos sem dígito (slugs, e-mails): o normalizador só
  troca segmentos com dígito ou com 24+ caracteres. Esses casos pedem
  `filter` ou um padrão extra.
- Se o build de release usa `--obfuscate` (procure no CI/Fastlane): nomes de
  tipos saem ofuscados. Nomes de span são sempre strings fixas.

### 1.5 Fluxos críticos

Escolha **de 1 a 3 fluxos** de ponta a ponta para a primeira entrega (ex.:
login, listagem principal, checkout). Para cada um, desenhe a cadeia:

```
Tela → evento (Bloc) → repositório → HTTP/canal → backend
```

### 1.6 Resultado da revisão

Preencha antes de começar:

```markdown
## Revisão de telemetria: <app>
- Composition root do HTTP: <arquivo/linha>
- Clients encontrados: <n>; chamadas diretas http.get/post: <n> (<arquivos>)
- Wrappers existentes: <auth, retry, logging> → ordem proposta: <...>
- Hosts próprios (propagateTo): <...>; terceiros: <...>
- Bloc: <n> blocs / <n> handlers; candidatos: <lista>; não rastrear: <lista>
- Cubit: <n>; métodos candidatos: <lista>
- Canais usados nos fluxos: <canal/método>
- Padrões extras de redação: <regex>
- Build ofuscado: sim/não
- Fluxos da primeira entrega: <1..3>
```

## 2. Estrutura mínima no app

Três arquivos pequenos, todos do app:

```dart
// lib/telemetry/span_names.dart
// Nomes {area}.{acao}, fixos, sem ids. Um arquivo só facilita a revisão.
abstract final class SpanNames {
  static const ordersLoad = 'orders.load';
  static const ordersRefresh = 'orders.refresh';
  static const checkoutConfirm = 'checkout.confirm';
}
```

```dart
// lib/telemetry/http.dart
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

/// O único http.Client do app. Injete este em todos os repositórios.
http.Client buildHttpClient() => AuthClient(         // wrapper do app, se existir
      RetryClient(                                   // retry por fora
        OtelHttpClient(                              // um span por tentativa
          http.Client(),
          propagateTo: const {'api.meuapp.com'},
          filter: (r) => r.url.host != 'analytics.meuapp.com',
        ),
      ),
    );
```

```dart
// lib/main.dart (trecho)
await OtelFlutterBridge.initialize(
  OtelBridgeConfig(
    serviceName: 'meu-app',
    serviceVersion: '2.3.0',
    endpoint: Uri.parse('https://otel.meuapp.com'),
    redaction: const RedactionConfig(extraPatterns: [r'PED-\d+']),
  ),
);
getIt.registerSingleton<http.Client>(buildHttpClient());
```

## 3. Casos

### A. Bloc com `on<E>`: `tracedHandler`

```dart
on<LoadOrders>(tracedHandler(
  SpanNames.ordersLoad,
  _onLoadOrders,
  enrich: (span, event) =>
      span.setStringAttribute('app.orders.filter', event.filter.name),
));
```

- O span fica ativo enquanto o handler roda: HTTP, `invokeTraced` e spans
  manuais dentro dele viram filhos, inclusive através de repositórios.
- O span do handler costuma ser a **raiz** do trace. O Bloc executa o
  handler na zona em que foi criado, não na de quem chamou `add()`, então um
  span aberto no `onPressed` não vira pai. Na prática, o evento já é a ação
  do usuário.
- O evento nunca é lido. Em `enrich`, use só enums, booleanos e contagens
  pequenas com chaves `app.*`. Nunca ids, textos, e-mails, valores.
- Se o handler lança, o span fica com erro e `error.type`, e o mesmo erro
  segue para o `onError` do Bloc, com a mesma stack. Nada muda no
  comportamento. O texto da exceção nunca é exportado nem impresso.
- Em build com `--obfuscate`, nomes de tipo saem ofuscados. Para as exceções
  do app, informe nomes fixos:

  ```dart
  on<LoadOrders>(tracedHandler(
    SpanNames.ordersLoad,
    _onLoadOrders,
    errorType: (e) => switch (e) {
      OrdersException() => 'orders_exception',
      _ => 'other',
    },
  ));
  ```

### B. Erro tratado dentro do handler

Quando o handler captura a exceção e emite um estado de falha, o span sai
OK (os spans HTTP filhos mostram o status). Para marcar o span do handler:

```dart
} on OrdersException catch (e) {
  Context.current.span
    ?..setStringAttribute('error.type', e.code)   // código fixo, não mensagem
    ..setStatus(SpanStatusCode.Error);
  emit(state.failed());
}
```

### C. Cubit: span no método

Métodos de Cubit são chamados direto da UI, então o contexto é preservado.
Use a API padrão do SDK, sem helper. A biblioteca configura o SDK para que
exceções registradas assim guardem só o tipo, sem mensagem:

```dart
Future<void> load() => OTel.tracer().startActiveSpanAsync(
      name: SpanNames.ordersLoad,
      fn: (span) async {
        emit(state.loading());
        emit(state.loaded(await _repo.fetch()));
      },
    );
```

### D. `package:http` com wrappers próprios

- `OtelHttpClient` deve ficar **mais perto da rede** (mais interno): cada
  tentativa real vira um span, e o `traceparent` vai na requisição que sai.
- Wrappers de auth e headers ficam por fora: os headers deles não são
  gravados de qualquer forma.
- `RetryClient` por fora de `OtelHttpClient`: um span por tentativa, como
  pedem as convenções semânticas de HTTP.
- O span termina quando chegam os headers da resposta. Erros ao ler o corpo
  não aparecem no span HTTP; se importarem, aparecem no span do handler.

### E. Chamadas diretas `http.get(...)`

Não são rastreadas. Troque por chamadas no client injetado:

```dart
// antes
final res = await http.get(Uri.parse('$base/orders'));
// depois
final res = await _client.get(Uri.parse('$base/orders'));
```

### F. dio

`OtelDioInterceptor(propagateTo: {...})` no `Dio` do app. Adicione-o
**depois** dos interceptors de auth, para que a requisição já esteja
completa quando o span começa. As mesmas regras de `filter` e `enrich`.

### G. Canal nativo dentro do handler

Troque `invokeMethod` por `invokeTraced` só nas chamadas dos fluxos
escolhidos. No Swift, `startSpan(_:arguments:)` continua o trace. O
argumento precisa ser um `Map`.

### H. `bloc_concurrency` (`restartable`, `droppable`, `sequential`)

- `droppable`: eventos descartados não executam o handler, logo não geram
  span. Correto.
- `restartable`: o handler anterior é cancelado para o Bloc (o `emit` passa
  a ser ignorado), mas a `Future` dele continua até terminar, e o span
  termina junto. Espere spans sobrepostos em buscas rápidas; se incomodar,
  não rastreie esse handler e deixe só os spans HTTP.
- `sequential`: a duração do span inclui só a execução, não a espera na fila.

### I. Eventos de alta frequência

Digitação, scroll, sliders, ticks de timer, eventos vindos de streams
(websocket, localização): **não use `tracedHandler`**. As requisições que
eles dispararem continuam rastreadas pelo client, como raízes próprias.

### J. Bloc que escuta outro Bloc ou stream

Um evento disparado por `stream.listen` de outro Bloc inicia um trace novo.
É aceitável: são ações diferentes. Não tente encadear.

### K. Inicialização e tarefas em segundo plano

Carregamentos no `main()` ou na splash: envolva com
`startActiveSpanAsync(name: 'app.startup', ...)` se quiser um trace único.
Tarefas periódicas: rastreie a operação explícita, não cada tick.

### L. Requisições para terceiros

Continuam rastreadas (útil para ver latência), mas sem `traceparent` quando
`propagateTo` lista só os hosts próprios. Para não rastrear, use `filter`.

## 4. O que não fazer

- Nome de span com `runtimeType`, `toString()` ou interpolação de ids.
- `enrich` lendo campos livres do evento, do estado ou da resposta.
- Um `BlocObserver` que cria span em `onTransition`/`onChange`: volume alto,
  duração sem sentido e risco de `toString()` de estado.
- `transformer` global no Bloc ou `HttpOverrides.global` para "rastrear
  tudo".
- Passar o `OtelHttpClient` como transporte da própria telemetria.
- Liberar chaves novas na redação sem revisão (`allowedAttributes`).

## 5. Ordem de entrega

1. Revisão (seção 1) preenchida e revisada por alguém do time.
2. Client único no composition root, com `OtelHttpClient` ou o interceptor
   do dio. Só isso já gera spans HTTP com `session.id`.
3. `tracedHandler` nos handlers do primeiro fluxo.
4. `invokeTraced` + lado nativo, se o fluxo passa pelo nativo.
5. Validação (seção 7). Depois, expandir fluxo a fluxo.

## 6. Checklist de code review da instrumentação

- [ ] Nomes de span vêm de `SpanNames` e seguem `{area}.{acao}`.
- [ ] Nenhum `enrich` lê texto livre, id, e-mail, valor ou documento.
- [ ] Todas as chaves novas são `app.*`; nenhuma `allowedAttributes` nova
      sem justificativa.
- [ ] Nenhuma chamada nova a `http.get(...)` direta ou `http.Client()` fora
      do composition root.
- [ ] `propagateTo` contém só hosts da empresa.
- [ ] Handlers de alta frequência não usam `tracedHandler`.
- [ ] O comportamento do handler não mudou (mesmos estados, mesmos erros).

## 7. Validação

- **Inspetor** (`TelemetryInspectorPage`): o fluxo aparece como árvore
  `handler → HTTP`, com o contador de atributos removidos.
- **Jaeger**: o mesmo trace com os spans do backend.
- **Teste automatizado no app**, com transporte em memória:

```dart
final transport = InMemoryTransport();
await OtelFlutterBridge.initialize(
  OtelBridgeConfig(serviceName: 'test', endpoint: Uri.parse('http://x')),
  transport: transport,
  connectNative: false,
);
final client = OtelHttpClient(MockClient((_) async => http.Response('[]', 200)));
final bloc = OrdersBloc(OrdersRepository(client));
bloc.add(LoadOrders(OrderFilter.open));
await bloc.stream.firstWhere((s) => s.isLoaded);
await OtelFlutterBridge.flush();

final handler = transport.spans.singleWhere((s) => s.name == 'orders.load');
final request = transport.spans.singleWhere((s) => s.name == 'GET');
expect(request.parentSpanId, handler.spanId);
```

- **Privacidade**: no mesmo teste, confira que nenhum valor do evento
  aparece em `transport.requests`.
