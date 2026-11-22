import 'dart:convert';
import 'dart:io' as io;

class BenchmarkReporter {
  const BenchmarkReporter({required this.reportHost});

  final String reportHost;

  Future<void> sendReport(String report) async {
    if (reportHost.isEmpty) return;
    try {
      final client = io.HttpClient();
      try {
        final req = await client.postUrl(Uri.parse('http://$reportHost:8765/report'));
        final bytes = utf8.encode(report);
        req.contentLength = bytes.length;
        req.add(bytes);
        final res = await req.close();
        await res.drain<void>();
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      // Best-effort delivery.
    }
  }
}
