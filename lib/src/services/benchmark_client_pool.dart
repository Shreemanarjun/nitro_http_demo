import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dartnative_http/http.dart';
import 'package:nitro_http/nitro_http.dart';

import '../../tls_fixture.dart';
import '../models/benchmark_config.dart';

class BenchmarkClientPool {
  BenchmarkClientPool({required this.config})
      : nitro = NitroHttpClient(
          settings: ClientSettings(
            cookieSettings: const CookieSettings.none(),
            poolSettings: PoolSettings(maxConnectionsPerHost: config.concurrencyWidth),
          ),
        ),
        ioClient = io.HttpClient()..maxConnectionsPerHost = config.concurrencyWidth,
        dnClient = NativeHttpClient(cache: false, cookies: false),
        statsClient = io.HttpClient(),
        statsTlsClient = io.HttpClient(
          context: io.SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificatesBytes(utf8.encode(benchCaPem)),
        )..badCertificateCallback = ((cert, host, port) =>
            host == '127.0.0.1' && cert.pem.trim() == benchServerCertPem.trim()),
        nitroTls = NitroHttpClient(
          settings: ClientSettings(
            cookieSettings: const CookieSettings.none(),
            poolSettings: PoolSettings(maxConnectionsPerHost: config.concurrencyWidth),
            tlsSettings: const TlsSettings(
              rootCaSource: RootCaSource.custom(benchTrustBundle),
            ),
          ),
        ),
        nitroTlsSmall = NitroHttpClient(
          settings: ClientSettings(
            cookieSettings: const CookieSettings.none(),
            poolSettings: PoolSettings(maxConnectionsPerHost: config.concurrencyWidth),
            tlsSettings: const TlsSettings(rootCaSource: RootCaSource.custom(benchCaPem)),
          ),
        ),
        ioTlsClient = io.HttpClient(
          context: io.SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificatesBytes(utf8.encode(benchTrustBundle)),
        )
          ..maxConnectionsPerHost = config.concurrencyWidth
          ..badCertificateCallback = ((cert, host, port) =>
              host == '127.0.0.1' && cert.pem.trim() == benchServerCertPem.trim());

  final BenchmarkConfig config;
  final NitroHttpClient nitro;
  final io.HttpClient ioClient;
  final NativeHttpClient dnClient;
  final io.HttpClient statsClient;
  final io.HttpClient statsTlsClient;
  final NitroHttpClient nitroTls;
  final NitroHttpClient nitroTlsSmall;
  final io.HttpClient ioTlsClient;

  Future<int> nitroGet(String url) => _nitroGetWith(nitro, url);
  Future<int> nitroTlsGet(String url) => _nitroGetWith(nitroTls, url);

  static Future<int> _nitroGetWith(NitroHttpClient client, String url) async {
    final res = await client.get(url);
    if (res.statusCode != 200) throw StateError('nitro ${res.statusCode}');
    return res.bodyBytes.length;
  }

  Future<int> dnGet(String url) async {
    final res = await dnClient.get(Uri.parse(url));
    if (res.statusCode != 200) throw StateError('dn_http ${res.statusCode}');
    return res.bodyBytes.length;
  }

  Future<int> ioGet(String url) => _ioGetWith(ioClient, url);
  Future<int> ioTlsGet(String url) => _ioGetWith(ioTlsClient, url);

  static Future<int> _ioGetWith(io.HttpClient client, String url) async {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) throw StateError('dart:io ${res.statusCode}');
    final b = BytesBuilder(copy: false);
    await for (final chunk in res) {
      b.add(chunk);
    }
    return b.takeBytes().length;
  }

  void dispose() {
    nitro.dispose();
    ioClient.close(force: true);
    dnClient.close();
    statsClient.close(force: true);
    statsTlsClient.close(force: true);
    nitroTls.dispose();
    nitroTlsSmall.dispose();
    ioTlsClient.close(force: true);
  }
}
