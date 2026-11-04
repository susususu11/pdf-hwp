import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:pdfrx/pdfrx.dart';

import 'converter.dart';
import 'native_files.dart';

/// Google이 제공하는 시험용 배너 ID. 출시 전에 실제 ID로 바꿔야 한다.
const _testBannerId = 'ca-app-pub-3940256099942544/6300978111';
const _bannerSlotHeight = 58.0;

class BannerSlot extends StatefulWidget {
  const BannerSlot({super.key});

  @override
  State<BannerSlot> createState() => _BannerSlotState();
}

class _BannerSlotState extends State<BannerSlot> {
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
          const BannerSlot(),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_document.kind == DocumentKind.unsupported) {
      return const _Message('HWP, HWPX, PDF 문서만 열 수 있습니다.');
    }
    if (_document.kind == DocumentKind.pdf) return PdfViewer.file(_document.path);
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
        Expanded(child: PdfViewer.file(result.pdfPath)),
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
