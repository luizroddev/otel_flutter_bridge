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
| `AppContext` (tela e fluxo carimbados no início de cada span) | Quando atualizar a tela e o fluxo (navegação) |
| iOS: `HTTPClientSpan`, `traced(channel:)`, `invokeTraced`, `bind`, `task`, `appContext` | O ponto único de rede (Alamofire), o registro dos canais, as telas nativas |
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
  ordem de composição (seção 3, caso D; no iOS, seção 4.2).
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

No host iOS (rode na pasta do projeto Xcode):

```bash
# Handlers que o Flutter chama, e chamadas do nativo para o Flutter
grep -rnE "FlutterMethodChannel|setMethodCallHandler|invokeMethod\(" --include=*.swift .
# Rede: o ponto único do Alamofire e usos diretos
grep -rnE "SessionManager|Alamofire\.request|\.request\(|URLSession\.shared|dataTask\(" --include=*.swift .
# Adapter e retrier já existentes (a ordem importa)
grep -rnE "RequestAdapter|RequestRetrier" --include=*.swift .
# Telas nativas: onde fica o viewDidAppear comum (base class, coordinator)
grep -rnE "class .*: UIViewController|viewDidAppear" --include=*.swift . | head -50
```

Anote: o **ponto único de rede** (a classe que chama `SessionManager`), as
telas nativas dos fluxos escolhidos e se o nativo chama o Flutter (push,
deep link, eventos de SDK).

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
  static const authLogin = 'auth.login';
  static const authPasswordReset = 'auth.password_reset';
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

```dart
// lib/telemetry/screen_observer.dart
// Atualiza a tela atual a cada navegação. Use nomes de rota fixos
// ('order.detail'), nunca o caminho com ids ('/orders/123').
class TelemetryScreenObserver extends NavigatorObserver {
  void _set(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name != null) AppContext.screen = name;
  }

  @override
  void didPush(Route route, Route? previousRoute) => _set(route);
  @override
  void didPop(Route route, Route? previousRoute) => _set(previousRoute);
  @override
  void didReplace({Route? newRoute, Route? oldRoute}) => _set(newRoute);
}

// Fluxo: marque o início e o fim da jornada onde ela começa e termina.
AppContext.flow = 'purchase';   // ao entrar no checkout
AppContext.flow = null;         // ao concluir ou abandonar
```

Com `go_router` ou `auto_route`, faça o mesmo no listener do router, com o
**nome** da rota (não a `location`).

## 2.1 Modelo: um trace por ação, ligado pela sessão e pelo contexto

- **Trace = uma ação causal** (um evento do Bloc, um método do Cubit): do
  handler até o HTTP, o nativo e o backend.
- **Jornada = a sessão**: todo span tem `session.id`. Filtrar por ela mostra
  a linha do tempo do usuário.
- **Onde o usuário estava = `app.screen` e `app.flow`**, carimbados no
  início de cada span (filhos herdam do pai, então um trace nunca mistura
  telas). Permite "todos os traces do fluxo `purchase`" ou "p95 de
  `orders.load` por tela".
- **Não faça um trace por tela ou por jornada.** O span raiz só é exportado
  ao terminar: se o app for morto ou suspenso, a raiz some e os filhos ficam
  órfãos. A amostragem é por trace (a jornada inteira entra ou sai), e a
  duração da raiz mede o tempo de leitura do usuário, não o app.
- **`enrichers` não servem para tela e fluxo**: rodam na exportação, em lote,
  segundos depois do início do span, e carimbariam a tela errada. Use-os
  para valores fixos da sessão (tenant, flavor).
- Métricas de funil e conversão são analytics de produto, não tracing.

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

### A.1 Um handler para vários eventos (ex.: login)

Comum em Blocs de autenticação: `on<SenhaEvent>` trata biometria, senha e
esqueci a senha num handler só. Com um nome fixo, as três operações viram o
mesmo span, e latência e erro de coisas diferentes se misturam.

Modele pela **operação**, não pelo evento: biometria e senha são a mesma
operação (login) com variantes; esqueci a senha é outra operação.

**Opção 1: separar os handlers** (preferível, é o estilo recomendado do
Bloc), desde que a concorrência não mude:

