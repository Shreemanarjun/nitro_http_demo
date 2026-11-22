class BenchmarkPayload {
  const BenchmarkPayload({
    required this.path,
    required this.sequentialCount,
    required this.concurrentCount,
    required this.bytes,
  });

  final String path;
  final int sequentialCount;
  final int concurrentCount;
  final int bytes;
}

class BenchmarkConfig {
  const BenchmarkConfig({
    this.rounds = 5,
    this.concurrencyWidth = 4,
    this.reportHost = const String.fromEnvironment('BENCH_HOST'),
    this.payloads = const [
      BenchmarkPayload(
        path: '1k',
        sequentialCount: 400,
        concurrentCount: 800,
        bytes: 1024,
      ),
      BenchmarkPayload(
        path: '64k',
        sequentialCount: 200,
        concurrentCount: 400,
        bytes: 64 * 1024,
      ),
      BenchmarkPayload(
        path: '1m',
        sequentialCount: 40,
        concurrentCount: 80,
        bytes: 1024 * 1024,
      ),
    ],
  });

  final int rounds;
  final int concurrencyWidth;
  final String reportHost;
  final List<BenchmarkPayload> payloads;

  int bytesFor(String path) {
    for (final p in payloads) {
      if (p.path == path) return p.bytes;
    }
    throw ArgumentError('Unknown payload path: $path');
  }
}
