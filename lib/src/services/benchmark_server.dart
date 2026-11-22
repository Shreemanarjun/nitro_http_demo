import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:typed_data';

import '../../tls_fixture.dart';

class BenchmarkServerManager {
  String? _httpBaseUrl;
  String? _httpsBaseUrl;

  String? get httpBaseUrl => _httpBaseUrl;
  String? get httpsBaseUrl => _httpsBaseUrl;

  Future<void> ensureServersRunning() async {
    if (_httpBaseUrl != null && _httpsBaseUrl != null) return;

    final httpPort = ReceivePort();
    await Isolate.spawn(_serveIsolate, (httpPort.sendPort, false));
    _httpBaseUrl = 'http://127.0.0.1:${await httpPort.first}';

    final httpsPort = ReceivePort();
    await Isolate.spawn(_serveIsolate, (httpsPort.sendPort, true));
    _httpsBaseUrl = 'https://127.0.0.1:${await httpsPort.first}';
  }

  static Future<void> _serveIsolate((SendPort, bool) args) async {
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

    final ports = <int>{};
    await for (final req in server) {
      if (req.uri.path == '/stats') {
        req.response.write(ports.length);
        ports.clear();
        await req.response.close();
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
      await res.close();
    }
  }
}