```dart
on<LoginBiometria>(tracedHandler(SpanNames.authLogin, _onBiometria,
    enrich: (s, _) => s.setStringAttribute('app.auth.method', 'biometric')));
on<LoginSenha>(tracedHandler(SpanNames.authLogin, _onSenha,
    enrich: (s, _) => s.setStringAttribute('app.auth.method', 'password')));
on<EsqueciSenha>(tracedHandler(SpanNames.authPasswordReset, _onEsqueci));
```

Atenção: cada `on<E>` tem seu próprio `transformer`. Se o handler único
usa `droppable()` ou `sequential()` justamente para impedir, por exemplo,
login por senha enquanto a biometria roda, separar muda esse comportamento.
Nesse caso, use a opção 2.

**Opção 2: manter o handler e nomear por evento** com `nameOf`:

```dart
on<SenhaEvent>(
  tracedHandler(
    SpanNames.authLogin,          // usado se nameOf devolver null
    _onSenhaEvent,
    nameOf: (e) => switch (e) {
      LoginBiometria() || LoginSenha() => SpanNames.authLogin,
      EsqueciSenha() => SpanNames.authPasswordReset,
    },
    enrich: (span, e) {
      if (e is LoginBiometria) span.setStringAttribute('app.auth.method', 'biometric');
      if (e is LoginSenha) span.setStringAttribute('app.auth.method', 'password');
    },
  ),
  transformer: droppable(),
);
```

`nameOf` deve devolver só strings fixas (switch por tipo; com `SenhaEvent`
`sealed`, o compilador avisa quando surgir um evento novo sem nome). Nunca
interpole dados do evento.

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

### J. Um evento que causa outro (Bloc que escuta Bloc, nativo → Flutter)

Por padrão, um evento disparado por `stream.listen` de outro Bloc, ou por
uma chamada do nativo, inicia um trace novo. Na maioria dos casos isso é
correto: são ações diferentes, ligadas pela sessão e pelo `app.flow`.

Quando a causalidade importa para investigar (ex.: o push do nativo que
dispara a sincronização), ligue os traces com um **span link**: "relacionado
a, mas não filho de". Capture o contexto no `add` e adicione o link no
handler:

```dart
final _addedFrom = Expando<Context>();

class SyncBloc extends Bloc<SyncEvent, SyncState> {
  SyncBloc() : super(const SyncState.idle()) {
    on<SyncRequested>(tracedHandler(SpanNames.sync, (event, emit) async {
      final from = _addedFrom[event]?.span;
      if (from != null) Context.current.span?.addLink(from.spanContext);
      // ...
    }));
  }

  @override
  void add(SyncEvent event) {
    _addedFrom[event] = Context.current; // o contexto de quem chamou add
    super.add(event);
  }
}
```

Use pai (em vez de link) só se o segundo evento é parte da mesma unidade de
trabalho e o primeiro espera por ele. Aplique onde a revisão encontrar
cadeias reais; não em todo Bloc. Limitação: eventos `const` são a mesma
instância, então dois `add` concorrentes do mesmo evento `const` podem
trocar de link.

### K. Inicialização e tarefas em segundo plano

Carregamentos no `main()` ou na splash: envolva com
`startActiveSpanAsync(name: 'app.startup', ...)` se quiser um trace único.
Tarefas periódicas: rastreie a operação explícita, não cada tick.

### L. Requisições para terceiros

Continuam rastreadas (útil para ver latência), mas sem `traceparent` quando
`propagateTo` lista só os hosts próprios. Para não rastrear, use `filter`.

## 4. Lado iOS (host nativo)

O trace de ponta a ponta atravessa o canal nos dois sentidos. As regras do
Dart valem no Swift: só é rastreado o que passa pelas peças da biblioteca
(sem swizzling), a redação acontece no Dart, e tela e fluxo são carimbados
no início de cada span.

A estratégia é instrumentar **as fronteiras** (canal e rede), uma vez, e
deixar o span corrente seguir sozinho pelo código do meio: estado, managers,
notificações. O código de negócio quase não muda.

