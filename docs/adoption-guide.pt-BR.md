# Guia de adoção: biblioteca e dashboard de jornada em outro sistema (pt-BR)

Este guia explica como levar o
[otel_flutter_bridge](https://github.com/luizroddev/otel_flutter_bridge)
(biblioteca) e o
[otel-journey-dashboard](https://github.com/luizroddev/otel-journey-dashboard)
(dashboard) para um sistema que já existe: um app com telas Flutter e,
talvez, telas nativas, um backend próprio, um banco, um portal interno e uma
ferramenta de logs. Nada aqui é específico de uma empresa: cada decisão vem
com as opções, quando usar cada uma e o que ela custa.

Ele foi escrito para ser lido por pessoas **e** por um agente de IA. O
[prompt de adoção](adoption-prompt.pt-BR.md) diz ao agente como usar este
guia, fase a fase. Este guia é autossuficiente: a seção 15 resume os
contratos para quem não tiver acesso aos links.

Sumário:

1. O que você ganha, e o que não
2. Arquitetura em uma página
3. Vocabulário
4. Levantamento do sistema-alvo
5. Decisões de arquitetura
6. Integração no app Flutter
7. Integração no iOS nativo
8. O receptor: o backend que recebe a telemetria
9. O dashboard: implantação
10. Volume, custo e amostragem
11. Privacidade e segurança
12. Validação de ponta a ponta
13. Implantação gradual e operação
14. Armadilhas comuns
15. Referência rápida

---

## 1. O que você ganha, e o que não

**Ganha:**

- **A jornada de cada sessão**: telas vistas, fluxos começados e
  terminados (login, compra, cadastro), ações do usuário e como cada uma
  terminou (sucesso, falha, cancelado, concluído sem resultado) e por quê
  (`invalidPassword`, `paymentDeclined`).
- **O detalhe técnico de cada ação**: o trace da ação no Flutter, a chamada
  ao nativo, o HTTP e, se o backend propagar, os spans do backend.
- **Busca de investigação**: por aparelho, instalação, usuário ou sessão,
  inclusive vários aparelhos de uma pessoa de uma vez.
- **Visão geral**: taxa de falha por fluxo, por versão e por motivo; o que
  mudou em relação ao período anterior; ações mais lentas.
- **Padrão aberto**: o app emite OpenTelemetry comum (OTLP/HTTP, traces e
  logs). Qualquer destino OTLP recebe os dados; o dashboard é opcional.
- **Privacidade por padrão**: só sai do aparelho o que está numa lista de
  permissão, e os valores passam por regras de mascaramento.

**Não é:**

- analytics de produto (funil de marketing, cohort, A/B);
- crash reporter (mantenha o seu);
- métricas (contadores, histogramas do SDK) nem logs livres;
- APM de backend (os spans do backend só aparecem se o backend os gerar e
  gravar).

---

## 2. Arquitetura em uma página

```text
┌───────────────────────────── aparelho ─────────────────────────────┐
│ Flutter (Dart)                         iOS nativo (Swift)          │
│  Journey: telas, fluxos, ações          Journey: telas nativas     │
│  spans: OTel Dart SDK                   spans: OTel Swift          │
│        │                                     │                     │
│        └──────── canal da plataforma ────────┘                     │
│          (spans e eventos nativos, estado da jornada, contexto)    │
│        ▼                                                           │
│  Pipeline único (Dart): sessão → redação → fila → envio            │
│        │ OTLP/HTTP protobuf: /v1/traces e /v1/logs                 │
│        │ (pelo HTTP do Dart, ou pela rede do app nativo)           │
└────────┼───────────────────────────────────────────────────────────┘
         ▼
  Receptor: um collector, o backend do app, ou o receptor do dashboard
  (autentica, carimba o aparelho, filtra, insere)
         ▼
  MongoDB: spans e events (só inserção)
         ▼
  Dashboard (MODE=query): agrega sessions e rollups, serve a interface
  e a API, atrás do SSO do portal
```

Peças e contratos:

| Peça | O que faz | Contrato |
|---|---|---|
| Biblioteca, Dart | Inicializa o OTel, mantém a sessão, aplica a redação e exporta tudo (Dart e nativo) | [specs/](specs/) |
| Biblioteca, Swift | Envia spans e eventos nativos ao Dart; propaga o trace pelo canal; `Journey` nativo | [specs/native-bridge.md](specs/native-bridge.md) |
| O que o app envia | Chaves, eventos, ids e regras para quem recebe | [specs/journey.md](specs/journey.md) |
| Receptor | Recebe OTLP, autentica, grava | seção 8 deste guia |
| Armazenamento | Coleções, campos e índices do MongoDB | [storage-schema.md](https://github.com/luizroddev/otel-journey-dashboard/blob/main/docs/storage-schema.md) |
| Dashboard | Agrega e mostra; API de consulta | [query-api.md](https://github.com/luizroddev/otel-journey-dashboard/blob/main/docs/query-api.md) |
| Conformidade | 29 verificações sobre o que o receptor gravou | `npm run conformance` no dashboard |

Os dois sinais:

- **Eventos (logs OTLP com `event.name`)**: o que é instantâneo. Inclui
  tela vista, começo e fim de fluxo, ação pontual, resultado de uma ação
  medida, início de sessão e mudança de estado do app. É a jornada.
- **Spans (traces OTLP)**: o que tem duração e filhos. Inclui ação medida,
  chamada ao nativo e HTTP. É o detalhe técnico.

Nenhum span fica aberto enquanto o usuário está numa tela: um span raiz só é
exportado quando termina, e um app fechado no meio levaria a raiz e
deixaria os filhos órfãos. Por isso fluxos são eventos, não spans longos.

---

## 3. Vocabulário

| Termo | Significado | Chave |
|---|---|---|
| Sessão | Um período de uso; termina por inatividade (30 min) ou duração máxima (4 h), ou quando o app nativo decide | `session.id` |
| Instalação | Uma instalação do app; no iOS, `identifierForVendor` | `app.installation.id` (recurso) |
| Aparelho | O aparelho que o backend autenticou; **nunca vem do app** | `deviceId` (gravado pelo receptor) |
| Usuário | Id opaco, só depois do login | `user.id` |
| Tela | Código fixo da tela | `app.screen.name` |
| Fluxo | Uma jornada entre telas: login, compra | `journey.flow.name` |
| Execução do fluxo | Uma tentativa daquele fluxo; tem começo, fim e resultado | `journey.flow.instance_id` |
| Ação pontual | Uma escolha sem duração | evento `journey.action` |
| Ação medida | Uma operação com duração e trace | span + evento `journey.action` com `journey.duration_ms` |
| Resultado | `success`, `failure`, `cancelled`, `completed` | `journey.outcome` |
| Motivo | Código fixo que explica o resultado | `journey.outcome_reason` |
| Sem conclusão | Fluxo que começou e não terminou; **não** quer dizer abandonado | (ausência de `journey.flow.end`) |

`completed` quer dizer "o código terminou e o app não disse se deu certo".
Nunca é tratado como sucesso.

---

## 4. Levantamento do sistema-alvo

Antes de escrever código, responda às perguntas abaixo. Cada resposta muda
uma decisão da seção 5; a coluna "Decide" aponta qual.

### 4.1 Perguntas

**App**

| Pergunta | Por que importa | Decide |
|---|---|---|
| O app é Flutter puro, add-to-app (host nativo com módulo Flutter) ou misto, com telas nativas e Flutter no mesmo fluxo? | Fluxos mistos precisam do `Journey` no Swift e do estado compartilhado | D3, seção 7 |
| Quantas engines Flutter existem? São criadas no launch ou sob demanda? | O lado nativo guarda spans e eventos até o Dart ficar pronto (até 512 de cada) | seção 7.1 |
| Como a navegação funciona (Navigator, go_router, auto_route, coordinator nativo)? Rotas têm nome fixo? | Telas vêm do nome da rota; caminhos com ids vazariam dados | seção 6.4 |
| Gerência de estado (Bloc, Cubit, Provider, Riverpod)? | Onde encaixar as ações medidas | seção 6.10 |
| Quais são os fluxos críticos e onde cada um começa e termina? Que motivos de falha o produto quer distinguir? | Vira o catálogo de enums | seção 6.3 |
| Existe configuração remota e um mecanismo de liga/desliga? | Kill switch sem nova versão | D9 |

**Rede**

| Pergunta | Por que importa | Decide |
|---|---|---|
| O HTTP do Flutter sai pelo Dart (dio, `package:http`) ou vai para o nativo por canal? | Onde nasce o span de HTTP; evitar dois spans para o mesmo request | seções 6.8 e 7.3 |
| No nativo, existe um ponto único de rede (um client sobre Alamofire ou `URLSession`)? | É ali que entra `HTTPClientSpan` | seção 7.3 |
| A rede exige certificate pinning, TLS mútuo, headers de gateway ou assinatura de request? | Se sim, a telemetria deve sair pela rede do app | D2 |
| Para quais hosts o app pode enviar `traceparent`? | Ids de trace não devem ir para terceiros | seções 6.8 e 7.3 |
| O backend propaga `traceparent` e gera spans? | O trace pode continuar até o servidor | seção 8.10 |

**Sessão e identidade**

| Pergunta | Por que importa | Decide |
|---|---|---|
| O app já tem um conceito de sessão? Onde nasce (nativo, Dart, servidor) e quem decide a renovação? | Quem é o dono da sessão | D3 |
| O backend valida o aparelho antes do login? Com qual header? | Fonte confiável de `deviceId` | D4 |
| Que identificador de usuário existe que não seja dado pessoal (id interno de cliente)? Se não existe, dá para usar um HMAC com segredo do servidor? | `user.id` precisa ser opaco | D4 |
| Por qual identificador as investigações começam (documento, conta, telefone)? Qual serviço resolve esse identificador para aparelho ou usuário? | Esse identificador **não** entra na telemetria; a busca começa no serviço que já o resolve | seção 9.6 |

**Backend e armazenamento**

| Pergunta | Por que importa | Decide |
|---|---|---|
| Existe um backend do app (BFF, gateway) que pode receber `/v1/traces` e `/v1/logs`? Em que linguagem? | Quem implementa o receptor | D1 |
| Esse backend já filtra atributos, nomes de span ou de evento por lista fixa? Mascara dígitos? | Precisa aceitar o contrato e não mascarar ids | seções 8.4 e 8.5 |
| Ele aceita OTLP em protobuf? E `gzip`? | O padrão da biblioteca é protobuf; gzip é opcional | D2, seção 8.2 |
| Há MongoDB disponível? Banco próprio ou compartilhado? Quem cria índices? | `COLLECTION_PREFIX`, permissões | D5 |
| Qual retenção é permitida para dados de telemetria? | `RETENTION_DAYS`, `expireAt` | D7 |

**Acesso e observabilidade**

| Pergunta | Por que importa | Decide |
|---|---|---|
| Onde o dashboard vai morar: domínio próprio ou subcaminho de um portal? Qual SSO? | `BASE_PATH`, proxy de autenticação | D6 |
| Qual ferramenta de logs ou traces o time já usa? Qual é a URL de busca por trace id? | `TRACE_LINK_TEMPLATE` | D6 |
| O app já usa OpenTelemetry (provider próprio no Swift, tracers por área)? | Convivência com o provider existente | D8 |
| O app já tem uma camada própria de jornada ou analytics? | Plano de migração | D8, seção 6.14 |

**Volume e privacidade**

| Pergunta | Por que importa | Decide |
|---|---|---|
| Quantos usuários ativos por dia e sessões por dia? Qual o pico por hora? | Tamanho do banco, número de requests, amostragem | D7, seção 10 |
| Existe uma regra interna sobre dados pessoais em logs (lei de proteção de dados, política de segurança)? | Allowlist, retenção, controle de acesso | seção 11 |
| Quem pode ver a jornada de um cliente, e esse acesso precisa ser auditado? | Proxy de SSO, auditoria fora do dashboard | D6 |

### 4.2 Buscas no código

Comandos para mapear o app rapidamente (`rg` é o ripgrep):

```bash
# Flutter: clients HTTP e onde nascem
rg -n "Dio\(|http\.Client\(|HttpClient\(|package:http/http.dart" --type dart
rg -n "http\.(get|post|put|delete|patch)\(" --type dart   # chamadas diretas, não rastreadas
rg -n "interceptors\.add|extends Interceptor|RetryClient|BaseClient" --type dart

# Flutter: canais com o nativo
rg -n "MethodChannel\(|invokeMethod|setMethodCallHandler|EventChannel" --type dart

# Flutter: navegação e estado
rg -n "MaterialApp|GoRouter|AutoRoute|navigatorObservers|RouteSettings\(name" --type dart
rg -n "extends Bloc<|extends Cubit<|on<" --type dart

# Flutter: telemetria existente
rg -n "opentelemetry|OTel\.|Tracer|Span\b|analytics|track\(|logEvent" --type dart

# iOS: canais, rede, sessão, telemetria
rg -n "FlutterMethodChannel|setMethodCallHandler|invokeMethod" --type swift
rg -n "Alamofire|Session\(|URLSession|dataTask|RequestAdapter|RequestInterceptor" --type swift
rg -n "session|Session" --type swift -i | rg -i "id|manager|renew|expire"
rg -n "OpenTelemetry|TracerProvider|spanBuilder|SpanProcessor" --type swift
rg -n "viewDidAppear|Coordinator|FlutterEngine\(|FlutterViewController" --type swift
```

### 4.3 Modelo do relatório de levantamento

```markdown
## Levantamento: <app>

- Forma do app: <Flutter puro | add-to-app | misto>; engines: <n, quando sobem>
- Fluxos críticos: <fluxo: começa em …, termina em …, motivos de falha …>
- Navegação: <ferramenta>; rotas com nome fixo: <sim/não>
- HTTP Flutter: <dio/http/canal>, ponto único: <arquivo>; nativo: <client>, ponto único: <arquivo>
- Exigências de rede: <pinning, TLS mútuo, headers de gateway>
- Sessão: <dono, regras>; aparelho validado no backend por: <header>
- Usuário: <id opaco disponível? HMAC?>; identificador de investigação: <…>, resolvido por <serviço>
- Backend receptor: <serviço, linguagem>; filtros existentes: <allowlists, mascaramento>
- Banco: <MongoDB próprio/compartilhado>; retenção permitida: <dias>
- Portal: <URL/subcaminho>, SSO: <…>; ferramenta de logs: <URL de busca por trace id>
- Telemetria existente: <OTel nativo, camada de jornada, analytics>
- Volume: <DAU, sessões/dia, pico/hora>
- Restrições de privacidade: <…>
- Riscos e dúvidas em aberto: <…>
```

---

## 5. Decisões de arquitetura

Registre cada decisão (contexto, escolha, consequência) num documento curto
do próprio sistema.

### D1. Para onde vai o OTLP

| Opção | Quando | Consequência |
|---|---|---|
| **A. O backend do app recebe e grava no MongoDB** | Já existe um backend que autentica o aparelho e o usuário | Você implementa o receptor (seção 8). Só inserção, sem estado. O dashboard roda em `MODE=query` |
| **B. O backend repassa ao receptor do dashboard** | Gravar no MongoDB pelo backend ainda não é possível | O backend autentica e repassa o corpo intacto com dois headers confiáveis; o dashboard roda em `MODE=ingest`, acessível só pela rede do backend |
| **C. Direto para o receptor do dashboard** | Projetos pessoais, ambiente de teste | `MODE=all`; sem identidade autenticada (`deviceId` fica nulo) |
| **D. Um OpenTelemetry Collector no meio** | A empresa já opera collectors e quer replicar para outras ferramentas | O collector exporta OTLP/HTTP para o receptor (opção B ou C); não há exportador oficial para este schema do MongoDB |

Recomendação: **A** quando existe backend; **B** como passo intermediário.

### D2. Como a telemetria sai do aparelho

| Opção | Quando | Configuração |
|---|---|---|
| HTTP do Dart (padrão) | Sem exigências especiais de rede | `endpoint` |
| Rede do app nativo | Pinning, TLS mútuo, headers de gateway, assinatura | `sendThroughNative: true` + `exportHandler` no Swift (seção 7.4) |
| Transporte próprio no Dart | Um client Dart com essas exigências | `initialize(transport:, logTransport:)` |

Em todos os casos: `gzip: true` se o receptor aceitar (o corpo fica em torno
de um quinto). O corpo é OTLP **protobuf**. Se o backend só aceita OTLP
JSON, prefira ensinar o backend a ler protobuf (classes geradas dos
`.proto` oficiais) a converter no aparelho.

### D3. Quem é o dono da sessão

| Opção | Quando | Configuração |
|---|---|---|
| A biblioteca (padrão) | O app não tem sessão própria | 30 min de inatividade, 4 h no máximo (`SessionConfig`) |
| O app nativo | A sessão nasce no nativo, antes do Flutter, e o nativo decide a renovação | Swift `setSession(id:previousId:)` + Dart `SessionConfig(fromHost: true)` |
| Outro dono no Dart | A sessão vem de outro lugar no Dart | `sessionIdProvider:` + `Journey.sessionStarted` |

O id de sessão deve ser aleatório e não pode identificar ninguém.

### D4. Identidade

- **Instalação**: `OtelBridgeConfig.installationId` (`identifierForVendor` no
  iOS, um UUID guardado pelo app no Android). Vai no recurso.
- **Aparelho**: carimbado **pelo receptor** a partir do que ele autenticou
  (um header que ele já valida). Nunca do payload: o app pode mentir.
- **Usuário**: `Journey.setUser(id)` depois do login, `null` no logout. Use
  um id interno opaco. Sem ele, o receptor troca o valor por um HMAC com
  segredo do servidor. Um hash simples de um documento não protege nada,
  porque o espaço de documentos válidos é pequeno o bastante para calcular
  o hash de todos.
- **Regra do usuário no receptor**: substituir `user.id` pelo usuário
  autenticado **só nos registros que já têm `user.id`**. Eventos de antes do
  login, mesmo enviados depois dele no mesmo lote, ficam sem usuário. Uma
  requisição sem o header autenticado mantém o valor do payload.

### D5. Armazenamento

| Opção | Quando | Configuração |
|---|---|---|
| Banco próprio | Possível criar um banco | `MONGO_DB` |
| Banco compartilhado | Só há um banco do sistema | `COLLECTION_PREFIX=journey_`; o receptor grava em `journey_spans` e `journey_events` |
| Outro banco | Sem MongoDB | Reimplementar a gravação e a API de consulta (`query-api.md`); custo alto |

Permissões:

- o receptor **insere** em `spans` e `events`;
- o dashboard **lê** `spans` e `events` e **escreve** `sessions`, `rollups`
  e `jobs`;
- instâncias extras só de leitura usam `AGGREGATOR=off`.

### D6. Onde o dashboard roda e quem acessa

- Atrás do SSO do portal: o proxy autentica e repassa. O dashboard não tem
  contas próprias; `API_TOKEN` existe para uso local.
- Num subcaminho: `BASE_PATH=/journey/`. O proxy repassa o caminho como
  está, sem tirar o prefixo.
- Link para a ferramenta de logs: `TRACE_LINK_TEMPLATE` com `{traceId}`.
- Auditoria de acesso, se exigida, fica no proxy ou no portal.

### D7. Volume, amostragem e retenção

Veja a seção 10. Pontos de partida:

- `sampleRatio` 1.0 em desenvolvimento e homologação;
- em produção, comece com um valor baixo e suba;
- eventos da jornada não são amostrados, por isso cabem 100% dos fluxos
  mesmo com traces amostrados;
- `RETENTION_DAYS` pelo que a política permite;
- `ROLLUP_RETENTION_DAYS` maior, porque os contadores por hora são pequenos.

### D8. Convivência com o que já existe

- **OpenTelemetry nativo próprio**: registre o provider do app com os
  processadores da biblioteca (`registerGlobal: false`,
  `makeAppContextProcessor()`, `makeSpanProcessor()`). Os spans do app
  passam a ir pelo mesmo pipeline.
- **Camada de jornada própria**: migre para `Journey` (mapa na seção 6.14)
  ou mantenha as duas por um período, com nomes distintos.
- **Analytics de produto**: continua; a jornada não substitui funis de
  marketing.

### D9. Liga/desliga e ambientes

- `OtelBridgeConfig.enabled` e `OtelFlutterBridge.setEnabled(bool)` vindos
  da configuração remota, com efeito nos dois lados.
- Ambientes em `deploymentEnvironment` (`dev`, `qa`, `staging`,
  `production`).
- `OtelBridgeConfig.fromMap` lê a configuração inteira de um mapa remoto,
  sem lançar erro.

---

## 6. Integração no app Flutter

### 6.1 Dependência

Use git com referência fixa (tag ou commit). Nunca uma branch.

```yaml
dependencies:
  otel_flutter_bridge:
    git:
      url: https://github.com/luizroddev/otel_flutter_bridge
      path: packages/otel_flutter_bridge
      ref: <tag ou commit>
  otel_flutter_bridge_dio:            # só se o app usa dio
    git:
      url: https://github.com/luizroddev/otel_flutter_bridge
      path: packages/otel_flutter_bridge_dio
      ref: <mesma referência>
dependency_overrides:                 # enquanto o núcleo não está no pub.dev
  otel_flutter_bridge:
    git:
      url: https://github.com/luizroddev/otel_flutter_bridge
      path: packages/otel_flutter_bridge
      ref: <mesma referência>
```

No iOS, CocoaPods traz `OpenTelemetry-Swift-Api` e `-Sdk` (versões fixas no
podspec).

### 6.2 Inicialização

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final remote = await carregarConfigRemota();          // do app
  await OtelFlutterBridge.initialize(
    OtelBridgeConfig(
      serviceName: 'meu-app',
      serviceVersion: versaoDoApp,
      deploymentEnvironment: ambiente,                    // dev, qa, production
      endpoint: Uri.parse('https://telemetria.exemplo.com'),
      installationId: idDaInstalacao,                     // iOS: identifierForVendor
      enabled: remote.telemetriaLigada,
      sampleRatio: remote.amostragem,                     // 0..1
      exportLogs: true,                                   // a jornada (logs OTLP)
      gzip: true,                                         // se o receptor aceita
      sendThroughNative: false,                           // D2
      session: const SessionConfig(fromHost: false),      // D3
      redaction: const RedactionConfig(
        allowedPrefixes: {'app.', 'loja.'},               // atributos próprios
        extraPatterns: [r'PED-\d+'],                      // ids próprios a mascarar
      ),
    ),
    onDiagnostic: (d) => logger.debug('[otel] $d'),
  );
  runApp(const App());
}
```

- `initialize` nunca lança: se falhar, a biblioteca fica desligada e o app
  segue.
- A configuração pode vir inteira de um mapa remoto: `OtelBridgeConfig.fromMap`.
- `/v1/traces` e `/v1/logs` são acrescentados ao `endpoint`; esse é o único
  host que a biblioteca contata.
- O que está pendente é enviado quando o app sai do primeiro plano.

### 6.3 O catálogo da jornada

Declare em um arquivo só, revisável:

```dart
// lib/telemetry/journey.dart
enum AppScreen with JourneyScreen {
  home('Início'), login('Login'), cart('Carrinho');
  const AppScreen(this.label);
  @override
  final String label;
}
enum AppFlow with JourneyFlow { login, signUp, checkout }
enum AppAction with JourneyAction { chooseBiometric, confirmLogin, pay }
enum LoginReason with JourneyReason {
  invalidPassword, blockedAccount, expiredSession, networkUnavailable,
}
```

Regras:

- O **código** é o nome do valor do enum. Nunca mude o sentido de um código
  publicado; para renomear no código Dart, sobrescreva `code` com o valor
  antigo.
- **Rótulos** (`label`) são para pessoas e podem mudar.
- Motivos vêm de uma lista fixa: nunca texto de erro, mensagem do servidor
  ou ids.
- Um motivo por causa que o produto quer distinguir. Tecnicamente iguais
  mas com tratamento diferente (senha errada × conta bloqueada) merecem
  motivos diferentes.
- Comece pelos fluxos críticos e cresça aos poucos.

### 6.4 Telas

```dart
MaterialApp(navigatorObservers: [JourneyNavigatorObserver()]);
```

- Só rotas de página contam (diálogos e bottom sheets não). A tela é o
  `RouteSettings.name`.
- `screenOf:` mapeia rotas para o enum; `useRouteNames: false` ignora as
  rotas sem mapa.
- Nomes de rota fixos (`/cart`), nunca caminhos com ids (`/orders/123`).
- go_router e auto_route: chame `Journey.screen(AppScreen.x)` no listener
  do router, com o nome da rota, não a `location`.
- Nunca escreva em `AppContext` direto: isso carimba spans, mas não gera
  eventos nem chega ao nativo.

### 6.5 Fluxos

```dart
final run = Journey.startFlow(AppFlow.checkout);
// ... telas e ações ...
run.end(JourneyOutcome.success);
run.end(JourneyOutcome.failure, reason: CheckoutReason.paymentDeclined);
run.end(JourneyOutcome.cancelled, reason: CheckoutReason.userLeft);
// De outro lugar (outra tela, outro Bloc, o nativo):
Journey.flowRun(AppFlow.checkout)?.end(JourneyOutcome.success);
```

- Termine em **todos** os caminhos: sucesso, falha, cancelamento e saída
  pelo botão voltar. Um fluxo sem fim aparece como "sem conclusão".
- Fluxo dentro de fluxo (por exemplo, ativar token no meio do login) é
  aninhado. Os eventos levam `journey.flow.parent_instance_id`, e ao
  terminar o interno o externo volta a ser o atual.
- Só o primeiro `end` conta, dos dois lados.
- Não passe o objeto do fluxo por argumentos de rota: use
  `Journey.flowRun(flow)` ou `Journey.currentFlow`.

### 6.6 Ações

```dart
// Pontual: uma escolha, sem duração.
Journey.event(AppAction.chooseBiometric, attributes: {'app.login.method': LoginMethod.biometric});

// Medida: span + evento com duração e resultado.
final r = await Journey.track(
  AppAction.confirmLogin,
  () => auth.login(credenciais),
  outcome: (r) => r.ok ? JourneyOutcome.success : JourneyOutcome.failure,
  reason: (r) => r.reason,                        // um LoginReason, ou null
  errorType: (e) => e is TimeoutException ? 'timeout' : e.runtimeType.toString(),
);
```

- Exceções viram `failure` com `error.type` (nunca o texto) e são relançadas
  com a stack original.
- Tela, fluxo, usuário e sessão são os do início da ação.
- O HTTP e as chamadas ao nativo feitas dentro de `track` viram filhos do
  span.
- Atributos próprios: chaves `app.*` (ou o prefixo próprio permitido) com
  valores de lista fixa. Nunca valores livres.

### 6.7 Usuário

```dart
Journey.setUser(usuario.idOpaco);   // depois do login
Journey.setUser(null);              // no logout
```

Se o próximo usuário do aparelho deve ter outra sessão, renove a sessão no
logout: com a sessão do app nativo, chame `setSession` com um id novo e sem
`previousId`; com um `SessionManager` próprio passado em
`sessionIdProvider`, chame `reset()`.

### 6.8 HTTP no Dart

```dart
// package:http: envolva o client único do app.
final client = OtelHttpClient(http.Client(), propagateTo: {'api.exemplo.com'});

// dio
dio.interceptors.add(OtelDioInterceptor(propagateTo: {'api.exemplo.com'}));
```

- Um span de cliente por tentativa. Registra só método, host, porta,
  esquema e caminho (ids no caminho viram `{id}`), status e `error.type`.
- `propagateTo` limita o `traceparent` aos hosts da empresa.
- Retry por fora do client rastreado: cada tentativa é um span.
- Se o HTTP do Flutter vai para o nativo por canal, **não** rastreie no
  Dart: use `invokeTraced` (seção 6.9) e o span de HTTP nasce no nativo
  (seção 7.3). Assim não há dois spans para o mesmo request.

### 6.9 Canais com o nativo

```dart
await canal.invokeTraced('pagar', arguments: {'valor': 10});   // Dart → nativo
canal.setTracedMethodCallHandler((call) async { ... });        // nativo → Dart
```

Os argumentos precisam ser um `Map`, porque o contexto viaja numa chave
extra (`_otel`). Antes do `initialize`, ou se a telemetria falhar, a chamada
sai sem rastreio e com os argumentos intactos.

### 6.10 Bloc e Cubit

```dart
on<ConfirmarPagamento>(tracedHandler('checkout.pay', _onPagar));
on<Login>(tracedHandler('auth.login', _onLogin,
    nameOf: (e) => e is LoginBiometria ? 'auth.login.biometric' : 'auth.login.password'));
```

Para ações que importam ao produto, prefira `Journey.track` dentro do
handler: além do span, gera o evento com resultado e motivo.

### 6.11 Liga/desliga

```dart
await OtelFlutterBridge.setEnabled(false);   // Dart e nativo; descarta o pendente
```

### 6.12 Inspetor

Num menu de debug: `TelemetryInspectorPage` (import
`package:otel_flutter_bridge/inspector.dart`) e
`TelemetryInspectorController.instance.attach()` no `main`. Mostra cada
span exportado, já redigido, e quantos atributos a redação removeu.

### 6.13 Testes automatizados no app

```dart
final traces = InMemoryTransport();
final logs = InMemoryLogTransport();
await OtelFlutterBridge.initialize(
  OtelBridgeConfig(serviceName: 'teste', endpoint: Uri.parse('http://x')),
  transport: traces,
  logTransport: logs,
  connectNative: false,
);
// ... executa o fluxo ...
await OtelFlutterBridge.flush();
// Verifique: eventos em logs.records, spans em traces.spans, nenhum valor
// pessoal em traces.requests / logs.requests.
await OtelFlutterBridge.shutdown();
```

### 6.14 Migrar uma camada de jornada própria

Apps que já instrumentaram jornadas costumam ter padrões parecidos. O mapa
para `Journey`:

| Padrão comum | Problema | Em `Journey` |
|---|---|---|
| Um span raiz que vive enquanto o fluxo dura | Só é exportado no fim; app fechado no meio perde a raiz e deixa os filhos órfãos; a amostragem leva ou descarta o fluxo inteiro | `Journey.startFlow` / `run.end` (eventos) |
| Passos como spans filhos `<fluxo>.<passo>` | Dependem da raiz aberta | `Journey.track(acao, ...)` ou `begin`/`end` no Swift |
| Um enum grande de resultados por domínio | Mistura resultado e motivo | `JourneyOutcome` (4 valores) + um enum `JourneyReason` por domínio |
| `cancel()` separado | | `run.end(JourneyOutcome.cancelled, reason: ...)` |
| Objeto do fluxo passado entre telas por argumentos de rota | Acopla telas; não atravessa o nativo | `Journey.flowRun(flow)`, estado compartilhado com o Swift |
| Número da tentativa como atributo | | Cada `startFlow` é uma execução nova; o dashboard numera as tentativas. Para tentativas dentro de uma execução, use um atributo `app.*` |
| Liga/desliga fixo no código (por build ou plataforma) | Desligar exige nova versão | `enabled` e `setEnabled` pela configuração remota |
| Lista de prefixos permitidos na redação | | `RedactionConfig(allowedPrefixes:)`; as chaves `journey.*` já são permitidas |
| Gerenciador de sessão no Dart quando o nativo já tem sessão | Duas sessões para a mesma pessoa | `SessionConfig(fromHost: true)` + `setSession` |
| Transporte próprio que manda a telemetria pela rede do app | Código a manter | `sendThroughNative` + `exportHandler` |
| Amostragem diferente por ambiente | | `sampleRatio` por ambiente, pela configuração |

Estratégia: migre fluxo a fluxo. Durante a transição, mantenha os nomes
antigos fora do namespace `journey.` para não colidir, e compare as
contagens das duas camadas antes de remover a antiga.

---

## 7. Integração no iOS nativo

### 7.1 Início

No `application(_:didFinishLaunchingWithOptions:)`, antes da engine:

```swift
import otel_flutter_bridge

OtelFlutterBridge.shared.start()                  // aparelho, iOS e conexão entram sozinhos
HTTPClientSpan.propagateTo = ["api.exemplo.com"]  // traceparent só para os hosts da empresa
```

- Spans e eventos nativos criados antes do Dart ficar pronto esperam numa
  fila: até 512 de cada; os mais antigos saem primeiro.
- O app já tem um `TracerProvider`? Use
  `start(registerGlobal: false)` e adicione
  `makeAppContextProcessor()` e `makeSpanProcessor()` ao provider dele,
  nessa ordem.
- `start(resourceAttributes:)` acrescenta atributos de recurso, que também
  precisam passar pela redação do Dart.

### 7.2 Sessão do app nativo

```swift
// No launch, antes da engine, e a cada sessão nova:
OtelFlutterBridge.shared.setSession(id: sessao.id, previousId: sessaoExpirada?.id)
```

Com `SessionConfig(fromHost: true)` no Dart, o comportamento é este:

- o Dart segue a sessão nativa;
- uma sessão nova registra `session.start`;
- spans e eventos nativos levam a sessão desde o início.

`previousId` só quando a nova continua uma que expirou; nunca depois de um
logout.

### 7.3 Rede nativa

No ponto único de rede (o client que todo request atravessa):

```swift
let call = HTTPClientSpan.start(urlRequest)            // pai: o span atual
session.request(call.request).validate().responseData { response in
  call.finish(response: response.response, error: response.error) {
    completion(response)                               // roda no trace de quem pediu
  }
}
```

- `finish` em todos os caminhos: sucesso, erro e cancelamento.
- `error.type` é o status (4xx/5xx) ou o código do `URLError`
  (`URLError.timedOut`, `URLError.notConnectedToInternet`,
  `URLError.serverCertificateUntrusted`).
- `network.connection.type` (`wifi`, `cell`, `unavailable`) entra sozinho.
- `URLSession` direto: `TracedURLSession.data(for:)` / `dataTask(with:)`.
- Sem swizzling: só é rastreado o que passa por aqui.

### 7.4 Telemetria pela rede do app

Com `sendThroughNative: true` no Dart:

```swift
OtelFlutterBridge.shared.exportHandler = { export, completion in
  guard let request = export.urlRequest() else { return completion(false) }
  apiClient.send(request) { response in completion(response.isSuccess) }
}
```

- `export.urlRequest(endpoint:)` monta o `POST` (URL derivada do `endpoint`
  do Dart, ou a do app) com corpo e headers (`Content-Type`,
  `Content-Encoding: gzip` quando ligado, headers da configuração).
- O request vem **marcado como telemetria** e o `HTTPClientSpan` não o
  rastreia. Requests montados à mão: `request.markAsTelemetry()`. Sem
  isso, cada envio geraria um span a enviar, sem fim.
- `completion(true)` só para 2xx. Sem handler, sem resposta dentro do
  `exportTimeout` ou com recusa, o envio conta como falha.
- Se o client do app adiciona headers (gateway, assinatura), a marca
  sobrevive: é uma propriedade do `URLProtocol`, nunca enviada.

### 7.5 Canais e código assíncrono

```swift
canal.setMethodCallHandler(OtelFlutterBridge.shared.traced(channel: "app/pagamento") { call, result in
  // o handler de sempre; o span termina quando result é chamado
})
canal.invokeTraced("carrinhoAtualizado", arguments: [...])   // nativo → Dart, no mesmo trace
let depois = OtelFlutterBridge.shared.bind(callback)           // callback guardado
OtelFlutterBridge.shared.task { await servico.carregar() }    // Task com o span atual
let span = OtelFlutterBridge.shared.span("Carrinho.ler")      // span próprio; sobrevive a await
```

### 7.6 Telas e fluxos nativos

```swift
enum AppScreen: String, JourneyScreen { case documento, endereco }
enum AppFlow: String, JourneyFlow { case login, checkout }   // mesmos códigos do Dart
enum AppAction: String, JourneyAction { case confirmarDocumento }
enum LoginReason: String, JourneyReason { case documentoInvalido }

class BaseViewController: UIViewController {
  var journeyScreen: AppScreen? { nil }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if let screen = journeyScreen { Journey.screen(screen) }
  }
}

let acao = Journey.begin(AppAction.confirmarDocumento)
TraceContext.with(acao.span) {
  api.validar(documento) { r in
    acao.end(r.ok ? .success : .failure, reason: r.ok ? nil : LoginReason.documentoInvalido)
  }
}
Journey.flowRun(AppFlow.login)?.end(.success)
```

- Tela atual, fluxos abertos e usuário são **os mesmos** nos dois lados:
  um fluxo que começa numa tela nativa e termina numa tela Flutter é uma
  execução só.
- Os códigos dos fluxos precisam ser iguais no Swift e no Dart.
- Eventos nativos saem marcados com `otel_flutter_bridge.source = native`
  (o dashboard mostra "nativo").
- `Journey.track` assíncrono também existe; `begin`/`end` é a forma
  natural com callbacks.

### 7.7 Segundo plano e ciclo de vida

Nada a configurar. Ao ir para segundo plano:

- o nativo segura uma tarefa em segundo plano e pede ao Dart para enviar
  tudo; a tarefa termina quando o Dart responde, ou em 10 s;
- a jornada registra `device.app.lifecycle` (`ios.app.state`:
  `background`, `foreground`, `terminate`), e o dashboard mostra "Saiu do
  app" e "Voltou ao app".

### 7.8 Android

A telemetria Dart funciona no Android. Ainda não existe a ponte nativa
Android (spans e `Journey` em Kotlin): telas nativas Android não entram na
jornada.

---

## 8. O receptor: o backend que recebe a telemetria

Esta seção vale para qualquer linguagem. A referência executável está no
dashboard (`server/src/ingest/mapping.ts`, `server/src/store/mongo.ts`).

### 8.1 Rotas e respostas

- `POST <prefixo>/v1/traces` e `POST <prefixo>/v1/logs`. O app só muda o
  `endpoint`.
- Corpo `application/x-protobuf`; aceite `Content-Encoding: gzip`. JSON
  (`application/json`) é opcional.
- Respostas:

  | Código | Quando |
  |---|---|
  | 200 com corpo vazio | Sucesso |
  | 400 | Corpo malformado (não adianta reenviar) |
  | 401 / 403 | Falha de autenticação |
  | 413 | Grande demais |
  | 415 | Tipo ou codificação não aceitos |
  | 429 / 503 | Não dá para gravar agora (clientes OTLP padrão reenviam depois) |

- A biblioteca ainda não reenvia (o buffer offline está no roteiro): hoje
  todo envio que não recebe 2xx é perdido e contado em `onDiagnostic`.

### 8.2 Decodificar

Gere as classes a partir dos `.proto` oficiais do OpenTelemetry
(`opentelemetry/proto/collector/{trace,logs}/v1/*.proto`, versão 1.5.0 no
dashboard) com o protobuf da sua linguagem, e leia
`ExportTraceServiceRequest` / `ExportLogsServiceRequest`. Em .NET, Java,
Go e Node existem pacotes prontos com essas classes.

### 8.3 Autenticar e carimbar identidade

1. Autentique a requisição como as outras do app (token, aparelho
   validado).
2. `deviceId` = o aparelho que você autenticou. Sem isso, `null`. Nunca do
   payload.
3. `userId`: troque o `user.id` do registro pelo usuário autenticado
   **apenas se o registro tiver `user.id`**. Se não houver usuário
   autenticado, mantenha o do payload. Se a política exigir, grave um HMAC
   em vez do id.

### 8.4 Lista de permissão

Se o backend filtra o que aceita, ele precisa aceitar **todo** este
contrato, senão a jornada quebra em silêncio:

- **Atributos de recurso**: `service.name`, `service.version`,
  `deployment.environment.name`, `os.type`, `os.name`, `os.version`,
  `device.model.identifier`, `device.manufacturer`, `app.installation.id`,
  `telemetry.sdk.*`.
- **Nomes de evento**: `session.start`, `journey.screen.view`,
  `journey.flow.start`, `journey.flow.end`, `journey.action`,
  `device.app.lifecycle`.
- **Atributos de evento e de span**: as chaves da seção 15.1, as de HTTP
  (`http.request.method`, `http.response.status_code`, `http.route`,
  `url.scheme`, `url.path`, `server.address`, `server.port`,
  `network.protocol.version`, `network.connection.type`), as de RPC
  (`rpc.system`, `rpc.service`, `rpc.method`), as de erro (`error.type`,
  `exception.type`, `exception.message`) e os prefixos próprios do app
  (`app.*`).
- **Nomes de span**: códigos de ação escolhidos pelo app, `{MÉTODO}` para
  HTTP e `{canal}/{método}` para canais. Use um **padrão** (por exemplo
  `^[A-Za-z0-9_.:/-]{1,128}$`), não uma lista fixa: cada ação nova seria
  rejeitada.

### 8.5 Mascaramento: nunca nos ids

Ids são hexadecimais aleatórios: cerca de metade dos ids de 32 caracteres
tem uma sequência de 6 ou mais dígitos, e cerca de 1 em 20 tem 11 ou mais.
Uma regra que mascara números de documento corrompe esses ids e desliga a
jornada. **Não mascare** os valores de:

- `session.id` e `session.previous_id`;
- `user.id` e `app.installation.id`;
- `log.record.uid`;
- `journey.flow.instance_id`, `journey.flow.parent_instance_id` e
  `journey.action.instance_id`;
- trace id e span id.

### 8.6 Limites

Defina pela sua política:

- tamanho do corpo (o dashboard usa 1 MiB antes do gunzip);
- registros por requisição (1000);
- cota por aparelho.

A biblioteca manda no máximo 512 spans ou eventos por requisição.

### 8.7 Gravar no MongoDB

Coleções `spans` e `events`, com o prefixo, se houver. Resumo dos campos
(a especificação completa está em `storage-schema.md`):

- **Campos comuns** (spans e events):

  | Campo | Origem |
  |---|---|
  | `service` | recurso `service.name` |
  | `serviceVersion` | recurso `service.version` |
  | `environment` | recurso `deployment.environment.name` |
  | `platform` | recurso `os.name`, senão `os.type` |
  | `deviceId` | o aparelho autenticado |
  | `installationId` | recurso `app.installation.id` |
  | `sessionId` | `session.id` |
  | `userId` | regra da seção 8.3 |
  | `screen` | `app.screen.name` |
  | `flow` | `journey.flow.name` |
  | `flowInstanceId` | `journey.flow.instance_id` |
  | `actionName` | `journey.action.name` |
  | `actionInstanceId` | `journey.action.instance_id` |
  | `outcome` | `journey.outcome` |
  | `outcomeReason` | `journey.outcome_reason` |
  | `errorType` | `error.type` |
  | `source` | `otel_flutter_bridge.source` |
  | `scope` | `{name, version}` |
  | `receivedAt` | o relógio do receptor |
  | `expireAt` | `receivedAt` + retenção |

  Os valores vêm primeiro dos atributos do registro, depois do recurso.
- **`spans`**:
  - `_id` = `{service}:{traceId}:{spanId}`;
  - `traceId`, `spanId`, `parentSpanId` em hex minúsculo (o protobuf traz
    bytes);
  - `name`, `kind` (número OTLP), `statusCode`, `statusMessage`;
  - `start`/`end` como `Date` e `startNs`/`endNs` como string de
    nanossegundos; `durationMs`;
  - `resource`, `attributes`, `events`, `links`.
- **`events`**:
  - `_id` = `{service}:{log.record.uid}`;
  - `time` (`Date`) e `timeNs`;
  - `eventName` (campo OTLP `event_name`, senão o atributo `event.name`);
  - `severityNumber`, os rótulos `screenLabel` / `flowLabel` /
    `actionLabel`, `durationMs`;
  - `traceId`/`spanId` (nulos fora de um span);
  - `attributes`, sem `resource`.
- **Documentos enxutos**: atributos são uma lista `{ key, value }`, nunca
  um objeto com chaves com ponto. As chaves que viraram campo não se
  repetem em `attributes` e `resource`.
- **Só inserção**: inserção não ordenada que ignora chave duplicada (o app
  reenvia depois de timeout). Nunca escreva `sessions`, `rollups` ou
  `jobs`: o dashboard os deriva.
- **Índices** (uma vez):
  - `spans`: `{traceId:1,start:1}`, `{sessionId:1,start:1}`,
    `{receivedAt:1}`, TTL `{expireAt:1}`;
  - `events`: `{sessionId:1,time:1}`, `{traceId:1}`, `{receivedAt:1}`, TTL
    `{expireAt:1}`.

### 8.8 Pseudocódigo do receptor

```text
handle(signal, request):
  identity = authenticate(request) or reject 401
  body = gunzip_if(request.headers["Content-Encoding"] == "gzip", request.body)
  reject 413 if size(body) > limit
  message = parse_protobuf(signal, body) or reject 400
  docs = []
  for resource_group in message:
    resource = filter_allowed(resource_group.resource)
    for scope in resource_group.scopes:
      for record in scope.items:
        attrs = scrub_except_ids(filter_allowed(record.attributes))
        doc = map_to_schema(signal, resource, scope, record, attrs)   // seção 8.7
        doc.deviceId = identity.device or null
        if doc.userId != null and identity.user: doc.userId = identity.user
        doc.receivedAt = now(); doc.expireAt = now() + retention
        docs.append(doc)
  insert_many_unordered(collection(prefix, signal), docs, ignore_duplicate_keys)
    or reply 503
  reply 200
```

### 8.9 Conformidade

No repositório do dashboard:

```bash
npm run conformance -- --endpoint https://telemetria.exemplo.com \
  --mongo "mongodb://..." --db <banco> [--prefix journey_] \
  --header "Authorization: Bearer <token de teste>" \
  --expect-device <aparelho que o receptor vai autenticar> --expect-user <usuário>
```

O script manda uma sessão fictícia duas vezes (reenvio não pode duplicar)
e confere 29 regras no que foi gravado. Rode a cada mudança no receptor.

### 8.10 Trace até o backend (opcional)

Com `propagateTo` apontando para a API, os requests levam `traceparent`
(W3C). Um backend com OpenTelemetry continua o trace. Se ele também gravar
os spans dele na coleção `spans` (com `sessionId` nulo), o waterfall do
dashboard mostra app e servidor juntos. Sem isso, o trace id ainda liga o
request do app aos logs do servidor (`TRACE_LINK_TEMPLATE`).

### 8.11 Opção B: repassar ao receptor do dashboard

O backend autentica e repassa o corpo **intacto** a uma instância
`MODE=ingest`, acessível só pela rede dele, com dois headers:

```bash
MODE=ingest TRUSTED_DEVICE_HEADER=X-Validated-Device TRUSTED_USER_HEADER=X-Validated-User npm start
```

O receptor aplica as mesmas regras de identidade da seção 8.3.

---

## 9. O dashboard: implantação

### 9.1 Modos

| `MODE` | Roda | Uso |
|---|---|---|
| `all` | receptor + agregador + interface + API | local, projetos pessoais |
| `ingest` | só receptor | opção B |
| `query` | agregador + interface + API | opção A: outro sistema insere |

### 9.2 Variáveis principais

| Variável | Padrão | Para quê |
|---|---|---|
| `MONGO_URL`, `MONGO_DB` | `mongodb://localhost:27017`, `otel_journey` | banco |
| `COLLECTION_PREFIX` | vazio | banco compartilhado (`journey_`) |
| `BASE_PATH` | `/` | subcaminho atrás de proxy (`/journey/`) |
| `TRACE_LINK_TEMPLATE`, `TRACE_LINK_LABEL` | vazio, `Abrir no log` | link do trace para a ferramenta de logs |
| `RETENTION_DAYS` | 30 | TTL de registros e sessões |
| `ROLLUP_RETENTION_DAYS` | 400 | TTL dos contadores por hora |
| `AGGREGATOR` | `on` | `off`: só serve |
| `AGGREGATE_EVERY_SECONDS` / `AGGREGATE_LAG_SECONDS` | 15 / 30 | frequência e atraso do agregador |
| `OVERVIEW_MIN_VOLUME` | 200 | menor grupo comparado na visão geral |
| `API_TOKEN`, `INGEST_TOKEN` | vazio | tokens simples (uso local) |
| `TRUSTED_DEVICE_HEADER`, `TRUSTED_USER_HEADER` | vazio | opção B |
| `MAX_*` | ver README | limites de corpo, janela, página, vista |

### 9.3 Permissões no MongoDB

- **Usuário do dashboard**: lê `spans` e `events`; lê e escreve
  `sessions`, `rollups` e `jobs`; cria os índices dessas três.
- **Usuário do receptor**: insere em `spans` e `events`; cria os índices
  delas.
- Várias instâncias podem rodar: só uma agrega por vez (lease em `jobs`).

### 9.4 Atrás do portal

- **Proxy de SSO** na frente. O dashboard confia em quem chega, então não
  deixe a porta acessível por fora do proxy.
- **`BASE_PATH`** para montar num subcaminho. O proxy repassa o caminho
  inteiro, sem remover o prefixo. `/health` fica na raiz.
- **Imagem Docker**: `docker build` no repositório. Uma imagem serve
  qualquer `BASE_PATH`.

### 9.5 Ferramenta de logs

`TRACE_LINK_TEMPLATE` precisa conter `{traceId}` e começar com `http(s)://`
ou `/`. Use a URL de busca da sua ferramenta por trace id. O link aparece na
página do trace e em cada passo da jornada que tem trace.

### 9.6 Investigações que começam por outro identificador

O dashboard busca por aparelho, instalação, usuário e sessão, aceitando até
50 valores por campo. Se a investigação começa por um identificador pessoal
(documento, conta, telefone):

1. Resolva esse identificador no serviço que já faz isso (por exemplo:
   documento → lista de aparelhos).
2. Abra `/sessions?deviceId=a,b,c` com o resultado, a partir de um link no
   portal.

O identificador pessoal **não** entra na telemetria.

### 9.7 O que o agregador faz

- A cada 15 s, lê o que chegou (por `receivedAt`, com 30 s de atraso) e
  atualiza:
  - `sessions`: um resumo por sessão;
  - `rollups`: contadores por hora, versão, plataforma, fluxo e ação.
- Não conta duas vezes: guarda `upTo` por documento e um registro de
  progresso em `jobs`.
- Na primeira execução, reconstrói tudo a partir dos registros guardados.
- Sessões aparecem cerca de 1 minuto depois de chegar.

---

## 10. Volume, custo e amostragem

### 10.1 Estimativa

Valores medidos nos dados fictícios do dashboard; meça no seu app:

- **Registros por sessão**: de 15 a 60, somando eventos da jornada e spans.
  Cresce com o número de ações medidas e de HTTP.
- **Tamanho no banco**: cerca de 0,8 KB por evento e 1,1 KB por span de
  app, antes dos índices.
- **Requests por sessão**:
  - spans e eventos saem em lotes: no máximo um request por sinal (traces
    e logs) a cada janela de 2 s com atividade, mais um ao ir para segundo
    plano;
  - uma sessão com atividade espaçada gera mais requests que uma intensa
    e curta. Meça no Inspetor ou no receptor;
  - em um gateway que cobra por request, esse é o custo principal.
- **Rollups**: cerca de 24 × (versões ativas) × (plataformas) ×
  (fluxos + ações + 1) documentos pequenos por dia.

Fórmulas:

```text
registros/dia  = sessões/dia × registros por sessão
GB/dia         ≈ registros/dia × 1 KB / 1e6   (+ índices, ~30–50%)
GB guardados   ≈ GB/dia × RETENTION_DAYS
requests/dia   ≈ sessões/dia × requests por sessão
```

### 10.2 Amostragem

- `sampleRatio` decide por trace: todos os spans de um trace entram ou saem
  juntos, inclusive os nativos.
- Eventos da jornada **não** são amostrados: a visão geral e a jornada
  contam 100% das sessões.
- Comece em 1.0 fora de produção. Em produção, escolha pelo orçamento de
  armazenamento e de requests, e ajuste pela configuração remota.

### 10.3 Reduzir custo sem perder a jornada

- `gzip: true` (cerca de 1/5 dos bytes).
- Menos ações medidas, mais ações pontuais onde a duração não importa.
- Não rastreie HTTP de terceiros (`filter:` nos clients).
- `RETENTION_DAYS` curto: a visão geral lê os rollups, que duram mais.

---

## 11. Privacidade e segurança

- **Lista de permissão no aparelho**: só saem chaves permitidas (padrão:
  convenções OpenTelemetry que descrevem app, aparelho e operação, as
  chaves da jornada e o prefixo `app.`). Uma chave fora da lista é
  descartada.
- **Mascaramento padrão** de valores livres:
  - JWT, `Bearer`/`Basic`, e-mails e UUIDs;
  - query strings de URLs;
  - sequências de 6 ou mais dígitos (documentos, cartões, telefones, contas).

  Ids gerados pela biblioteca não passam pelo mascaramento. Acrescente
  padrões próprios com `extraPatterns`.
- **Nunca saem**:
  - corpo de request ou resposta, headers, query string;
  - texto e stack de exceção, nas exceções registradas pelo SDK;
  - `device.id`.
- **Caminhos de URL**: segmentos com dígitos ou tokens longos viram `{id}`.
- **No receptor**: repita a lista de permissão como segunda barreira, mas
  sem mascarar ids (seção 8.5).
- **Usuário**: id opaco ou HMAC; nunca documento, e-mail ou telefone.
- **Retenção**: TTL em todas as coleções (`expireAt`).
- **Acesso**: o dashboard não tem contas. Coloque o SSO e a auditoria no
  proxy.
- **Revisão**: chaves novas em `allowedAttributes` e prefixos novos passam
  por revisão de código, como qualquer mudança de privacidade.

---

## 12. Validação de ponta a ponta

### 12.1 Cenários obrigatórios

| Cenário | O que conferir |
|---|---|
| Login com senha errada e depois certa | Duas tentativas na mesma execução do fluxo; motivo da falha; usuário só depois do sucesso |
| Fluxo que passa por telas nativas e Flutter | Uma execução só, com começo e fim; passos nativos marcados "nativo" |
| Ir para segundo plano no meio do fluxo | "Saiu do app" e "Voltou ao app"; os últimos eventos chegam |
| Receptor fora do ar | O app funciona igual; o Inspetor mostra falha de envio |
| Liga/desliga remoto | Desligado: nada sai, dos dois lados |
| Sem rede | `error.type` = `URLError.notConnectedToInternet` no span do HTTP |
| Spans nativos antes do Flutter subir | Chegam na mesma sessão |
| Dados pessoais de propósito num atributo `app.*` | Mascarados no Inspetor e no banco |
| Reenvio do mesmo lote | Nada duplicado (conformidade) |

### 12.2 Verificações técnicas

- Conformidade do receptor: 29 verificações passando.
- Índices criados (`receivedAt` incluído); TTL ativo.
- Agregador em dia: `GET /api/status` (`aggregatedUpTo` com menos de 1
  minuto de atraso).
- Build Release em aparelho físico: tempo de inicialização e fluidez sem
  regressão perceptível.
- Builds com proteção em tempo de execução, se houver, rodando com a
  biblioteca.

---

## 13. Implantação gradual e operação

### 13.1 Fases

1. **Desenvolvimento**: `MODE=all` local, `sampleRatio` 1.0, Inspetor.
2. **Homologação**:
   - receptor real (opção A ou B) e dashboard em `MODE=query`;
   - conformidade passando;
   - os cenários da seção 12.
3. **Produção restrita**: liga para uma fração dos usuários pela
   configuração remota; acompanhe o volume real contra a estimativa.
4. **Produção**: aumenta a fração; fixa `sampleRatio` e retenção.

### 13.2 Guia de problemas

| Sintoma | Causa provável | Onde olhar |
|---|---|---|
| Sessão não aparece | Agregador parado ou atrasado; receptor sem `receivedAt` | `/api/status`; índice `{receivedAt:1}`; logs do dashboard |
| Eventos chegam, jornada vazia | Receptor rejeitando `/v1/logs`, nomes de evento fora da lista ou `exportLogs: false` | Allowlist do receptor (seção 8.4) |
| Fluxo partido em dois, ou passos soltos | Id de execução corrompido pelo mascaramento | Seção 8.5 |
| Usuário aparece antes do login | Receptor aplicando o usuário a todos os registros | Seção 8.3 |
| Muitos fluxos "sem conclusão" | Falta `end` em algum caminho (voltar, erro, cancelar) | Catálogo e código do fluxo |
| Duas sessões para o mesmo uso | Sessão do Dart e do nativo ao mesmo tempo | D3 (`fromHost`) |
| Spans HTTP duplicados | HTTP rastreado no Dart e no nativo | Seção 6.8 |
| Um span por envio de telemetria, crescendo | Request de telemetria sem marca | Seção 7.4 (`markAsTelemetry`) |
| Atributo próprio sumiu | Chave fora da lista de permissão | `allowedPrefixes` / `allowedAttributes` |
| Valores `[REDACTED]` onde não deviam | Padrão de mascaramento amplo demais | `extraPatterns`; valores que deveriam ser códigos fixos |

---

## 14. Armadilhas comuns

- Span longo por tela ou por fluxo.
- Nome de span ou de evento com id, texto livre ou `toString()`.
- `deviceId` vindo do payload.
- Mascarar ids no receptor.
- Lista fixa de nomes de span no receptor.
- `AppContext` escrito à mão em vez de `Journey`.
- Fluxo sem `end` nos caminhos de erro e de saída.
- Rastrear o mesmo HTTP no Dart e no nativo.
- Telemetria enviada pelo client rastreado sem `markAsTelemetry`.
- Liberar chaves novas na redação sem revisão.
- Receptor gravando `sessions` ou fazendo leitura e escrita por request: o
  dashboard deriva isso.
- Retenção longa nos registros brutos quando a necessidade é de
  tendência: os rollups bastam.
- Usar um hash simples de documento como "anonimização".

---

## 15. Referência rápida

### 15.1 Chaves e eventos

| Chave | Onde | Valor |
|---|---|---|
| `service.name`, `service.version`, `deployment.environment.name` | recurso | configuração |
| `os.type`, `os.name`, `os.version`, `device.model.identifier`, `device.manufacturer` | recurso | automático |
| `app.installation.id` | recurso | `installationId` |
| `session.id` | todo span e evento | sessão |
| `session.previous_id` | `session.start` | sessão anterior, quando continua uma expirada |
| `user.id` | todo span e evento, depois do login | id opaco |
| `event.name`, `log.record.uid` | todo evento | nome, id único (32 hex) |
| `app.screen.name`, `journey.screen.label` | spans, eventos; rótulo em `journey.screen.view` | tela |
| `journey.flow.name`, `journey.flow.instance_id` | dentro de uma execução de fluxo | fluxo e execução |
| `journey.flow.label`, `journey.flow.parent_instance_id` | `journey.flow.start` / `end` | rótulo, execução externa |
| `journey.action.name`, `journey.action.label`, `journey.action.instance_id` | `journey.action` e o span da ação | ação |
| `journey.outcome`, `journey.outcome_reason`, `journey.duration_ms` | fim de fluxo, ação | resultado, motivo, duração |
| `error.type` | spans com erro, ações que falharam | tipo do erro (nunca texto) |
| `ios.app.state` | `device.app.lifecycle` | `background`, `foreground`, `terminate` |
| `network.connection.type` | spans HTTP nativos | `wifi`, `cell`, `wired`, `unavailable`, `unknown` |
| `otel_flutter_bridge.source` | todo span e evento | `dart` ou `native` |

| `event.name` | Quando |
|---|---|
| `session.start` | uma sessão começa |
| `journey.screen.view` | entrou numa tela |
| `journey.flow.start` / `journey.flow.end` | começo e fim de uma execução de fluxo |
| `journey.action` | ação pontual ou resultado de uma ação medida |
| `device.app.lifecycle` | o app foi para segundo plano, voltou ou foi encerrado (iOS) |

### 15.2 Configuração Dart

| Opção | Padrão | Nota |
|---|---|---|
| `serviceName`, `endpoint` | obrigatórios | |
| `serviceVersion`, `deploymentEnvironment`, `installationId` | | |
| `enabled` | `true` | liga/desliga geral |
| `sampleRatio` | 1.0 | por trace |
| `exportLogs` | `true` | a jornada |
| `sendThroughNative` | `false` | envio pela rede do app |
| `gzip` | `false` | corpo comprimido |
| `headers` | `{}` | nunca token de fornecedor |
| `resourceAttributes` | `{}` | passa pela redação |
| `redaction` | lista padrão + `app.` | `allowedAttributes`, `allowedPrefixes`, `extraPatterns` |
| `session` | 30 min / 4 h | `fromHost` |
| `limits` | 32 lotes, 512 por envio, 64 por lote nativo, 256 caracteres | |
| `exportTimeout` | 10 s | |

### 15.3 API Swift

`OtelFlutterBridge.shared`:

- `start(resourceAttributes:extraProcessors:sampler:registerGlobal:)`;
- `setSession(id:previousId:)`, `exportHandler`, `flush()`;
- `traced(channel:_:)`, `span(_:)`, `bind(_:)`, `task(_:)`;
- `makeSpanProcessor()`, `makeAppContextProcessor()`.

Os demais tipos:

- `Journey`: `screen`, `startFlow`, `flowRun`, `currentFlow`, `event`,
  `begin` (que devolve `JourneyActionRun.end`), `track` e `setUser`.
- `HTTPClientSpan.start(_:)`, que devolve `HTTPClientCall.finish(response:error:then:)`;
  `HTTPClientSpan.propagateTo`.
- `TracedURLSession`, `TraceContext.with` e `TraceContext.current`.
- `FlutterMethodChannel.invokeTraced`.
- `TelemetryExport.urlRequest(endpoint:)` e `URLRequest.markAsTelemetry()`.

### 15.4 Canal entre nativo e Dart

| Método | Direção | Conteúdo |
|---|---|---|
| `ready` | Dart → nativo | versão, liga/desliga, tamanho de lote, estado da jornada; resposta: estado mesclado e recurso do aparelho |
| `exportSpans` / `exportEvents` | nativo → Dart | lotes de spans e eventos nativos |
| `journey` | os dois | uma mudança: tela, usuário, começo ou fim de fluxo, sessão do app nativo |
| `flush` | nativo → Dart | enviar tudo (segundo plano) |
| `export` | Dart → nativo | um request OTLP para a rede do app |
| `setEnabled` | Dart → nativo | liga/desliga |

### 15.5 Links

- Biblioteca:
  - [README](https://github.com/luizroddev/otel_flutter_bridge);
  - especificações: [journey](specs/journey.md),
    [native-bridge](specs/native-bridge.md), [session](specs/session.md),
    [redaction](specs/redaction.md), [configuration](specs/configuration.md),
    [failure-and-limits](specs/failure-and-limits.md);
  - [pontos de extensão](extension-points.md);
  - guias de [integração](integration-guide.pt-BR.md) e de
    [instrumentação](app-instrumentation-guide.pt-BR.md).
- Dashboard:
  - [README](https://github.com/luizroddev/otel-journey-dashboard);
  - [backend-integration](https://github.com/luizroddev/otel-journey-dashboard/blob/main/docs/backend-integration.md),
    [storage-schema](https://github.com/luizroddev/otel-journey-dashboard/blob/main/docs/storage-schema.md),
    [query-api](https://github.com/luizroddev/otel-journey-dashboard/blob/main/docs/query-api.md).
- [Prompt de adoção](adoption-prompt.pt-BR.md).
