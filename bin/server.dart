import 'dart:convert';
import 'dart:io';

import '../lib/model.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--json')) {
    stdout.writeln(jsonEncode(simulate(const Config())));
    return;
  }

  final host = Platform.environment['HOST'] ?? '127.0.0.1';
  final rawPort = Platform.environment['PORT'] ?? '8080';
  final port = int.tryParse(rawPort);
  if (!{'127.0.0.1', 'localhost', '0.0.0.0'}.contains(host)) {
    stderr.writeln('HOST must be 127.0.0.1, localhost, or 0.0.0.0');
    exitCode = 2;
    return;
  }
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('PORT must be an integer from 0 to 65535');
    exitCode = 2;
    return;
  }

  final publicDirectory = Platform.environment['PUBLIC_DIR'] ?? 'public';
  final server = await HttpServer.bind(host, port);
  final displayHost = host == '0.0.0.0' ? '127.0.0.1' : host;
  stdout.writeln(
    jsonEncode({
      'event': 'server.started',
      'url': 'http://$displayHost:${server.port}',
    }),
  );

  await for (final request in server) {
    await _handle(request, publicDirectory);
  }
}

Future<void> _handle(HttpRequest request, String publicDirectory) async {
  if (request.method != 'GET') {
    await _json(request.response, HttpStatus.methodNotAllowed, {
      'error': 'method not allowed',
    });
    return;
  }

  switch (request.uri.path) {
    case '/healthz':
      await _send(request.response, HttpStatus.ok, 'ok', ContentType.text);
    case '/api/simulate':
      final query = request.uri.queryParameters;
      await _json(
        request.response,
        HttpStatus.ok,
        simulate(Config.fromQuery(query)),
      );
    case '/':
      await _static(
        request.response,
        '$publicDirectory/index.html',
        ContentType.html,
      );
    case '/app.js':
      await _static(
        request.response,
        '$publicDirectory/app.js',
        ContentType('text', 'javascript', charset: 'utf-8'),
      );
    case '/styles.css':
      await _static(
        request.response,
        '$publicDirectory/styles.css',
        ContentType('text', 'css', charset: 'utf-8'),
      );
    default:
      await _json(request.response, HttpStatus.notFound, {
        'error': 'not found',
      });
  }
}

Future<void> _static(
  HttpResponse response,
  String fileName,
  ContentType contentType,
) async {
  final file = File(fileName);
  if (!await file.exists()) {
    await _json(response, HttpStatus.notFound, {'error': 'not found'});
    return;
  }
  await _send(response, HttpStatus.ok, await file.readAsBytes(), contentType);
}

Future<void> _json(
  HttpResponse response,
  int statusCode,
  Map<String, Object> body,
) => _send(response, statusCode, jsonEncode(body), ContentType.json);

Future<void> _send(
  HttpResponse response,
  int statusCode,
  Object body,
  ContentType contentType,
) async {
  response
    ..statusCode = statusCode
    ..headers.contentType = contentType
    ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
    ..headers.set(
      'Content-Security-Policy',
      "default-src 'self'; connect-src 'self'; img-src 'self' data:; "
          "style-src 'self'; script-src 'self'; base-uri 'none'; "
          "frame-ancestors 'none'",
    )
    ..headers.set('Referrer-Policy', 'no-referrer')
    ..headers.set('X-Content-Type-Options', 'nosniff')
    ..headers.set('X-Frame-Options', 'DENY');
  if (body case final List<int> bytes) {
    response.add(bytes);
  } else {
    response.write(body);
  }
  await response.close();
}
