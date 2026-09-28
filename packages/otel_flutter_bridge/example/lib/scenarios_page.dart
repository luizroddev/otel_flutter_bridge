import 'package:flutter/material.dart';
import 'package:otel_flutter_bridge/otel_flutter_bridge.dart';

import 'poc_config.dart';
import 'scenarios.dart';

class ScenariosPage extends StatefulWidget {
  const ScenariosPage({super.key});

  @override
  State<ScenariosPage> createState() => _ScenariosPageState();
}

class _ScenariosPageState extends State<ScenariosPage> {
  final _results = <String, String>{};
  bool _enabled = true;

  Future<void> _run(Scenario s) async {
    setState(() => _results[s.title] = '…');
    final result = await s.run();
    await OtelFlutterBridge.flush();
    if (mounted) setState(() => _results[s.title] = result);
  }

  @override
  Widget build(BuildContext context) {
    final mono = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(fontFamily: 'monospace');
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Card(
          margin: const EdgeInsets.all(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'Destino OTLP: ${PocConfig.endpoint.isEmpty ? '(só memória)' : PocConfig.endpoint}',
                    style: mono),
                Text('Backend demo: ${PocConfig.demoBackend}', style: mono),
                Text('Jaeger UI: http://localhost:16686', style: mono),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Telemetria ligada'),
                  subtitle: const Text('Liga-desliga em tempo de execução'),
                  value: _enabled,
                  onChanged: (v) async {
                    await setTelemetryEnabled(v);
                    setState(() => _enabled = v);
                  },
                ),
              ],
            ),
          ),
        ),
        for (final s in scenarios)
          ListTile(
            title: Text(s.title),
            subtitle: Text(
              _results[s.title] == null
                  ? s.description
                  : '${s.description}\n→ ${_results[s.title]}',
            ),
            isThreeLine: _results[s.title] != null,
            trailing: const Icon(Icons.play_arrow),
            onTap: () => _run(s),
          ),
      ],
    );
  }
}
