import 'package:dartnative/dartnative.dart';

import '../models/benchmark_config.dart';
import '../services/benchmark_client_pool.dart';
import '../services/benchmark_reporter.dart';
import '../services/benchmark_runner.dart';
import '../services/benchmark_server.dart';

class BenchmarkController {
  BenchmarkController({
    BenchmarkConfig? config,
    BenchmarkServerManager? serverManager,
    BenchmarkClientPool? clientPool,
    BenchmarkRunner? runner,
    BenchmarkReporter? reporter,
  })  : config = config ?? const BenchmarkConfig(),
        serverManager = serverManager ?? BenchmarkServerManager(),
        _injectedClientPool = clientPool,
        _injectedRunner = runner,
        reporter = reporter ??
            BenchmarkReporter(
              reportHost: (config ?? const BenchmarkConfig()).reportHost,
            );

  final BenchmarkConfig config;
  final BenchmarkServerManager serverManager;
  final BenchmarkClientPool? _injectedClientPool;
  final BenchmarkRunner? _injectedRunner;
  final BenchmarkReporter reporter;

  BenchmarkClientPool? _clientPool;
  BenchmarkClientPool get clientPool =>
      _clientPool ??= (_injectedClientPool ?? BenchmarkClientPool(config: config));

  BenchmarkRunner? _runner;
  BenchmarkRunner get runner =>
      _runner ??= (_injectedRunner ??
          BenchmarkRunner(
            config: config,
            serverManager: serverManager,
            clientPool: clientPool,
          ));

  /// Reactive signals for state management
  final Signal<bool> isRunning = signal<bool>(false);
  final Signal<String> report = signal<String>('Starting…');

  /// Derived computed signals
  late final Computed<bool> canRun = computed<bool>(() => !isRunning.value);
  late final Computed<String> buttonLabel = computed<String>(
    () => isRunning.value ? 'Running…' : 'Refresh',
  );

  Future<void> runBenchmark() async {
    if (isRunning.value) return;

    isRunning.value = true;
    report.value = 'Running ${config.rounds} rounds…';

    final lines = <String>[];
    try {
      await serverManager.ensureServersRunning();
      final mode = const bool.fromEnvironment('dart.vm.product') ? 'release' : 'debug';
      lines.add('median of ${config.rounds} rounds · loopback · $mode');

      // HTTP Suite
      final httpLines = await runner.runSuite(
        title: 'HTTP',
        baseUrl: serverManager.httpBaseUrl!,
        statsClient: clientPool.statsClient,
        clients: {
          'nitro': clientPool.nitroGet,
          'dn_http': clientPool.dnGet,
          'dartio': clientPool.ioGet,
        },
      );
      lines.addAll(httpLines);

      // HTTPS Suite
      final httpsLines = await runner.runSuite(
        title: 'HTTPS',
        baseUrl: serverManager.httpsBaseUrl!,
        statsClient: clientPool.statsTlsClient,
        clients: {
          'nitro': clientPool.nitroTlsGet,
          'dartio': clientPool.ioTlsGet,
        },
      );
      lines.addAll(httpsLines);

      // Profile
      final profileLines = await runner.runProfile();
      lines.addAll(profileLines);
    } catch (e, st) {
      lines.add('Error: $e\n$st');
    }

    final fullReport = '[bench]\n${lines.join('\n')}';
    print(fullReport);

    await reporter.sendReport(fullReport);

    report.value = lines.join('\n');
    isRunning.value = false;
  }

  void dispose() {
    _clientPool?.dispose();
  }
}
