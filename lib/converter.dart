import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'native_files.dart';

class ConversionResult {
  const ConversionResult({required this.pdfPath, required this.warningPages, required this.pageTexts});

  final String pdfPath;
  final List<int> warningPages;
  final List<String> pageTexts;
}

class _Job {
  _Job(this.document, this.pdfPath, this.metaPath, this.onProgress);

  final OpenedDocument document;
  final String pdfPath;
  final String metaPath;
  final void Function(int done, int total)? onProgress;
  final completer = Completer<ConversionResult>();
}

/// 앱 내부 서버와 보이지 않는 WebView로 rhwp(WASM)를 실행한다.
/// 문서는 이 기기 밖으로 나가지 않는다.
class ConverterService {
  /// 변환 방식을 바꾸면 값을 올려 기존 변환본을 다시 만든다.
  static const _cacheVersion = 'v1';
  static const _timeout = Duration(minutes: 3);
  static const _mime = {
    'html': 'text/html; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'wasm': 'application/wasm',
  };

  final WebViewController controller = WebViewController();

  HttpServer? _server;
  late final String _token;
  _Job? _job;
  Future<void> _queue = Future.value();

  Future<void> start() async {
    if (_server != null) return;
    final random = Random.secure();
    _token = List.generate(24, (_) => random.nextInt(16).toRadixString(16)).join();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle);
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setOnConsoleMessage((message) {
      // ignore: avoid_print
      print('WEBVIEW ${message.level.name}: ${message.message}');
    });
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          final local = Uri.parse(request.url).host == '127.0.0.1';
          return local ? NavigationDecision.navigate : NavigationDecision.prevent;
        },
      ),
    );
  }

  Future<ConversionResult> convert(
    OpenedDocument document, {
    void Function(int done, int total)? onProgress,
  }) async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/converted');
    await dir.create(recursive: true);
    final base = '${dir.path}/${document.hash}.$_cacheVersion';
    final job = _Job(document, '$base.pdf', '$base.json', onProgress);

    final cached = await _readCached(job);
    if (cached != null) return cached;

    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    await previous;
    try {
      return await _run(job);
    } finally {
      _job = null;
      done.complete();
    }
  }

  Future<ConversionResult?> _readCached(_Job job) async {
    final pdf = File(job.pdfPath);
    final meta = File(job.metaPath);
    if (!await pdf.exists() || !await meta.exists()) return null;
    try {
      return _parseMeta(job.pdfPath, await meta.readAsString());
    } on FormatException {
      return null;
    }
  }

  ConversionResult _parseMeta(String pdfPath, String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    return ConversionResult(
      pdfPath: pdfPath,
      warningPages: (json['warningPages'] as List<dynamic>).cast<int>(),
      pageTexts: (json['pageTexts'] as List<dynamic>).cast<String>(),
    );
  }

  Future<ConversionResult> _run(_Job job) async {
    await start();
    _job = job;
    final port = _server!.port;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    await controller.loadRequest(Uri.parse('http://127.0.0.1:$port/$_token/app/converter/index.html?$stamp'));
    return job.completer.future.timeout(
      _timeout,
      onTimeout: () => throw TimeoutException('문서 변환 시간이 너무 오래 걸립니다'),
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 3 || segments[0] != _token || segments[1] != 'app') {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      final route = segments.sublist(2).join('/');
      final job = _job;
      if (route.startsWith('converter/') || route.startsWith('rhwp/')) {
        await _serveAsset(route, response);
      } else if (job == null) {
        response.statusCode = HttpStatus.conflict;
      } else if (route == 'doc') {
        response.headers.contentType = ContentType.binary;
        await response.addStream(File(job.document.path).openRead());
      } else if (route == 'progress') {
        final q = request.uri.queryParameters;
        job.onProgress?.call(int.parse(q['done']!), int.parse(q['total']!));
      } else if (route == 'pdf') {
        final temp = File('${job.pdfPath}.tmp');
        final sink = temp.openWrite();
        await sink.addStream(request);
        await sink.close();
        await temp.rename(job.pdfPath);
      } else if (route == 'meta') {
        final text = await utf8.decoder.bind(request).join();
        await File(job.metaPath).writeAsString(text);
        if (!job.completer.isCompleted) job.completer.complete(_parseMeta(job.pdfPath, text));
      } else if (route == 'error') {
        final message = await utf8.decoder.bind(request).join();
        if (!job.completer.isCompleted) job.completer.completeError(Exception(message));
      } else {
        response.statusCode = HttpStatus.notFound;
      }
    } catch (error) {
      final job = _job;
      if (job != null && !job.completer.isCompleted) job.completer.completeError(error);
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      await response.close().catchError((_) {});
    }
  }

  Future<void> _serveAsset(String route, HttpResponse response) async {
    final ByteData data;
    try {
      data = await rootBundle.load('assets/$route');
    } on FlutterError {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    final extension = route.split('.').last;
    response.headers.set(HttpHeaders.contentTypeHeader, _mime[extension] ?? 'application/octet-stream');
    response.add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  }
}