```
Flutter ─invokeTraced─► Swift traced(channel:) ─HTTPClientSpan─► backend
                                   │ (resposta roda no trace de quem pediu)
                                   └─invokeTraced─► Flutter setTracedMethodCallHandler
```

### 4.1 Início

No `didFinishLaunching`, antes do engine (que no seu app sobe no launch):

```swift
OtelFlutterBridge.shared.start(resourceAttributes: [
  "os.name": .string("iOS"),
  "os.version": .string(UIDevice.current.systemVersion),
])
HTTPClientSpan.propagateTo = ["api.meuapp.com"]  // traceparent só para a sua API
```

Spans nativos criados antes do Dart ficar pronto esperam numa fila (512, os
mais antigos saem primeiro) e entram na mesma sessão. A amostragem
(`sampleRatio`) é aplicada a eles no Dart, com a mesma regra dos traces
Dart.

### 4.2 As fronteiras (uma vez no app)

**Rede: o ponto único do Alamofire.** Instrumente a classe que chama o
`SessionManager`, não o Alamofire. A biblioteca não depende do Alamofire
(a 4.8 está sem manutenção desde 2020), e o código vale igual na 5.

```swift
final class APIClient {
  private let session: SessionManager

  func request(_ route: URLRequestConvertible,
               completion: @escaping (DataResponse<Data>) -> Void) {
    guard let urlRequest = try? route.asURLRequest() else {
      session.request(route).validate().responseData(completionHandler: completion)
      return
    }
    let call = HTTPClientSpan.start(urlRequest)          // pai = span corrente
    session.request(call.request).validate().responseData { response in
      call.finish(response: response.response, error: response.error) {
        completion(response)                              // roda no trace de quem pediu
      }
    }
  }
}
```

- `finish { ... }` roda o callback com o span **de quem pediu** como corrente
  (ou o próprio span HTTP, quando ninguém pediu, ex.: um Timer). Por isso
  tudo o que a resposta dispara (estado, callbacks guardados, notificações
  síncronas, chamadas ao Flutter) continua no mesmo trace, sem mudar o
  código que trata a resposta.
- `validate()` com 4xx/5xx: `error.type` é o status (`404`), não `AFError`.
- Retry (`RequestRetrier`) do Alamofire 4 reenvia a mesma requisição: as
  tentativas ficam no mesmo span.
- `finish` deve ser chamado em todos os caminhos (sucesso, erro,
  cancelamento); chamadas repetidas são ignoradas.
- `URLSession` direto: `TracedURLSession.dataTask(with:)` já faz o mesmo.

**Canal, Flutter → nativo: uma palavra por canal.**

```swift
channel.setMethodCallHandler(OtelFlutterBridge.shared.traced(channel: "app/native") { call, result in
  // o código do handler, sem mudanças
})
```

O span `app/native/<método>` continua o trace do Dart (com a tela e o fluxo
do Dart), fica corrente enquanto o handler roda e **termina quando `result`
é chamado**: a duração inclui a espera real. `FlutterError` vira
`error.type = <code>`. O nome do canal precisa ser o mesmo usado no Dart.

**Canal, nativo → Flutter: `invokeTraced` no lugar de `invokeMethod`.**

```swift
channel.invokeTraced("saldoAtualizado", arguments: ["origem": "timer"])
```

```dart
// No Dart, no lugar de setMethodCallHandler:
channel.setTracedMethodCallHandler((call) async {
  // spans criados aqui são filhos do span nativo, com a tela dele
});
```

### 4.3 Código fácil: o handler chama a API e responde

```swift
channel.setMethodCallHandler(OtelFlutterBridge.shared.traced(channel: "app/native") { call, result in
  switch call.method {
  case "getPerfil":
    api.request(Router.perfil) { response in
      result(response.value.map(Perfil.json))
    }
  default:
    result(FlutterMethodNotImplemented)
  }
})
```

Alteração além das fronteiras: **nenhuma**.

```
perfil.open (Dart)                                  app.screen=perfil
└─ app/native/getPerfil (client, Dart)                210 ms
   └─ app/native/getPerfil (server, Swift)            205 ms
      └─ GET /v1/perfil                               190 ms   status 200
         └─ backend ...
```

