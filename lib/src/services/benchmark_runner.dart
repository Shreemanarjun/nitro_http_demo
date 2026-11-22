import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import '../models/benchmark_config.dart';
import 'benchmark_client_pool.dart';
import 'benchmark_server.dart';

typedef FetchFunction = Future<int> Function(String url);

class BenchmarkRunner {
  BenchmarkRunner({
    required this.config,
    required this.serverManager,
    required this.clientPool,
  });

  final BenchmarkConfig config;
  final BenchmarkServerManager serverManager;
  final BenchmarkClientPool clientPool;

  static double median(List<double> v) => (v.toList()..sort())[v.length ~/ 2];

  Future<double> runSequential(FetchFunction fetch, String url, int count) async {
    final path = url.split('/').last;
    final expectedBytes = config.bytesFor(path);
    final latencies = <double>[];
    for (var i = 0; i < count; i++) {
      final sw = Stopwatch()..start();
      final got = await fetch(url);
      latencies.add(sw.elapsedMicroseconds / 1000);
      if (got != expectedBytes) {
        throw StateError('$url: got $got bytes, want $expectedBytes');
      }
    }
    return median(latencies);
  }

  Future<double> runConcurrent(FetchFunction fetch, String url, int count) async {
    final path = url.split('/').last;
    final expectedBytes = config.bytesFor(path);
    var next = 0;
    final sw = Stopwatch()..start();
    Future<void> worker() async {
      while (next < count) {
        next++;
        final got = await fetch(url);
        if (got != expectedBytes) {
          throw StateError('$url: got $got bytes, want $expectedBytes');
        }
      }
    }
    await Future.wait(List.generate(config.concurrencyWidth, (_) => worker()));
    return count / (sw.elapsedMicroseconds / 1e6);
  }

  Future<int> queryConnectionCount(String base, io.HttpClient stats) async {
    final req = await stats.getUrl(Uri.parse('$base/stats'));
    final res = await req.close();
    return int.parse(await res.transform(utf8.decoder).join());
  }

  Future<List<String>> runSuite({
    required String title,
    required String baseUrl,
    required io.HttpClient statsClient,
    required Map<String, FetchFunction> clients,
  }) async {
    final lines = <String>[];
    const clientDisplayNames = {
      'nitro': 'nitro',
      'dn_http': 'dn_http',
      'dartio': 'dart:io',
    };

    // Warm up connection pools and paths
    for (final c in clients.entries) {
      for (final payload in config.payloads) {
        await runSequential(c.value, '$baseUrl/${payload.path}', 10);
      }
    }

    final results = <String, Map<String, List<double>>>{};
    void addResult(String test, String client, double v) {
      ((results[test] ??= {})[client] ??= []).add(v);
    }

    for (var r = 0; r < config.rounds; r++) {
      final all = clients.entries.toList();
      final k = r % all.length;
      final order = [...all.sublist(k), ...all.sublist(0, k)];
      for (final payload in config.payloads) {
        final path = payload.path;
        final url = '$baseUrl/$path';
        for (final c in order) {
          await queryConnectionCount(baseUrl, statsClient);
          addResult('$path seq p50 ms', c.key,
              await runSequential(c.value, url, payload.sequentialCount));
          addResult('$path seq conns', c.key,
              (await queryConnectionCount(baseUrl, statsClient)).toDouble());
          addResult('$path x${config.concurrencyWidth} req/s', c.key,
              await runConcurrent(c.value, url, payload.concurrentCount));
          addResult('$path x${config.concurrencyWidth} conns', c.key,
              (await queryConnectionCount(baseUrl, statsClient)).toDouble());
        }
      }
    }

    lines.add('');
    lines.add('== $title');
    final keys = clients.keys.toList();
    lines.add('${'test'.padRight(15)}'
        '${keys.map((k) => clientDisplayNames[k]!.padLeft(10)).join()}');

    for (final MapEntry(key: test, value: byClient) in results.entries) {
      if (test.endsWith('conns')) continue;
      final d = median(byClient['dartio']!);
      String vs(double x) =>
          '${(test.contains('ms') ? d / x : x / d).toStringAsFixed(2)}x';
      final meds = {for (final k in keys) k: median(byClient[k]!)};
      lines.add('${test.padRight(15)}'
          '${keys.map((k) => meds[k]!.toStringAsFixed(test.contains('ms') ? 3 : 0).padLeft(10)).join()}');
      lines.add('${''.padRight(15)}'
          '${keys.map((k) => vs(meds[k]!).padLeft(10)).join()}');
    }

    lines.add('');
    lines.add('connections used (max of ${config.rounds} rounds)');
    for (final MapEntry(key: test, value: byClient) in results.entries) {
      if (!test.endsWith('conns')) continue;
      String c(String k) =>
          byClient[k]!.reduce((a, b) => a > b ? a : b).toStringAsFixed(0);
      lines.add('${test.padRight(15)}'
          '${keys.map((k) => c(k).padLeft(10)).join()}');
    }

    return lines;
  }

  Future<List<String>> runProfile() async {
    final base = serverManager.httpBaseUrl!;
    final out = <String>['', 'profile: nitro per request, median ms'];
    out.add('${'size'.padRight(6)}${'wall'.padLeft(8)}${'libcurl'.padLeft(9)}'
        '${'outside'.padLeft(9)}${'dart:io'.padLeft(9)}${'dn_http'.padLeft(9)}'
        '${'memcpy'.padLeft(8)}');

    const profileCounts = {'1k': 300, '64k': 200, '1m': 60};
    for (final payload in config.payloads) {
      final path = payload.path;
      final n = profileCounts[path] ?? 100;
      final url = '$base/$path';
      final wall = <double>[], curl = <double>[], outside = <double>[];

      for (var i = 0; i < n; i++) {
        final sw = Stopwatch()..start();
        final res = await clientPool.nitro.get(url);
        res.bodyBytes;
        final w = sw.elapsedMicroseconds / 1000;
        final c = res.timings.total.inMicroseconds / 1000;
        wall.add(w);
        curl.add(c);
        outside.add(w - c);
      }

      final ioMedian = await runSequential(clientPool.ioGet, url, n);
      final dnMedian = await runSequential(clientPool.dnGet, url, n);

      final src = Uint8List((await clientPool.nitro.get(url)).bodyBytes.length);
      final copy = <double>[];
      for (var i = 0; i < 50; i++) {
        final sw = Stopwatch()..start();
        src.sublist(0);
        copy.add(sw.elapsedMicroseconds / 1000);
      }

      String f(double v) => v.toStringAsFixed(3);
      out.add('${path.padRight(6)}${f(median(wall)).padLeft(8)}'
          '${f(median(curl)).padLeft(9)}${f(median(outside)).padLeft(9)}'
          '${f(ioMedian).padLeft(9)}${f(dnMedian).padLeft(9)}${f(median(copy)).padLeft(8)}');
    }

    return out;
  }
}
