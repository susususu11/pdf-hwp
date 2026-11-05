import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:path_provider/path_provider.dart';

/// 한 번 결제하면 광고가 사라지는 상품. Play Console에 같은 ID로 인앱 상품을 만들어야 한다.
class PurchaseService {
  static const productId = 'remove_ads';

  final ValueNotifier<bool> adFree = ValueNotifier(false);
  final _notices = StreamController<String>.broadcast();
  final _store = InAppPurchase.instance;

  ProductDetails? product;
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  late File _flag;

  /// 결제 결과처럼 사용자에게 알려야 하는 문구.
  Stream<String> get notices => _notices.stream;

  /// 저장된 상태를 먼저 읽어 광고 제거 사용자에게 배너가 잠깐 보이는 일을 막는다.
  Future<void> start() async {
    _flag = File('${(await getApplicationSupportDirectory()).path}/ad_free.flag');
    adFree.value = await _flag.exists();
    unawaited(_connect());
  }

  Future<void> _connect() async {
    try {
      _subscription = _store.purchaseStream.listen(_onPurchases, onError: (Object error) {
        debugPrint('PURCHASE $error');
      });
      if (await refresh()) await _store.restorePurchases();
    } catch (error) {
      // 스토어가 없는 기기에서도 앱은 광고가 있는 상태로 정상 동작해야 한다.
      debugPrint('PURCHASE $error');
    }
  }

  /// 상품 정보를 다시 읽는다. Play 스토어를 쓸 수 없으면 false.
  Future<bool> refresh() async {
    if (!await _store.isAvailable()) return false;
    final response = await _store.queryProductDetails({productId});
    product = response.productDetails.isEmpty ? null : response.productDetails.first;
    return true;
  }

  Future<void> buy() async {
    final details = product;
    if (details == null) return;
    await _store.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: details));
  }

  Future<void> restore() async {
    await _store.restorePurchases();
    _notices.add('구매 내역을 확인했습니다. 구매한 적이 있다면 광고가 사라집니다.');
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.productID != productId) continue;
      switch (purchase.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _grant(notify: purchase.status == PurchaseStatus.purchased);
        case PurchaseStatus.pending:
          _notices.add('결제를 확인하고 있습니다. 완료되면 광고가 사라집니다.');
        case PurchaseStatus.error:
          _notices.add('결제하지 못했습니다. 잠시 후 다시 시도해 주세요.');
        case PurchaseStatus.canceled:
          break;
      }
      // 완료 처리를 하지 않으면 Google Play가 며칠 뒤 자동 환불한다.
      if (purchase.pendingCompletePurchase) await _store.completePurchase(purchase);
    }
  }

  Future<void> _grant({required bool notify}) async {
    await _flag.writeAsString('1');
    adFree.value = true;
    if (notify) _notices.add('광고가 제거되었습니다. 감사합니다.');
  }

  void dispose() {
    _subscription?.cancel();
  }
}

final purchases = PurchaseService();
