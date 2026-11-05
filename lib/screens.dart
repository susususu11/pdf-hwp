import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'converter.dart';
import 'native_files.dart';
import 'purchases.dart';

/// Google이 제공하는 시험용 배너 ID. 출시 전에 실제 ID로 바꿔야 한다.
const _testBannerId = 'ca-app-pub-3940256099942544/6300978111';
const _bannerSlotHeight = 58.0;

/// 광고 제거를 구매하면 배너를 만들지도, 자리를 차지하지도 않는다.
/// [visible]이 false이면 자리만 비워 두어 문서가 나타난 뒤 화면이 들썩이지 않게 한다.
class BannerSlot extends StatelessWidget {
  const BannerSlot({super.key, required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: purchases.adFree,
      builder: (context, adFree, _) {
        if (adFree) return const SizedBox.shrink();
        return visible ? const _Banner() : const SizedBox(height: _bannerSlotHeight);
      },
    );
  }
}

class _Banner extends StatefulWidget {
  const _Banner();

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _ad = BannerAd(
      adUnitId: _testBannerId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, _) {
          ad.dispose();
          if (mounted) setState(() => _ad = null);
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    // 광고가 없어도 자리를 유지해 문서가 들썩이지 않게 한다.
    return Container(
      height: _bannerSlotHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: _loaded && ad != null
          ? SizedBox(width: ad.size.width.toDouble(), height: ad.size.height.toDouble(), child: AdWidget(ad: ad))
          : null,
    );
  }
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.document, required this.converter});

  final OpenedDocument document;
  final ConverterService converter;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  ConversionResult? _result;
  Object? _error;
  int _done = 0;
  int _total = 0;
  bool _warningDismissed = false;
  bool _contentShown = false;

  OpenedDocument get _document => widget.document;

  @override
  void initState() {
    super.initState();
    if (_document.needsConversion) _convert();
  }

  Future<void> _convert() async {
    setState(() => _error = null);
    try {
      final result = await widget.converter.convert(
        _document,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _done = done;
              _total = total;
            });
          }
        },
      );
      if (mounted) setState(() => _result = result);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _markContentShown() {
    if (mounted && !_contentShown) setState(() => _contentShown = true);
  }

  void _onPdfReady(PdfDocument document, PdfViewerController controller) => _markContentShown();

  Widget _pdf(String path) => PdfViewer.file(path, params: PdfViewerParams(onViewerReady: _onPdfReady));

  void _openText() {
    final texts = _result?.pageTexts ?? const <String>[];
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => TextViewScreen(title: _document.name, pageTexts: texts)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_document.name, overflow: TextOverflow.ellipsis),
        actions: [
          if (_result != null)
            IconButton(icon: const Icon(Icons.subject), tooltip: '텍스트로 보기', onPressed: _openText),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody()),
          // 문서가 실제로 화면에 나타난 뒤에만 광고를 띄운다.
          // 로딩, 오류, 빈 화면의 광고는 AdMob의 콘텐츠 없는 화면 정책에 어긋난다.
          BannerSlot(visible: _contentShown),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_document.kind) {
      case DocumentKind.unsupported:
        return const _Message('열 수 없는 파일입니다.\nHWP, PDF, Word, Excel, PowerPoint, 이미지, 텍스트 파일을 열 수 있습니다.');
      case DocumentKind.legacyOffice:
        return const _Message('이전 형식(.doc, .ppt)이나 암호가 걸린 Office 문서는 아직 열 수 없습니다.\n'
            'Word나 PowerPoint에서 .docx, .pptx로 저장한 파일을 열어 주세요.');
      case DocumentKind.pdf:
        return _pdf(_document.path);
      case DocumentKind.docx:
      case DocumentKind.xlsx:
      case DocumentKind.pptx:
        return OfficeView(document: _document, converter: widget.converter, onShown: _markContentShown);
      case DocumentKind.image:
        return _ImageView(path: _document.path, onShown: _markContentShown);
      case DocumentKind.text:
        return _PlainTextView(path: _document.path, onShown: _markContentShown);
      case DocumentKind.hwp:
      case DocumentKind.hwpx:
        return _buildConverted();
    }
  }

  Widget _buildConverted() {
    if (_error != null) {
      return _Message('문서를 변환하지 못했습니다.\n$_error', action: _convert, actionLabel: '다시 시도');
    }
    final result = _result;
    if (result == null) {
      final progress = _total == 0 ? null : _done / _total;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 200, child: LinearProgressIndicator(value: progress)),
            const SizedBox(height: 12),
            Text(_total == 0 ? '문서를 준비하고 있습니다' : '$_done / $_total쪽 변환 중'),
          ],
        ),
      );
    }
    return Column(
      children: [
        if (result.warningPages.isNotEmpty && !_warningDismissed) _warningBanner(result.warningPages),
        Expanded(child: _pdf(result.pdfPath)),
      ],
    );
  }

  Widget _warningBanner(List<int> pages) {
    return MaterialBanner(
      content: Text('${pages.join(', ')}쪽에서 글자가 겹쳐 일부 내용이 가려졌을 수 있습니다.'),
      actions: [
        TextButton(onPressed: _openText, child: const Text('텍스트로 보기')),
        TextButton(onPressed: () => setState(() => _warningDismissed = true), child: const Text('닫기')),
      ],
    );
  }
}

