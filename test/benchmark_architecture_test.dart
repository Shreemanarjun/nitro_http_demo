import 'package:nitro_http_demo/main.dart';
import 'package:test/test.dart';

void main() {
  group('BenchmarkConfig tests', () {
    test('default configuration and payload byte resolution', () {
      const config = BenchmarkConfig();
      expect(config.rounds, 5);
      expect(config.concurrencyWidth, 4);
      expect(config.payloads.length, 3);
      expect(config.bytesFor('1k'), 1024);
      expect(config.bytesFor('64k'), 64 * 1024);
      expect(config.bytesFor('1m'), 1024 * 1024);
      expect(() => config.bytesFor('invalid_path'), throwsArgumentError);
    });

    test('custom configuration values and permutations', () {
      const custom = BenchmarkConfig(
        rounds: 10,
        concurrencyWidth: 8,
        reportHost: '192.168.1.100',
        payloads: [
          BenchmarkPayload(
            path: 'custom_chunk',
            sequentialCount: 50,
            concurrentCount: 100,
            bytes: 2048,
          ),
        ],
      );

      expect(custom.rounds, 10);
      expect(custom.concurrencyWidth, 8);
      expect(custom.reportHost, '192.168.1.100');
      expect(custom.bytesFor('custom_chunk'), 2048);
      expect(() => custom.bytesFor('1k'), throwsArgumentError);
    });
  });

  group('Signal State Management & BenchmarkController tests', () {
    test('signal reactivity and computed derived signals in controller', () {
      final controller = BenchmarkController();

      // Initial state
      expect(controller.isRunning.value, isFalse);
      expect(controller.report.value, 'Starting…');
      expect(controller.canRun.value, isTrue);
      expect(controller.buttonLabel.value, 'Refresh');

      // State transition: running
      controller.isRunning.value = true;
      expect(controller.isRunning.value, isTrue);
      expect(controller.canRun.value, isFalse);
      expect(controller.buttonLabel.value, 'Running…');

      // State transition: update report
      controller.report.value = 'Running 5 rounds…';
      expect(controller.report.value, 'Running 5 rounds…');

      // State transition: finished
      controller.isRunning.value = false;
      controller.report.value = 'Completed successfully';
      expect(controller.isRunning.value, isFalse);
      expect(controller.canRun.value, isTrue);
      expect(controller.buttonLabel.value, 'Refresh');
      expect(controller.report.value, 'Completed successfully');

      controller.dispose();
    });

    test('signals compute median correctly', () {
      expect(BenchmarkRunner.median([1.0, 5.0, 3.0]), 3.0);
      expect(BenchmarkRunner.median([10.0, 20.0, 30.0, 40.0]), 30.0);
      expect(BenchmarkRunner.median([5.0]), 5.0);
    });

    test('reporter safely handles empty host without making network calls', () async {
      const reporter = BenchmarkReporter(reportHost: '');
      expect(reporter.reportHost, isEmpty);
      await reporter.sendReport('Dummy report');
    });

    test('BenchmarkServerManager state before starting', () {
      final serverManager = BenchmarkServerManager();
      expect(serverManager.httpBaseUrl, isNull);
      expect(serverManager.httpsBaseUrl, isNull);
    });
  });
}
