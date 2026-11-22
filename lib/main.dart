import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartnative/dartnative.dart';
import 'package:dartnative_http/http.dart';
import 'package:nitro_http/nitro_http.dart';

import 'dartnative_plugin_registrant.dart';
import 'tls_fixture.dart';

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

/// Requests in flight in the parallel tests, and the connection limit set on
/// every client that allows one. With only this many in flight no client can
/// use more connections than this, whatever its own limit, so all three work
/// under the same conditions. The server counts the connections each actually
/// opens, and the report shows them.
const _width = 4;

/// (path, sequential count, concurrent count)
const _sizes = [('1k', 400, 800), ('64k', 200, 400), ('1m', 40, 80)];

const _bytes = {'1k': 1024, '64k': 64 * 1024, '1m': 1024 * 1024};

/// Loopback server isolate; replies with the port it bound.
/// [args]: reply port, and whether to serve HTTPS with the test certificate.
Future<void> _serve((SendPort, bool) args) async {
  final (reply, secure) = args;
  final bodies = {
    '/1k': Uint8List(1024),
    '/64k': Uint8List(64 * 1024),
    '/1m': Uint8List(1024 * 1024),
  };
  final server = secure
      ? await io.HttpServer.bindSecure(
          io.InternetAddress.loopbackIPv4,
          0,
          io.SecurityContext()
            ..useCertificateChainBytes(utf8.encode(benchServerCertPem))
            ..usePrivateKeyBytes(utf8.encode(benchServerKeyPem)),
        )
      : await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
  reply.send(server.port);
  // Client ports that served a request since the last /stats call: the number
  // of TCP connections the client under test actually used.
  final ports = <int>{};
  await for (final req in server) {
    if (req.uri.path == '/stats') {
      req.response.write(ports.length);
      ports.clear();
      req.response.close();
      continue;
    }
    ports.add(req.connectionInfo!.remotePort);
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

/// Fetches [url] and returns the body length, so every response is checked
/// in full for every client.
typedef _Fetch = Future<int> Function(String url);

double _median(List<double> v) => (v.toList()..sort())[v.length ~/ 2];

class _HomeScreenState extends State<HomeScreen> {
  // Same conditions for all three: no HTTP cache, no cookies, at most
  // [_width] connections per host where the client lets you set it.
  // nitro_http: caching is off by default; cookies and the 6-per-host
  // default are overridden.
  final _nitro = NitroHttpClient(
    settings: const ClientSettings(
      cookieSettings: CookieSettings.none(),
      poolSettings: PoolSettings(maxConnectionsPerHost: _width),
    ),
  );
  // dart:io: no cache or cookie jar; per-host limit is unlimited by default.
  final _io = io.HttpClient()..maxConnectionsPerHost = _width;
  // dartnative_http: its per-host limit is set natively and not exposed, so
  // the in-flight cap above is what bounds it.
  final _dn = NativeHttpClient(cache: false, cookies: false);
  // Reads the server's connection count; kept apart so it never counts itself.
  final _stats = io.HttpClient();
  late final _statsTls = io.HttpClient(
    context: io.SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(benchCaPem)),
  )..badCertificateCallback = (cert, host, port) =>
      host == '127.0.0.1' && cert.pem.trim() == benchServerCertPem.trim();
  String? _base;
  String? _tlsBase;

  // HTTPS clients for the loopback TLS server. Both trust the same ~199 KB
  // bundle (system roots + the test CA), as an app's default trust would be.
  final _nitroTls = NitroHttpClient(
    settings: const ClientSettings(
      cookieSettings: CookieSettings.none(),
      poolSettings: PoolSettings(maxConnectionsPerHost: _width),
      tlsSettings: TlsSettings(
        rootCaSource: RootCaSource.custom(benchTrustBundle),
      ),
    ),
  );
  // Same, trusting only the 1 KB test CA: the difference from _nitroTls is
  // what the bundle's size costs per request.
  final _nitroTlsSmall = NitroHttpClient(
    settings: const ClientSettings(
      cookieSettings: CookieSettings.none(),
      poolSettings: PoolSettings(maxConnectionsPerHost: _width),
      tlsSettings: TlsSettings(rootCaSource: RootCaSource.custom(benchCaPem)),
    ),
  );
  final _ioTls = io.HttpClient(
    context: io.SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(benchTrustBundle)),
  )
    ..maxConnectionsPerHost = _width
    // dart:io rejects the test certificate's IP-address name; accept exactly
    // that certificate and nothing else. Runs once per connection, at setup,
    // so the timed requests on the reused connection don't pay for it.
    ..badCertificateCallback = (cert, host, port) =>
        host == '127.0.0.1' && cert.pem.trim() == benchServerCertPem.trim();
  bool _running = false;
  String _report = 'Starting…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<int> _nitroGet(String url) => _nitroGetWith(_nitro, url);
  Future<int> _nitroTlsGet(String url) => _nitroGetWith(_nitroTls, url);

  Future<int> _nitroGetWith(NitroHttpClient client, String url) async {
    final res = await client.get(url);
    if (res.statusCode != 200) throw StateError('nitro ${res.statusCode}');
    return res.bodyBytes.length;
  }

  Future<int> _dnGet(String url) async {
    final res = await _dn.get(Uri.parse(url));
    if (res.statusCode != 200) throw StateError('dn_http ${res.statusCode}');
    return res.bodyBytes.length;
  }

  Future<int> _ioGet(String url) => _ioGetWith(_io, url);
  Future<int> _ioTlsGet(String url) => _ioGetWith(_ioTls, url);

  Future<int> _ioGetWith(io.HttpClient client, String url) async {
    final res = await (await client.getUrl(Uri.parse(url))).close();
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
    final want = _bytes[url.split('/').last]!;
    final ms = <double>[];
    for (var i = 0; i < n; i++) {
      final sw = Stopwatch()..start();
      final got = await f(url);
      ms.add(sw.elapsedMicroseconds / 1000);
      if (got != want) throw StateError('$url: got $got bytes, want $want');
    }
    return _median(ms);
  }

  /// Throughput (req/s) for [n] requests with [_width] in flight.
  Future<double> _concurrent(_Fetch f, String url, int n) async {
    final want = _bytes[url.split('/').last]!;
    var next = 0;
    final sw = Stopwatch()..start();
    Future<void> worker() async {
      while (next < n) {
        next++;
        final got = await f(url);
        if (got != want) throw StateError('$url: got $got bytes, want $want');
      }
    }
    await Future.wait(List.generate(_width, (_) => worker()));
    return n / (sw.elapsedMicroseconds / 1e6);
  }

  Future<List<String>> _profile() async {
    final out = <String>['', 'profile: nitro per request, median ms'];
    out.add('${'size'.padRight(6)}${'wall'.padLeft(8)}${'libcurl'.padLeft(9)}'
        '${'outside'.padLeft(9)}${'dart:io'.padLeft(9)}${'dn_http'.padLeft(9)}'
        '${'memcpy'.padLeft(8)}');
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
      final dn = await _seq(_dnGet, url, n);
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
          '${f(io).padLeft(9)}${f(dn).padLeft(9)}${f(_median(copy)).padLeft(8)}');
    }
    return out;
  }

  /// TCP connections the server saw since the last call (and resets it).
  Future<int> _conns(String base, io.HttpClient stats) async {
    final res = await (await stats.getUrl(Uri.parse('$base/stats'))).close();
    return int.parse(await res.transform(utf8.decoder).join());
  }

  /// One fair comparison of [clients] against the server at [base]: same
  /// warm-up, [_rounds] rotating rounds, byte-checked responses, connection
  /// counts from [stats]. Appends its tables to [lines].
  Future<void> _suite(List<String> lines, String title, String base,
      io.HttpClient stats, Map<String, _Fetch> clients) async {
    const names = {'nitro': 'nitro', 'dn_http': 'dn_http', 'dartio': 'dart:io'};
    // Warm up connection pools and code paths for every size.
    for (final c in clients.entries) {
      for (final (path, _, _) in _sizes) {
        await _seq(c.value, '$base/$path', 10);
      }
    }
    // results[test][client] = one value per round
    final results = <String, Map<String, List<double>>>{};
    void add(String test, String client, double v) =>
        ((results[test] ??= {})[client] ??= []).add(v);
    for (var r = 0; r < _rounds; r++) {
      // Rotate who goes first so no client always gets the warmer device.
      final all = clients.entries.toList();
      final k = r % all.length;
      final order = [...all.sublist(k), ...all.sublist(0, k)];
      for (final (path, seqN, concN) in _sizes) {
        for (final c in order) {
          await _conns(base, stats); // reset
          add('$path seq p50 ms', c.key,
              await _seq(c.value, '$base/$path', seqN));
          add('$path seq conns', c.key, (await _conns(base, stats)).toDouble());
          add('$path x$_width req/s', c.key,
              await _concurrent(c.value, '$base/$path', concN));
          add('$path x$_width conns', c.key, (await _conns(base, stats)).toDouble());
        }
      }
    }
    lines.add('');
    lines.add('== $title');
    // Values, then speed relative to dart:io (> 1 means faster).
    final keys = clients.keys.toList();
    lines.add('${'test'.padRight(15)}'
        '${keys.map((k) => names[k]!.padLeft(10)).join()}');
    for (final MapEntry(key: test, value: byClient) in results.entries) {
      if (test.endsWith('conns')) continue;
      final d = _median(byClient['dartio']!);
      String vs(double x) =>
          '${(test.contains('ms') ? d / x : x / d).toStringAsFixed(2)}x';
      final meds = {for (final k in keys) k: _median(byClient[k]!)};
      lines.add('${test.padRight(15)}'
          '${keys.map((k) => meds[k]!.toStringAsFixed(test.contains('ms') ? 3 : 0).padLeft(10)).join()}');
      lines.add('${''.padRight(15)}'
          '${keys.map((k) => vs(meds[k]!).padLeft(10)).join()}');
    }
    // Connections each client opened per test: the most seen in any round.
    lines.add('');
    lines.add('connections used (max of $_rounds rounds)');
    for (final MapEntry(key: test, value: byClient) in results.entries) {
      if (!test.endsWith('conns')) continue;
      String c(String k) =>
          byClient[k]!.reduce((a, b) => a > b ? a : b).toStringAsFixed(0);
      lines.add('${test.padRight(15)}'
          '${keys.map((k) => c(k).padLeft(10)).join()}');
    }
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
        await Isolate.spawn(_serve, (port.sendPort, false));
        _base = 'http://127.0.0.1:${await port.first}';
        final tlsPort = ReceivePort();
        await Isolate.spawn(_serve, (tlsPort.sendPort, true));
        _tlsBase = 'https://127.0.0.1:${await tlsPort.first}';
      }
      lines.add('median of $_rounds rounds · loopback · '
          '${const bool.fromEnvironment('dart.vm.product') ? 'release' : 'debug'}');
      await _suite(lines, 'HTTP', _base!, _stats, {
        'nitro': _nitroGet,
        'dn_http': _dnGet,
        'dartio': _ioGet,
      });
      // dartnative_http can't trust a test CA (no option for it), so HTTPS
      // compares the two clients that can.
      await _suite(lines, 'HTTPS', _tlsBase!, _statsTls, {
        'nitro': _nitroTlsGet,
        'dartio': _ioTlsGet,
      });
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
    _dn.close();
    _stats.close(force: true);
    _statsTls.close(force: true);
    _nitroTls.dispose();
    _nitroTlsSmall.dispose();
    _ioTls.close(force: true);
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
