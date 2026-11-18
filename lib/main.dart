import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartnative/dartnative.dart';
import 'package:nitro_http/nitro_http.dart';

import 'dartnative_plugin_registrant.dart';

void main() {
  // Platform bindings + (once you add plugins) their FFI symbols. Keep this
  // as the FIRST line of main() — see lib/dartnative_plugin_registrant.dart.
  DartNativePluginRegistrant.registerAll();
  // App-wide system chrome default for the white template: dark status-bar
  // icons over the light background, transparent strips. Screens can override
  // in initState; the navigator restores this default on pop.
  SystemChrome.defaultStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: Brightness.light,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
  );
  runApp(const HomeScreen());
}

/// nitro_http vs dart:io HttpClient, measured against an HTTP server running
/// on this device's loopback in its own isolate, so the network costs nothing
/// and the numbers are the clients' own overhead. Tap Refresh to rerun.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Optional: the Mac running tool/bench_server.py, to collect the report from
/// release builds (which don't forward print). --dart-define=BENCH_HOST=x.x.x.x
const _reportHost = String.fromEnvironment('BENCH_HOST');

const _rounds = 5;
const _width = 16; // requests in flight for the concurrent tests

/// (path, sequential count, concurrent count)
const _sizes = [('1k', 400, 800), ('64k', 200, 400), ('1m', 40, 80)];

/// Loopback server isolate; replies with the port it bound.
Future<void> _serve(SendPort reply) async {
  final bodies = {
    '/1k': Uint8List(1024),
    '/64k': Uint8List(64 * 1024),
    '/1m': Uint8List(1024 * 1024),
  };
  final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
  reply.send(server.port);
  await for (final req in server) {
    final body = bodies[req.uri.path];
    final res = req.response;
    if (body == null) {
      res.statusCode = 404;
    } else {
      res.headers.contentType = io.ContentType.binary;
      res.contentLength = body.length;
      res.add(body);
    }
    res.close();
  }
}

typedef _Fetch = Future<int> Function(String url);

double _median(List<double> v) => (v.toList()..sort())[v.length ~/ 2];

