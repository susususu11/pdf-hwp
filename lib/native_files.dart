import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

enum DocumentKind {
  pdf('PDF'),
  hwp('HWP'),
  hwpx('HWPX'),
  docx('Word'),
  xlsx('Excel'),
  pptx('PowerPoint'),
  image('이미지'),
  text('텍스트'),
  legacyOffice('이전 Office 형식'),
  unsupported('지원하지 않는 형식');

  const DocumentKind(this.label);

  final String label;
}

class OpenedDocument {
  const OpenedDocument({required this.path, required this.name, required this.hash, required this.kind});

  final String path;
  final String name;
  final String hash;
  final DocumentKind kind;

  bool get needsConversion => kind == DocumentKind.hwp || kind == DocumentKind.hwpx;

  bool get isOffice => kind == DocumentKind.docx || kind == DocumentKind.xlsx || kind == DocumentKind.pptx;

  bool get canOpen => kind != DocumentKind.legacyOffice && kind != DocumentKind.unsupported;

  Map<String, String> toJson() => {'path': path, 'name': name, 'hash': hash, 'kind': kind.name};

  static OpenedDocument fromJson(Map<String, dynamic> json) => OpenedDocument(
        path: json['path'] as String,
        name: json['name'] as String,
        hash: json['hash'] as String,
        kind: DocumentKind.values.byName(json['kind'] as String),
      );
}

class TextContent {
  const TextContent(this.lines, {required this.truncated});

  final List<String> lines;
  final bool truncated;
}

/// 안드로이드의 파일 선택, "다음 앱으로 열기", 공유 메뉴를 Flutter와 잇는다.
class NativeFiles {
  static const _channel = MethodChannel('easy_doc_viewer/files');
  static const _textExtensions = {'txt', 'csv', 'tsv', 'md', 'json', 'log', 'xml', 'html', 'htm', 'ini', 'yaml', 'yml'};
  static const _scanBytes = 8 * 1024 * 1024;

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

  Future<bool> isSelfTest() async => await _channel.invokeMethod<bool>('isSelfTest') ?? false;

  static Future<TextContent> readText(String path) async {
    final map = await _channel.invokeMapMethod<String, Object>('readText', {'path': path});
    return TextContent(
      const LineSplitter().convert(map!['text']! as String),
      truncated: map['truncated']! as bool,
    );
  }

  Future<OpenedDocument?> _invoke(String method) async {
    final map = await _channel.invokeMapMethod<String, String>(method);
    return map == null ? null : _describe(map);
  }

  Future<OpenedDocument> _describe(Map<String, String> map) async {
    final path = map['path']!;
    final name = map['name']!;
    return OpenedDocument(path: path, name: name, hash: map['hash']!, kind: await detect(path, name));
  }

  /// 메신저가 파일 이름을 바꿔 보내는 경우가 있어 내용을 먼저 보고, 그다음 확장자를 본다.
  Future<DocumentKind> detect(String path, String name) async {
    final extension = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final raf = await File(path).open();
    try {
      final head = await raf.read(4096);
      if (_starts(head, const [0x25, 0x50, 0x44, 0x46])) return DocumentKind.pdf;
      if (_starts(head, const [0xD0, 0xCF, 0x11, 0xE0])) return await _detectOle(raf, extension);
      if (_starts(head, const [0x50, 0x4B])) return await _detectZip(raf, extension);
      if (_isImage(head) || const {'bmp', 'heic', 'heif'}.contains(extension)) return DocumentKind.image;
      if (_textExtensions.contains(extension) || !head.contains(0)) return DocumentKind.text;
      return DocumentKind.unsupported;
    } finally {
      await raf.close();
    }
  }

  /// HWP와 이전 Office 파일은 겉모양이 같다. 암호가 걸린 .docx 등도 이 형태로 저장된다.
  Future<DocumentKind> _detectOle(RandomAccessFile raf, String extension) async {
    if (extension == 'hwp') return DocumentKind.hwp;
    if (extension == 'xls') return DocumentKind.xlsx;
    if (const {'doc', 'dot', 'ppt', 'pps', 'docx', 'xlsx', 'pptx'}.contains(extension)) {
      return DocumentKind.legacyOffice;
    }
    await raf.setPosition(0);
    final data = await raf.read(_scanBytes);
    if (_contains(data, ascii.encode('HWP Document File'))) return DocumentKind.hwp;
    if (_contains(data, _utf16('Workbook')) || _contains(data, _utf16('Book'))) return DocumentKind.xlsx;
    if (_contains(data, _utf16('WordDocument')) || _contains(data, _utf16('PowerPoint Document'))) {
      return DocumentKind.legacyOffice;
    }
    return DocumentKind.hwp;
  }

  /// ZIP 파일 끝의 목록에 있는 이름으로 실제 형식을 찾는다.
  Future<DocumentKind> _detectZip(RandomAccessFile raf, String extension) async {
    final length = await raf.length();
    await raf.setPosition(max(0, length - 1024 * 1024));
    final tail = await raf.read(1024 * 1024);
    if (_contains(tail, ascii.encode('word/document'))) return DocumentKind.docx;
    if (_contains(tail, ascii.encode('xl/workbook'))) return DocumentKind.xlsx;
    if (_contains(tail, ascii.encode('ppt/presentation'))) return DocumentKind.pptx;
    if (_contains(tail, ascii.encode('Contents/section'))) return DocumentKind.hwpx;
    return switch (extension) {
      'docx' => DocumentKind.docx,
      'xlsx' => DocumentKind.xlsx,
      'pptx' => DocumentKind.pptx,
      'hwpx' => DocumentKind.hwpx,
      _ => DocumentKind.unsupported,
    };
  }

  bool _isImage(List<int> head) {
    final webp = head.length >= 12 && String.fromCharCodes(head.sublist(8, 12)) == 'WEBP';
    return _starts(head, const [0x89, 0x50, 0x4E, 0x47]) ||
        _starts(head, const [0xFF, 0xD8, 0xFF]) ||
        _starts(head, const [0x47, 0x49, 0x46, 0x38]) ||
        (_starts(head, const [0x52, 0x49, 0x46, 0x46]) && webp);
  }

  List<int> _utf16(String text) => [
        for (final unit in text.codeUnits) ...[unit, 0],
      ];

  bool _contains(List<int> data, List<int> pattern) {
    for (var i = 0; i <= data.length - pattern.length; i++) {
      var j = 0;
      while (j < pattern.length && data[i + j] == pattern[j]) {
        j++;
      }
      if (j == pattern.length) return true;
    }
    return false;
  }

  bool _starts(List<int> data, List<int> magic) {
    if (data.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (data[i] != magic[i]) return false;
    }
    return true;
  }
}
