import 'package:flutter/material.dart';
import 'package:otel_flutter_bridge/inspector.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

import 'poc_config.dart';
import 'scenarios_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize once, early. Everything app-specific lives in PocConfig.
  await OtelFlutterBridge.initialize(
    PocConfig.bridgeConfig(),
    // Extension point: in-memory only when no endpoint was given.
    transport: PocConfig.endpoint.isEmpty ? InMemoryTransport() : null,
    // Extension point: attributes every span should carry (must be allowed
    // by the redaction config: here, under `app.`).
    enrichers: [PocConfig.appEnricher],
    // Extension point: route internal problems to the app's logger.
    onDiagnostic: (d) => debugPrint('[otel] $d'),
  );

  // 2. Optional: keep the last exports for the on-screen inspector.
  TelemetryInspectorController.instance.attach();

  runApp(const PocApp());
}

class PocApp extends StatelessWidget {
  const PocApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'otel_flutter_bridge POC',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(_tab == 0 ? 'Cenários da POC' : 'Inspetor de telemetria'),
        ),
        body: IndexedStack(
          index: _tab,
          children: const [ScenariosPage(), TelemetryInspectorView()],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.play_circle), label: 'Cenários'),
            NavigationDestination(
                icon: Icon(Icons.manage_search), label: 'Inspetor'),
          ],
        ),
      );
}