class _HomeScreenState extends State<HomeScreen> {
  final _nitro = NitroHttpClient();
  final _io = io.HttpClient();
  String? _base;
  bool _running = false;
  String _report = 'Starting…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<int> _nitroGet(String url) async {
    final res = await _nitro.get(url);
    if (res.statusCode != 200) throw StateError('nitro ${res.statusCode}');
    return res.bodyBytes.length;
  }

  Future<int> _ioGet(String url) async {
    final res = await (await _io.getUrl(Uri.parse(url))).close();
    if (res.statusCode != 200) throw StateError('dart:io ${res.statusCode}');
    // One contiguous Uint8List, like nitro_http's bodyBytes (and package:http).
    final b = BytesBuilder(copy: false);
    await for (final chunk in res) {
      b.add(chunk);
    }
    return b.takeBytes().length;
  }

  /// Median per-request latency (ms) over [n] sequential requests.
  Future<double> _seq(_Fetch f, String url, int n) async {
    final ms = <double>[];
    for (var i = 0; i < n; i++) {
      final sw = Stopwatch()..start();
      await f(url);
      ms.add(sw.elapsedMicroseconds / 1000);
    }
    return _median(ms);
  }

  /// Throughput (req/s) for [n] requests with [_width] in flight.
  Future<double> _concurrent(_Fetch f, String url, int n) async {
    var next = 0;
    final sw = Stopwatch()..start();
    Future<void> worker() async {
      while (next < n) {
        next++;
        await f(url);
      }
    }
    await Future.wait(List.generate(_width, (_) => worker()));
    return n / (sw.elapsedMicroseconds / 1e6);
  }

  /// Splits nitro_http's time per request into libcurl's own transfer time
  /// (`timings.total`) and everything outside it: request handoff, response
  /// record encode, native copies, post to Dart, and the Dart-side decode.
  Future<List<String>> _profile() async {
    final out = <String>['', 'profile: nitro per request, median ms'];
    out.add('${'size'.padRight(6)}${'wall'.padLeft(8)}${'libcurl'.padLeft(9)}'
        '${'outside'.padLeft(9)}${'dart:io'.padLeft(9)}${'memcpy'.padLeft(8)}');
    for (final (path, n) in [('1k', 300), ('64k', 200), ('1m', 60)]) {
      final url = '$_base/$path';
      final wall = <double>[], curl = <double>[], outside = <double>[];
      for (var i = 0; i < n; i++) {
        final sw = Stopwatch()..start();
        final res = await _nitro.get(url);
        res.bodyBytes;
        final w = sw.elapsedMicroseconds / 1000;
        final c = res.timings.total.inMicroseconds / 1000;
        wall.add(w);
        curl.add(c);
        outside.add(w - c);
      }
      final io = await _seq(_ioGet, url, n);
      // One Dart-heap copy of this size: what each extra pass over the body costs.
      final src = Uint8List((await _nitro.get(url)).bodyBytes.length);
      final copy = <double>[];
      for (var i = 0; i < 50; i++) {
        final sw = Stopwatch()..start();
        src.sublist(0);
        copy.add(sw.elapsedMicroseconds / 1000);
      }
      String f(double v) => v.toStringAsFixed(3);
      out.add('${path.padRight(6)}${f(_median(wall)).padLeft(8)}'
          '${f(_median(curl)).padLeft(9)}${f(_median(outside)).padLeft(9)}'
          '${f(io).padLeft(9)}${f(_median(copy)).padLeft(8)}');
    }
    return out;
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _report = 'Running $_rounds rounds…';
    });
    final lines = <String>[];
    try {
      if (_base == null) {
        final port = ReceivePort();
        await Isolate.spawn(_serve, port.sendPort);
        _base = 'http://127.0.0.1:${await port.first}';
      }
      final clients = <String, _Fetch>{'nitro': _nitroGet, 'dartio': _ioGet};
      // Warm up connection pools and code paths for every size.
      for (final f in clients.values) {
        for (final (path, _, _) in _sizes) {
          await _seq(f, '$_base/$path', 10);
        }
      }
      // results[test][client] = one value per round
      final results = <String, Map<String, List<double>>>{};
      void add(String test, String client, double v) =>
          ((results[test] ??= {})[client] ??= []).add(v);
      for (var r = 0; r < _rounds; r++) {
        // Alternate who goes first so neither always gets the warmer device.
        final order = r.isEven
            ? clients.entries.toList()
            : clients.entries.toList().reversed.toList();
        for (final (path, seqN, concN) in _sizes) {
          for (final c in order) {
            add('$path seq p50 ms', c.key,
                await _seq(c.value, '$_base/$path', seqN));
            add('$path x$_width req/s', c.key,
                await _concurrent(c.value, '$_base/$path', concN));
          }
        }
      }
      lines.add('median of $_rounds rounds · loopback · '
          '${const bool.fromEnvironment('dart.vm.product') ? 'release' : 'debug'}');
      lines.add('${'test'.padRight(20)}${'nitro'.padLeft(9)}'
          '${'dart:io'.padLeft(9)}  nitro/io');
      for (final MapEntry(key: test, value: byClient) in results.entries) {
        final n = _median(byClient['nitro']!);
        final d = _median(byClient['dartio']!);
        // Ratio > 1 means nitro is better (lower latency / higher req/s).
        final ratio = test.contains('ms') ? d / n : n / d;
        lines.add('${test.padRight(20)}${n.toStringAsFixed(2).padLeft(9)}'
            '${d.toStringAsFixed(2).padLeft(9)}  ${ratio.toStringAsFixed(2)}x');
      }
      lines.addAll(await _profile());
    } catch (e) {
      lines.add('Error: $e');
    }
    final report = '[bench]\n${lines.join('\n')}';
    print(report);
    if (_reportHost.isNotEmpty) {
      try {
        final req =
            await _io.postUrl(Uri.parse('http://$_reportHost:8765/report'));
        final bytes = utf8.encode(report);
        req.contentLength = bytes.length;
        req.add(bytes);
        await (await req.close()).drain<void>();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _report = lines.join('\n');
    });
  }

  @override
  void dispose() {
    _nitro.dispose();
    _io.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      brightness: Brightness.light,
      appBar: AppBar(title: const Text('nitro_http benchmark')),
      backgroundColor: const Color(0xFFFFFFFF),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ElevatedButton(
              onPressed: _running ? null : _run,
              child: Text(_running ? 'Running…' : 'Refresh'),
            ),
            const SizedBox(height: 16),
            Text(_report,
                style: const TextStyle(fontSize: 11, fontFamily: 'Menlo')),
          ],
        ),
      ),
    );
  }
}
