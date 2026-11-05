import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'converter.dart';
import 'native_files.dart';
import 'screens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(MobileAds.instance.initialize());
  runApp(const EasyDocApp());
}

class EasyDocApp extends StatefulWidget {
  const EasyDocApp({super.key});

  @override
  State<EasyDocApp> createState() => _EasyDocAppState();
}

class _EasyDocAppState extends State<EasyDocApp> {
  final _navigator = GlobalKey<NavigatorState>();
  final _files = NativeFiles();
  final _converter = ConverterService();
  final _recent = RecentDocuments();
  StreamSubscription<OpenedDocument>? _subscription;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _subscription = _files.opened.listen(_open);
    _prepare();
  }

  Future<void> _prepare() async {
    await _converter.start();
    await _recent.load();
    if (mounted) setState(() => _ready = true);
    final initial = await _files.takeInitial();
    if (initial != null) _open(initial);
    if (await _files.isSelfTest()) await _runSelfTest();
  }

  /// 자동 시험 전용. 내장 문서를 실제 엔진으로 변환해 결과를 로그에 남긴다.
  Future<void> _runSelfTest() async {
    try {
      final data = await rootBundle.load('assets/selftest/sample.hwpx');
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/selftest.hwpx');
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      final document = OpenedDocument(path: file.path, name: 'selftest.hwpx', hash: 'selftest', kind: DocumentKind.hwpx);
      final watch = Stopwatch()..start();
      final result = await _converter.convert(document);
      final size = await File(result.pdfPath).length();
      final text = result.pageTexts.isEmpty ? '' : result.pageTexts.first.replaceAll('\n', ' ');
      final preview = text.length > 60 ? text.substring(0, 60) : text;
      // ignore: avoid_print
      print('SELFTEST OK ms=${watch.elapsedMilliseconds} pages=${result.pageTexts.length} '
          'warn=${result.warningPages} pdfBytes=$size text=$preview');
      _open(document);
    } catch (error) {
      // ignore: avoid_print
      print('SELFTEST FAIL $error');
    }
  }

  void _open(OpenedDocument document) {
    if (document.kind != DocumentKind.unsupported) unawaited(_recent.add(document));
    _navigator.currentState?.push(
      MaterialPageRoute<void>(builder: (_) => ReaderScreen(document: document, converter: _converter)),
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '편한 문서 뷰어',
      navigatorKey: _navigator,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [
          // 변환용 WebView는 화면에 보이지 않지만 항상 살아 있어야 한다.
          if (_ready)
            Positioned(
              left: 0,
              top: 0,
              width: 1,
              height: 1,
              child: Opacity(opacity: 0, child: WebViewWidget(controller: _converter.controller)),
            ),
          child ?? const SizedBox.shrink(),
        ],
      ),
      home: _ready
          ? HomeScreen(
              recent: _recent,
              onPick: () async {
                final document = await _files.pick();
                if (document != null) _open(document);
              },
              onOpen: _open,
            )
          : const Scaffold(body: Center(child: CircularProgressIndicator())),
    );
  }
}

class RecentDocuments extends ChangeNotifier {
  static const _limit = 20;

  List<OpenedDocument> items = [];
  late File _store;

  Future<void> load() async {
    _store = File('${(await getApplicationSupportDirectory()).path}/recent.json');
    if (!await _store.exists()) return;
    try {
      final list = jsonDecode(await _store.readAsString()) as List<dynamic>;
      final loaded = list.map((e) => OpenedDocument.fromJson(e as Map<String, dynamic>));
      items = loaded.where((d) => File(d.path).existsSync()).toList();
    } on FormatException {
      items = [];
    }
  }

  Future<void> add(OpenedDocument document) async {
    items = [document, ...items.where((d) => d.hash != document.hash)];
    if (items.length > _limit) {
      for (final old in items.sublist(_limit)) {
        final file = File(old.path);
        if (await file.exists()) await file.delete();
      }
      items = items.sublist(0, _limit);
    }
    notifyListeners();
    await _store.writeAsString(jsonEncode(items.map((d) => d.toJson()).toList()));
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.recent, required this.onPick, required this.onOpen});

  final RecentDocuments recent;
  final VoidCallback onPick;
  final ValueChanged<OpenedDocument> onOpen;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('편한 문서 뷰어')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: onPick,
        icon: const Icon(Icons.folder_open),
        label: const Text('문서 열기'),
      ),
      body: ListenableBuilder(
        listenable: recent,
        builder: (context, _) {
          if (recent.items.isEmpty) {
            return const Center(child: Text('HWP, HWPX, PDF 문서를 열어 보세요'));
          }
          return ListView(
            children: [
              for (final document in recent.items)
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(document.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(document.kind.name.toUpperCase()),
                  onTap: () => onOpen(document),
                ),
            ],
          );
        },
      ),
    );
  }
}