/// Word, Excel, PowerPoint는 앱 안의 WebView로 그린다. 외부 주소로는 이동하지 못한다.
class OfficeView extends StatefulWidget {
  const OfficeView({super.key, required this.document, required this.converter, required this.onShown});

  final OpenedDocument document;
  final ConverterService converter;
  final VoidCallback onShown;

  @override
  State<OfficeView> createState() => _OfficeViewState();
}

class _OfficeViewState extends State<OfficeView> {
  final _controller = WebViewController();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final hash = widget.document.hash;
    // 실패하면 onShown을 부르지 않는다. 오류 안내는 WebView 안에 표시된다.
    unawaited(widget.converter.waitForView(hash).then((_) => widget.onShown(), onError: (Object _) {}));
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.setOnConsoleMessage((message) {
      // ignore: avoid_print
      print('WEBVIEW ${message.level.name}: ${message.message}');
    });
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          final local = Uri.parse(request.url).host == '127.0.0.1';
          return local ? NavigationDecision.navigate : NavigationDecision.prevent;
        },
      ),
    );
    await _controller.loadRequest(await widget.converter.viewUrl(widget.document));
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    return _ready ? WebViewWidget(controller: _controller) : const Center(child: CircularProgressIndicator());
  }
}

class _ImageView extends StatelessWidget {
  const _ImageView({required this.path, required this.onShown});

  static const _maxDecodeWidth = 4096;

  final String path;
  final VoidCallback onShown;

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      maxScale: 8,
      child: Center(
        child: Image.file(
          File(path),
          cacheWidth: _maxDecodeWidth,
          frameBuilder: (_, child, frame, __) {
            if (frame != null) WidgetsBinding.instance.addPostFrameCallback((_) => onShown());
            return child;
          },
          errorBuilder: (_, __, ___) => const _Message('이미지를 열지 못했습니다.'),
        ),
      ),
    );
  }
}

class _PlainTextView extends StatefulWidget {
  const _PlainTextView({required this.path, required this.onShown});

  final String path;
  final VoidCallback onShown;

  @override
  State<_PlainTextView> createState() => _PlainTextViewState();
}

class _PlainTextViewState extends State<_PlainTextView> {
  late final Future<TextContent> _content;

  @override
  void initState() {
    super.initState();
    _content = NativeFiles.readText(widget.path);
    _content.then((content) {
      if (content.lines.any((line) => line.trim().isNotEmpty)) widget.onShown();
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TextContent>(
      future: _content,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const _Message('텍스트 파일을 읽지 못했습니다.');
        final content = snapshot.data;
        if (content == null) return const Center(child: CircularProgressIndicator());
        final lines = content.lines;
        final extra = content.truncated ? 1 : 0;
        return SelectionArea(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: lines.length + extra,
            itemBuilder: (context, index) =>
                Text(index < lines.length ? lines[index] : '파일이 커서 앞부분만 표시합니다.'),
          ),
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.action, this.actionLabel});

  final String text;
  final VoidCallback? action;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: 12),
              FilledButton(onPressed: action, child: Text(actionLabel ?? '확인')),
            ],
          ],
        ),
      ),
    );
  }
}

class TextViewScreen extends StatelessWidget {
  const TextViewScreen({super.key, required this.title, required this.pageTexts});

  final String title;
  final List<String> pageTexts;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: pageTexts.length,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${index + 1}쪽', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              SelectableText(pageTexts[index]),
            ],
          ),
        ),
      ),
    );
  }
}
