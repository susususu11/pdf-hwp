import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

enum DocumentKind { pdf, hwp, hwpx, unsupported }

class OpenedDocument {
  const OpenedDocument({required this.path, required this.name, required this.hash, required this.kind});

  final String path;
  final String name;
  final String hash;
  final DocumentKind kind;

  bool get needsConversion => kind == DocumentKind.hwp || kind == DocumentKind.hwpx;

  Map<String, String> toJson() => {'path': path, 'name': name, 'hash': hash, 'kind': kind.name};

  static OpenedDocument fromJson(Map<String, dynamic> json) => OpenedDocument(
        path: json['path'] as String,
        name: json['name'] as String,
        hash: json['hash'] as String,
        kind: DocumentKind.values.byName(json['kind'] as String),
      );
}

/// 안드로이드의 파일 선택, "다음 앱으로 열기", 공유 메뉴를 Flutter와 잇는다.
class NativeFiles {
  static const _channel = MethodChannel('easy_doc_viewer/files');

  final _opened = StreamController<OpenedDocument>.broadcast();

  Stream<OpenedDocument> get opened => _opened.stream;

  NativeFiles() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'documentOpened') {
        final map = Map<String, String>.from(call.arguments as Map);
        _opened.add(await _describe(map));
      }
    });
  }

  Future<OpenedDocument?> pick() => _invoke('pickDocument');

  Future<OpenedDocument?> takeInitial() => _invoke('takeInitialDocument');

  Future<OpenedDocument?> _invoke(String method) async {
    final map = await _channel.invokeMapMethod<String, String>(method);
    return map == null ? null : _describe(map);
  }

  Future<OpenedDocument> _describe(Map<String, String> map) async {
    final path = map['path']!;
    return OpenedDocument(path: path, name: map['name']!, hash: map['hash']!, kind: await _detect(path));
  }

  /// 메신저가 파일 이름을 바꿔 보내는 경우가 있어 내용의 앞부분으로 형식을 판별한다.
  Future<DocumentKind> _detect(String path) async {
    final raf = await File(path).open();
    try {
      final head = await raf.read(8);
      if (_starts(head, const [0x25, 0x50, 0x44, 0x46])) return DocumentKind.pdf;
      if (_starts(head, const [0xD0, 0xCF, 0x11, 0xE0])) return DocumentKind.hwp;
      if (_starts(head, const [0x50, 0x4B])) return DocumentKind.hwpx;
      return DocumentKind.unsupported;
    } finally {
      await raf.close();
    }
  }

  bool _starts(List<int> data, List<int> magic) {
    if (data.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (data[i] != magic[i]) return false;
    }
    return true;
  }
}