### 4.4 Código bom: service com async/await

```swift
channel.setMethodCallHandler(OtelFlutterBridge.shared.traced(channel: "app/extrato") { call, result in
  OtelFlutterBridge.shared.task {                  // ← no lugar de `Task {`
    do {
      result(try await service.load(month: 5).json)
    } catch {
      result(FlutterError(code: "extrato_falhou", message: nil, details: nil))
    }
  }
})

final class ExtratoService {                       // sem mudanças
  func load(month: Int) async throws -> Extrato {
    async let saldo = api.send(Router.saldo)
    async let lancamentos = api.send(Router.lancamentos(month))
    return try await Extrato(saldo: saldo, lancamentos: lancamentos)
  }
}
```

Alteração: **`Task {` → `OtelFlutterBridge.shared.task {`**, por ponto de
entrada async. O contexto padrão do OpenTelemetry Swift no iOS segue a
thread e se perde depois de um `await`; a biblioteca guarda o span num
`@TaskLocal`, herdado por tarefas filhas e `async let`. Se o `api.send`
async usa `HTTPClientSpan` por dentro, as duas chamadas saem como irmãs:

```
extrato.open (Dart)
└─ app/extrato/load (client, Dart)                   340 ms
   └─ app/extrato/load (server, Swift)               335 ms
      ├─ GET /v1/saldo                               120 ms   ┐ em paralelo
      └─ GET /v1/lancamentos                         310 ms   ┘
```

### 4.5 Código ruim: singleton, estado solto, cache, Timer, notificação

```swift
final class SaldoManager {
  static let shared = SaldoManager()
  var saldo: Saldo?
  var isLoading = false
  private var callbacks: [(Saldo?) -> Void] = []

  init() {
    Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in self.load() }
  }

  func get(_ completion: @escaping (Saldo?) -> Void) {
    if let saldo { return completion(saldo) }
    callbacks.append(OtelFlutterBridge.shared.bind(completion))   // ← única mudança
    load()
  }

  func load() {
    guard !isLoading else { return }
    isLoading = true
    api.request(Router.saldo) { response in
      self.saldo = response.value
      self.isLoading = false
      self.callbacks.forEach { $0(self.saldo) }; self.callbacks = []
      NotificationCenter.default.post(name: .saldoAtualizado, object: nil)
    }
  }
}

NotificationCenter.default.addObserver(forName: .saldoAtualizado, object: nil, queue: nil) { _ in
  channel.invokeTraced("saldoAtualizado")                       // ← era invokeMethod
}
```

Alteração: **um `bind` por lista de callbacks guardados**, e `invokeTraced`
onde o nativo avisa o Flutter.

Pedido do Flutter sem cache:

```
home.load (Dart)                                    app.screen=home
└─ app/native/getSaldo (client, Dart)                 120 ms
   └─ app/native/getSaldo (server, Swift)             118 ms   ← a espera aparece
      ├─ GET /v1/saldo                                110 ms
      └─ app/native/saldoAtualizado (server, Dart)              ← notificação na resposta
```

Segundo pedido enquanto o primeiro carrega: o span dele dura a espera (sem
o HTTP, que pertence ao primeiro). **O `bind` é o que impede que o que o
callback dele faz depois vá para o trace do primeiro.**

Atualização pelo Timer:

```
GET /v1/saldo (Swift, raiz)                         app.screen=extrato
├─ backend ...
└─ app/native/saldoAtualizado (server, Dart)
   └─ GET /v1/extrato (Dart) ...
```

Com cache: o span do servidor dura ~1 ms e não tem filhos. Correto: não
houve trabalho.

### 4.6 Onde o contexto não chega sozinho

| Padrão | O que acontece | O que fazer |
|---|---|---|
| Callback guardado e chamado fora da resposta que o originou (fila, coalescimento) | Vai para o trace errado ou nenhum | `bind(callback)` ao guardar |
| `Task { }` | Perde o span depois do primeiro `await` | `OtelFlutterBridge.shared.task { }` |
| `DispatchQueue.async` / `asyncAfter` dentro do handler | Em geral acompanha; não conte com isso | `bind` no bloco |
| SDKs de terceiros, push, CoreLocation, delegates de sistema | Trace novo | Correto na maioria das vezes; `bind` quando houver causa |
| Timer | Trace novo | Correto: ninguém pediu |

Para criar um span manual no meio do código (ex.: `Saldo.load`), use
`OtelFlutterBridge.shared.tracer().spanBuilder(spanName:)` com
`.setParent(TraceContext.current)` quando houver um corrente, e
`TraceContext.with(span) { ... }` para torná-lo corrente.

### 4.7 Telas nativas

No `viewDidAppear` da base class (ou no coordinator), com nomes fixos:

```swift
class BaseViewController: UIViewController {
  /// Nome fixo da tela para a telemetria, ex.: "Statement.list".
  var telemetryScreen: String? { nil }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if let name = telemetryScreen { OtelFlutterBridge.shared.appContext.screen = name }
  }
}
```

Fluxo: `OtelFlutterBridge.shared.appContext.flow = "statement"` ao começar
a jornada, `nil` ao terminar. Telas Flutter são definidas no Dart
(`AppContext`); spans nativos filhos de um handler Dart recebem a tela e o
fluxo do Dart pelo canal, então um trace nunca mistura telas.

### 4.8 Erros no nativo

`exception.message` e a mensagem de status são exportados (com a redação
padrão). Escreva mensagens sem dados pessoais e cadastre os identificadores
próprios em `RedactionConfig.extraPatterns`. Prefira códigos fixos em
`FlutterError.code` (vira `error.type`).

## 5. O que não fazer

- Nome de span com `runtimeType`, `toString()` ou interpolação de ids.
- `enrich` lendo campos livres do evento, do estado ou da resposta.
- Um `BlocObserver` que cria span em `onTransition`/`onChange`: volume alto,
  duração sem sentido e risco de `toString()` de estado.
- `transformer` global no Bloc ou `HttpOverrides.global` para "rastrear
  tudo".
- Passar o `OtelHttpClient` como transporte da própria telemetria.
- Liberar chaves novas na redação sem revisão (`allowedAttributes`).

## 6. Ordem de entrega

1. Revisão (seção 1) preenchida e revisada por alguém do time.
2. Client único no composition root, com `OtelHttpClient` ou o interceptor
   do dio. Só isso já gera spans HTTP com `session.id`.
3. `tracedHandler` nos handlers do primeiro fluxo.
4. `invokeTraced` + lado nativo, se o fluxo passa pelo nativo.
5. Validação (seção 8). Depois, expandir fluxo a fluxo.

## 7. Checklist de code review da instrumentação

- [ ] Nomes de span vêm de `SpanNames` e seguem `{area}.{acao}`.
- [ ] Nenhum `enrich` lê texto livre, id, e-mail, valor ou documento.
- [ ] Todas as chaves novas são `app.*`; nenhuma `allowedAttributes` nova
      sem justificativa.
- [ ] Nenhuma chamada nova a `http.get(...)` direta ou `http.Client()` fora
      do composition root.
- [ ] `propagateTo` contém só hosts da empresa.
- [ ] Handlers de alta frequência não usam `tracedHandler`.
- [ ] Um handler com várias operações usa `nameOf` (ou foi separado sem
      mudar o `transformer`).
- [ ] Tela e fluxo vêm de `AppContext`, com nomes de rota fixos; nenhum
      `enricher` lê a tela atual.
- [ ] iOS: todo `HTTPClientSpan.start` tem `finish` em todos os caminhos
      (sucesso, erro, cancelamento); nenhuma requisição dos fluxos sai do
      `SessionManager` sem passar pelo ponto único.
- [ ] iOS: canais registrados com `traced(channel:)` (mesmo nome do Dart);
      chamadas ao Flutter com `invokeTraced`, e o Dart com
      `setTracedMethodCallHandler`.
- [ ] iOS: `Task {` nos pontos de entrada dos fluxos virou
      `OtelFlutterBridge.shared.task {`; callbacks guardados usam `bind`.
- [ ] O comportamento do handler não mudou (mesmos estados, mesmos erros).

## 8. Validação

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
