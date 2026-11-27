// Backend service: Firebase Auth + Firestore for the Store project.
// All failures are logged to Diagnostics with their real reason and
// rethrown as plain-language messages — never swallowed silently.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/customers.dart';
import '../core/diagnostics.dart';
import '../core/identifier.dart';
import '../firebase_options.dart';
import 'cloudinary.dart';

class BackendException implements Exception {
  BackendException(this.message);
  final String message;
  @override
  String toString() => message;
}

String _friendlyAuthError(FirebaseAuthException e) {
  switch (e.code) {
    case 'invalid-credential':
    case 'wrong-password':
    case 'user-not-found':
      return 'بيانات الدخول غير صحيحة';
    case 'email-already-in-use':
      return 'الإيميل ده مستخدم قبل كده';
    case 'invalid-email':
      return 'الإيميل مش صحيح';
    case 'weak-password':
      return 'كلمة السر ضعيفة — لازم 6 حروف على الأقل';
    case 'network-request-failed':
      return 'مفيش اتصال بالإنترنت';
    default:
      return 'حصل خطأ: ${e.code}';
  }
}

class ProductData {
  ProductData({
    required this.id,
    required this.name,
    required this.price,
    required this.description,
    required this.categoryId,
    this.images = const <CloudinaryImage>[],
    this.featured = false,
    this.basePrice,
    this.discountSetAt,
  });
  final String id;
  final String name;
  final double price;
  final String description;
  final String categoryId;

  /// Featured on the storefront (no-functions contract §7/§9): the
  /// storefront lists every product with featured == true first.
  final bool featured;

  /// Gallery: cover = images[0]. A pasted link is an entry with an empty
  /// publicId. Legacy single imageUrl docs are read as one image.
  final List<CloudinaryImage> images;

  /// Pricing (Model P, Technical Plan §1): `price` is the effective
  /// (charged) price; [basePrice] is the display-only anchor the
  /// strikethrough / % / savings derive from. Null means no sale.
  final int? basePrice;

  /// When the current discount was first saved (Technical Plan §1 /
  /// B5). Set when a discount is first saved, cleared when removed;
  /// re-saving a different discounted price does NOT reset it. The
  /// admin product list shows "خصم نشط منذ X يوم" from this stamp.
  final DateTime? discountSetAt;

  factory ProductData.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    final rawImages = d['images'] as List<dynamic>? ?? [];
    var images = rawImages
        .whereType<Map<String, dynamic>>()
        .map(CloudinaryImage.fromMap)
        .where((img) => img.url.isNotEmpty)
        .toList();
    if (images.isEmpty) {
      final legacyUrl = (d['imageUrl'] ?? '') as String;
      if (legacyUrl.isNotEmpty) {
        images = [CloudinaryImage(url: legacyUrl, publicId: '')];
      }
    }
    return ProductData(
      id: doc.id,
      name: (d['name'] ?? '') as String,
      price: ((d['price'] ?? 0) as num).toDouble(),
      description: (d['description'] ?? '') as String,
      categoryId: (d['categoryId'] ?? '') as String,
      images: images,
      featured: (d['featured'] ?? false) == true,
      basePrice: (d['basePrice'] as num?)?.toInt(),
      discountSetAt: (d['discountSetAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// What a product save does to `discountSetAt` (B5) — see
/// [Backend.resolveDiscountSetAt].
enum DiscountSetAtAction {
  /// Keep the stored stamp (a live discount is re-saved).
  keep,

  /// Stamp now (a discount is saved for the first time).
  setNow,

  /// Clear the stamp (the discount is removed).
  clear,
}

class Backend {
  Backend._();
  static final Backend instance = Backend._();

  bool initialized = false;
  String? initError;

  FirebaseFirestore get db => FirebaseFirestore.instance;
  FirebaseAuth get auth => FirebaseAuth.instance;

  Future<void> init() async {
    try {
      await Firebase.initializeApp(options: StoreFirebaseOptions.options);
      initialized = true;
      Diagnostics.instance.log('Firebase initialized (store-3384c)');
    } catch (e) {
      initError = e.toString();
      Diagnostics.instance.log('Firebase init failed: $e');
    }
  }

  void _requireInit() {
    if (!initialized) {
      throw BackendException(initError == null
          ? 'الخدمة مش متوصلة — راجع سجل التشخيص'
          : 'تعذر الاتصال بقاعدة البيانات: $initError');
    }
  }

  // ---- Audited writes (v1.4 §5.2, enforced by firestore.rules) ----
  //
  // Every admin mutation is a batched write that includes its audit
  // entry: /audit/{operationId}, where operationId is a fresh auto-id
  // per operation. Each changed document carries the same operationId
  // as a metadata field (stamped alongside updatedAt), so the rules
  // can find the audit entry with getAfter(). The audit entry carries:
  //   docIds: { '<collection>/<docId>': [changedFields...] }
  //   newValuesByDoc: { '<collection>/<docId>': {sensitive field: new value} }
  // The rules check actor + timestamp + docIds coverage + the recorded
  // new value of every changed SENSITIVE field (price, stock, reserved,
  // status, paymentStatus, inStock, percent). Writes are chunked at 10
  // document pairs per batch (20 documents incl. the audit entry) per
  // the rules' access-call budget (v1.2 §11); each chunk gets its own
  // operationId + audit entry.

  /// One audited write chunk: [writes] maps `'collection/docId'` to
  /// the fields to set (merged, unless [merge] is false — the homepage
  /// uses a full replace). [sensitive] maps the same key to the changed
  /// sensitive fields with their new values. [oldValues] (optional)
  /// maps the same key to the values being replaced, when the caller
  /// knows them (order status changes, deletes).
  Future<void> _auditedBatch({
    required Map<String, Map<String, dynamic>> writes,
    required Map<String, Map<String, dynamic>> sensitive,
    required String operation,
    Map<String, Map<String, dynamic>> oldValues = const {},
    Map<String, dynamic> topNewValues = const {},
    bool merge = true,
  }) async {
    final entries = writes.entries.toList();
    for (var start = 0; start < entries.length; start += 10) {
      final chunk = entries.sublist(start, (start + 10).clamp(0, entries.length));
      final batch = db.batch();
      final auditRef = db.collection('audit').doc();
      final opId = auditRef.id;
      final docIds = <String, List<String>>{};
      final newValuesByDoc = <String, Map<String, dynamic>>{};
      final documents = <Map<String, dynamic>>[];
      String primaryCollection = '';
      String primaryDocId = '';
      for (final entry in chunk) {
        final slash = entry.key.indexOf('/');
        final collection = entry.key.substring(0, slash);
        final docId = entry.key.substring(slash + 1);
        if (primaryCollection.isEmpty) {
          primaryCollection = collection;
          primaryDocId = docId;
        }
        final ref = db.collection(collection).doc(docId);
        final data = <String, dynamic>{
          ...entry.value,
          'operationId': opId,
          'updatedAt': FieldValue.serverTimestamp(),
        };
        if (merge) {
          batch.set(ref, data, SetOptions(merge: true));
        } else {
          batch.set(ref, data);
        }
        final changed = data.keys.toList();
        docIds[entry.key] = changed;
        newValuesByDoc[entry.key] = sensitive[entry.key] ?? {};
        documents.add({
          'collection': collection,
          'docId': docId,
          'changedFields': changed,
          'oldValues': oldValues[entry.key] ?? {},
          'newValues': sensitive[entry.key] ?? {},
        });
      }
      batch.set(auditRef, {
        'operationId': opId,
        'actor': auth.currentUser?.uid ?? '',
        'actorName': auth.currentUser?.email ?? '',
        'timestamp': FieldValue.serverTimestamp(),
        'collection': primaryCollection,
        'docId': primaryDocId,
        'operation': operation,
        'changedFields': docIds.values.expand((e) => e).toSet().toList(),
        'oldValues': oldValues.values.fold<Map<String, dynamic>>(
            {}, (acc, m) => {...acc, ...m}),
        'newValues': topNewValues,
        'docIds': docIds,
        'newValuesByDoc': newValuesByDoc,
        'documents': documents,
        'source': 'flutter_admin',
      });
      try {
        await batch.commit();
      } on FirebaseException catch (e) {
        Diagnostics.instance.log('Audited write failed ($operation): ${e.code} ${e.message}');
        throw BackendException('تعذر حفظ التغيير: ${e.message ?? e.code}');
      }
    }
  }

  /// Public entry point to the audited-write system above, for the
  /// template service (Phase 3): the registry writes are admin
  /// writes, so they go through the same batch + audit entry the
  /// rules enforce — never a second audit implementation.
  Future<void> auditedWrite({
    required Map<String, Map<String, dynamic>> writes,
    required Map<String, Map<String, dynamic>> sensitive,
    required String operation,
    Map<String, Map<String, dynamic>> oldValues = const {},
    Map<String, dynamic> topNewValues = const {},
    bool merge = true,
  }) async {
    _requireInit();
    await _auditedBatch(
      writes: writes,
      sensitive: sensitive,
      operation: operation,
      oldValues: oldValues,
      topNewValues: topNewValues,
      merge: merge,
    );
  }

  /// An audited delete: the document is deleted and the audit entry
  /// uses the deterministic id `del_<collection>_<docId>` (a delete
  /// carries no resource data, so the rules cannot read an operationId
  /// from the write — see firestore.rules).
  Future<void> _auditedDelete({
    required String collection,
    required String docId,
    required List<String> changedFields,
    Map<String, dynamic> oldValues = const {},
  }) async {
    final batch = db.batch();
    final auditId = 'del_${collection}_$docId';
    batch.delete(db.collection(collection).doc(docId));
    batch.set(db.collection('audit').doc(auditId), {
      'operationId': auditId,
      'actor': auth.currentUser?.uid ?? '',
      'actorName': auth.currentUser?.email ?? '',
      'timestamp': FieldValue.serverTimestamp(),
      'collection': collection,
      'docId': docId,
      'operation': 'delete',
      'changedFields': changedFields,
      'oldValues': oldValues,
      'newValues': {},
      'docIds': {'$collection/$docId': changedFields},
      'newValuesByDoc': {'$collection/$docId': {}},
      'documents': [
        {
          'collection': collection,
          'docId': docId,
          'changedFields': changedFields,
          'oldValues': oldValues,
          'newValues': {},
        }
      ],
      'source': 'flutter_admin',
    });
    try {
      await batch.commit();
    } on FirebaseException catch (e) {
      Diagnostics.instance.log('Audited delete failed ($collection/$docId): ${e.code} ${e.message}');
      throw BackendException('تعذر الحذف: ${e.message ?? e.code}');
    }
  }

  /// The current user's admin profile (role + permissions). Admins have
  /// every permission; managers have only the permissions listed in
  /// their admins doc (v1.4 §5.10). Returns null when not signed in.
  Future<Map<String, dynamic>?> currentAdminProfile() async {
    final uid = auth.currentUser?.uid;
    if (uid == null) return null;
    final snap = await db.collection('admins').doc(uid).get();
    return snap.data();
  }

  Future<String?> currentUserRole() async {
    final profile = await currentAdminProfile();
    return profile?['role'] as String?;
  }

  /// Client-side permission check (the UI hides what the user may not
  /// do; the FUNCTIONS re-check it server-side — the UI is not
  /// security). Admins always pass.
  Future<bool> hasPermission(String permission) async {
    final profile = await currentAdminProfile();
    if (profile == null) return false;
    if (profile['role'] == 'admin') return true;
    final permissions = profile['permissions'];
    if (permissions is Map) return permissions[permission] == true;
    if (permissions is List) return permissions.contains(permission);
    return false;
  }

  // ---- No-functions pure helpers (contract §1/§5/§6/§9) ----
  //
  // Pure logic, no Firestore — unit-tested in
  // test/no_functions_backend_test.dart. The transaction methods
  // below call these so the client logic can never drift from the
  // tested shapes.

  // Cap is 7 lines (coordinator fix 2026-11-26): the rules allow
  // 10 get() calls per operation, and the order-create rule costs
  // N+1 gets for a manual order (N product gets + the manual-role
  // get — the code get is gone, 2026-11-27, and the audit getAfter
  // left with the audit-split, M1), so a 7-line manual order uses
  // 8 gets, inside the limit with room to spare. Same cap in the
  // storefront + PC.
  static const int maxProductsPerOrder = 7;
  static const int maxQtyPerLine = 20;

  /// 24h reservation TTL (contract §5). A 'new' order older than
  /// this is expired by the lazy sweep.
  static const Duration reservationTtl = Duration(hours: 24);

  static bool isReservationExpired({
    required DateTime? createdAt,
    required DateTime now,
  }) =>
      createdAt != null && !now.isBefore(createdAt.add(reservationTtl));

  /// Merge duplicate lines by productId, summing quantities (keeps
  /// first-seen order; mirrors functions/lib/validation.js
  /// dedupeItems).
  static List<Map<String, dynamic>> dedupeManualItems(
      List<Map<String, dynamic>> items) {
    final merged = <String, Map<String, dynamic>>{};
    for (final line in items) {
      final id = ((line['productId'] ?? '') as String).trim();
      if (id.isEmpty) continue;
      final qty = ((line['qty'] ?? 0) as num).toInt();
      if (merged.containsKey(id)) {
        merged[id]!['qty'] = ((merged[id]!['qty'] ?? 0) as num).toInt() + qty;
      } else {
        merged[id] = {'productId': id, 'qty': qty};
      }
    }
    return merged.values.toList();
  }

  /// Shape validation for a manual order (contract §1 step 3).
  /// Returns an Arabic error message, or null when valid.
  static String? validateManualOrderInput({
    required String customerName,
    required String customerPhone,
    required String customerAddress,
    required List<Map<String, dynamic>> items,
  }) {
    if (customerName.trim().isEmpty) return 'اكتب اسم العميل';
    final digits = customerPhone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 10) return 'اكتب رقم موبايل صحيح';
    if (customerAddress.trim().isEmpty) return 'اكتب العنوان';
    if (items.isEmpty) return 'اختار منتج واحد على الأقل';
    final merged = dedupeManualItems(items);
    if (merged.length > maxProductsPerOrder) {
      return 'الطلب فيه منتجات أكتر من الحد المسموح (7)';
    }
    for (final line in merged) {
      final qty = ((line['qty'] ?? 0) as num).toInt();
      if (qty < 1 || qty > maxQtyPerLine) return 'الكمية لازم تكون بين 1 و 20';
    }
    return null;
  }

  /// Pricing (Technical Plan §8) — ONE canonical helper per client,
  /// identical on the storefront, here, and the PC manager. It
  /// mirrors the storefront `computePricing` exactly (same fields,
  /// same rounding, same matrix totals). All money is integer EGP.
  /// All savings are exact integer sums, never rounded: per-line
  /// saving = `(basePrice − price) × qty`, and the total sale saving
  /// is the sum of the per-line savings.
  ///
  /// [lines] are `{'price': num, 'qty': int, 'basePrice': int?}` with
  /// trusted (database) prices; a line with no `basePrice`, or with
  /// `basePrice <= price`, is not on sale. `total` is the subtotal:
  /// there is no code discount any more (the promo code was removed
  /// 2026-11-27) — only the per-product sale prices reduce the
  /// total, and they are already baked into `price`.
  ///
  /// [deliveryFee] is the snapshot of `storeSettings/settings`
  /// `.deliveryFee`. Fee-default-free (decision 2026-11-27): when
  /// no fee is set (null, or an invalid negative), delivery is FREE
  /// automatically — an unset fee behaves exactly like 0, so
  /// `deliveryFee` is 0 and `amountDue` is `total`. [feeUnset]
  /// still reports that no fee was stored, for display only; it
  /// never blocks an order any more. [freeDeliveryThreshold]
  /// (decision D3, admin setting): when set (> 0), the fee is waived
  /// (`deliveryFee` 0 stored) once the `total` reaches the threshold;
  /// absent/null/0 means no waiver.
  ///
  /// `round()` is nearest integer, halves up, for the displayed %
  /// (see [salePercent]). It is exact integer math
  /// when the subtotal is an int: `(subtotal * percent + 50) ~/ 100`
  /// — the same as the storefront's `Math.floor(x + 0.5)`.
  static ({
    List<({num saving, int? pct})> perLine,
    num baseSubtotal,
    num subtotal,
    num saleSavings,
    num total,
    int? deliveryFee,
    bool feeUnset,
    bool feeWaived,
    num? amountDue,
    num savingTotal,
    num? insteadOf,
  }) computeOrderTotals(
    List<Map<String, dynamic>> lines, {
    int? deliveryFee,
    int? freeDeliveryThreshold,
  }) {
    num baseSubtotal = 0;
    num subtotal = 0;
    num saleSavings = 0;
    final perLine = <({num saving, int? pct})>[];
    for (final line in lines) {
      final price = ((line['price'] ?? 0) as num);
      final qty = ((line['qty'] ?? 0) as num).toInt();
      final baseRaw = line['basePrice'];
      // A base at or below the price is not a sale (invalid stored
      // data normalizes to no sale, exactly like the storefront).
      final base = (baseRaw is num && baseRaw.toInt() > price)
          ? baseRaw.toInt()
          : null;
      final lineSaving = base != null ? (base - price) * qty : 0;
      baseSubtotal += (base ?? price) * qty;
      subtotal += price * qty;
      saleSavings += lineSaving;
      perLine.add((
        saving: lineSaving,
        pct: base != null
            ? salePercent(basePrice: base, price: price is int ? price : price.toInt())
            : null,
      ));
    }
    final total = subtotal;
    // Fee: unset when not an int ≥ 0; waived (0 stored) once the
    // total reaches an admin-set threshold > 0. Fee-default-free
    // (decision 2026-11-27): an unset fee is free, exactly like 0.
    final feeUnset = deliveryFee == null || deliveryFee < 0;
    final threshold = (freeDeliveryThreshold != null &&
            freeDeliveryThreshold > 0)
        ? freeDeliveryThreshold
        : null;
    final feeWaived =
        !feeUnset && threshold != null && total >= threshold;
    final effectiveFee =
        feeUnset ? 0 : (feeWaived ? 0 : deliveryFee);
    return (
      perLine: perLine,
      baseSubtotal: baseSubtotal,
      subtotal: subtotal,
      saleSavings: saleSavings,
      total: total,
      deliveryFee: effectiveFee,
      feeUnset: feeUnset,
      feeWaived: feeWaived,
      amountDue: total + effectiveFee,
      savingTotal: saleSavings,
      insteadOf: baseSubtotal + effectiveFee,
    );
  }

  /// Exact per-line sale saving (Technical Plan §8): never rounded.
  /// Zero when the line is not on sale (`basePrice` null, equal to
  /// the price, or — invalid stored data — below it).
  static num lineSaleSaving({
    required int? basePrice,
    required num price,
    required int qty,
  }) =>
      (basePrice == null || basePrice <= price)
          ? 0
          : (basePrice - price) * qty;

  /// One order line as shown on the invoice and in the share text
  /// (CUJ 7): `name × qty = price×qty`, plus the before-sale amount
  /// when the line is on sale (`basePrice > price`). Without a sale
  /// the text is exactly the old format.
  static String invoiceItemLine(Map<String, dynamic> item) {
    final name = item['name'] ?? '';
    final qty = ((item['qty'] as num?) ?? 0).toInt();
    final price = (item['price'] as num?) ?? 0;
    final baseRaw = item['basePrice'];
    final base = (baseRaw is num) ? baseRaw.toInt() : null;
    final line = '$name × $qty = ${(price * qty).toStringAsFixed(0)} ج.م';
    if (base == null || base <= price) return line;
    return '$line (قبل الخصم: ${(base * qty).toStringAsFixed(0)} ج.م)';
  }

  /// The money lines of an order invoice (CUJ 7), in display order,
  /// mirroring the PC invoice: products total, sale savings, code
  /// discount (legacy orders only), delivery fee, amount due. The
  /// promo code was removed 2026-11-27, so new orders never carry
  /// code fields — the code line appears only when a pre-removal
  /// order still has `discountCode`/`discountAmount`, exactly like
  /// the PC invoice (`خصم الكود X (CODE)`), so its lines add up.
  /// `amountDue` falls back to `total` when the order predates it.
  static List<String> invoiceMoneyLines(Map<String, dynamic> data) {
    final total = (data['total'] as num?) ?? 0;
    final saleSavings = (data['saleSavings'] as num?) ?? 0;
    final fee = data['deliveryFee'];
    final due = (data['amountDue'] as num?) ?? total;
    final lines = <String>[
      'الإجمالي: ${total.toStringAsFixed(0)} ج.م',
    ];
    if (saleSavings > 0) {
      lines.add('وفّرت من العرض: ${saleSavings.toStringAsFixed(0)} ج.م');
    }
    final codeAmountRaw = data['discountAmount'];
    final codeAmount =
        codeAmountRaw is num ? codeAmountRaw : null;
    if (codeAmount != null && codeAmount > 0) {
      final code = (data['discountCode'] as String?)?.trim();
      lines.add(code != null && code.isNotEmpty
          ? 'خصم الكود ${codeAmount.toStringAsFixed(0)} ج.م ($code)'
          : 'خصم الكود ${codeAmount.toStringAsFixed(0)} ج.م');
    }
    if (fee != null) {
      final feeNum = fee as num;
      lines.add(feeNum == 0
          ? 'رسوم التوصيل: مجاني'
          : 'رسوم التوصيل: ${feeNum.toStringAsFixed(0)} ج.م');
    }
    lines.add('المبلغ المستحق: ${due.toStringAsFixed(0)} ج.م');
    return lines;
  }

  /// Rounded display % for one product, or null when there is no
  /// sale or when the badge must be suppressed (Technical Plan §8 /
  /// N3, mirroring the storefront `salePercent` exactly). The % is
  /// nearest whole percent, halves up, display-only, derived at
  /// render time, never stored, never used in any total. A customer
  /// multiplying a displayed % by the base must never find a 1 EGP
  /// discrepancy, so when the rounded % × base ≠ the exact saving
  /// the badge is suppressed and only "وفّر X" is shown — e.g. base
  /// 199 → 149: the computed % is 25, but 25% × 199 = 49.75 ≠ 50,
  /// so this returns null, NOT 25.
  static int? salePercent({required int basePrice, required int price}) {
    if (basePrice <= 0 || basePrice <= price) return null;
    // round((basePrice - price) * 100 / basePrice), halves up,
    // exact integer math: ((saving * 200) + base) ~/ (base * 2).
    final pct =
        ((basePrice - price) * 200 + basePrice) ~/ (basePrice * 2);
    if (pct * basePrice != (basePrice - price) * 100) return null;
    return pct;
  }

  /// Whether a product is live on sale (Model P): a real base price
  /// strictly above the charged price. Equal means NO sale, never a
  /// 0% badge.
  static bool isOnSale({required int? basePrice, required num price}) =>
      basePrice != null && basePrice > price;

  /// Cross-field product-form validation (Technical Plan §9):
  /// `basePrice == null || basePrice >= price`, both positive
  /// integers. Returns an Arabic error message, or null when valid.
  /// `basePrice == price` is valid input — the caller normalizes it
  /// to no sale (clears the field).
  static String? validateProductPrices({
    required int price,
    int? basePrice,
  }) {
    if (price <= 0) return 'السعر لازم يكون أكبر من صفر';
    if (basePrice != null && basePrice <= 0) {
      return 'السعر قبل الخصم لازم يكون أكبر من صفر';
    }
    if (basePrice != null && basePrice < price) {
      return 'السعر قبل الخصم لازم يكون أكبر من أو يساوي السعر';
    }
    return null;
  }

  /// What happens to `discountSetAt` on a product save (B5): set
  /// when a discount is first saved, cleared when removed;
  /// re-saving a different discounted price does NOT reset it.
  static DiscountSetAtAction resolveDiscountSetAt({
    required DateTime? existing,
    required bool hasDiscount,
  }) {
    if (!hasDiscount) return DiscountSetAtAction.clear;
    if (existing != null) return DiscountSetAtAction.keep;
    return DiscountSetAtAction.setNow;
  }

  /// Whole days since the discount was set (B5 staleness signal
  /// "خصم نشط منذ X يوم"). Null when there is no stamp.
  static int? discountAgeDays(DateTime? setAt, {DateTime? now}) {
    if (setAt == null) return null;
    final days = (now ?? DateTime.now()).difference(setAt).inDays;
    return days < 0 ? 0 : days;
  }

  /// Delivery-fee settings (Technical Plan §2 + decision D3) read
  /// from `storeSettings/settings`: `deliveryFee` (int ≥ 0; null =
  /// UNSET at parse level — the totals layer treats an unset fee
  /// as free, fee-default-free decision 2026-11-27) and the
  /// admin-set free-delivery threshold `freeDeliveryThreshold`
  /// (null = no threshold; a stored 0 is also no waiver, exactly
  /// like the storefront reads it).
  static ({int? deliveryFee, int? freeDeliveryThreshold})
      parseDeliveryFeeSettings(Map<String, dynamic>? data) {
    final d = data ?? {};
    final feeRaw = d['deliveryFee'];
    final thresholdRaw = d['freeDeliveryThreshold'];
    final fee = feeRaw is num ? feeRaw.toInt() : null;
    final threshold =
        thresholdRaw is num ? thresholdRaw.toInt() : null;
    return (
      deliveryFee: (fee != null && fee >= 0) ? fee : null,
      freeDeliveryThreshold:
          (threshold != null && threshold > 0) ? threshold : null,
    );
  }

  /// The fixed delivery fee (Technical Plan §9 + decision D3), set
  /// from either admin app. [deliveryFee] is integer EGP ≥ 0
  /// (0 = free delivery). [freeDeliveryThreshold] is optional:
  /// an integer ≥ 0 — 0 means no waiver; null (empty field) clears
  /// the threshold, storing the field absent. Recorded in the audit
  /// sensitive map (`deliveryFee`) and in `docIds` like any other
  /// changed settings field.
  Future<void> setDeliveryFee({
    required int deliveryFee,
    int? freeDeliveryThreshold,
  }) async {
    _requireInit();
    if (deliveryFee < 0) {
      throw BackendException('رسوم التوصيل لازم تكون صفر أو أكتر');
    }
    if (freeDeliveryThreshold != null && freeDeliveryThreshold < 0) {
      throw BackendException('حد التوصيل المجاني لازم يكون صفر أو أكتر');
    }
    await _auditedBatch(
      writes: {
        'storeSettings/settings': {
          'deliveryFee': deliveryFee,
          // Empty clears the threshold: the field is stored absent,
          // not null — the storefront reads absent/null/0 as no waiver.
          'freeDeliveryThreshold': freeDeliveryThreshold ??
              FieldValue.delete(),
        },
      },
      sensitive: {
        'storeSettings/settings': {'deliveryFee': deliveryFee},
      },
      operation: 'settings_delivery_fee',
    );
  }

  /// The recorded cost of a product, from its inventory document
  /// (decision D4). Null when the product has no recorded cost —
  /// unknown cost is not below cost, so no below-cost warning.
  Future<int?> productCostPrice(String productId) async {
    _requireInit();
    final snap = await db.collection('inventory').doc(productId).get();
    final raw = snap.data()?['costPrice'];
    if (raw is! num) return null;
    final cost = raw.toInt();
    return cost > 0 ? cost : null;
  }

  /// A whole-number price/total stored as int, not double: the new
  /// rules require `price is int`, and a Dart double 100.0 is stored
  /// as a double and fails that check. Fractional values pass through.
  static num wholeNum(num value) =>
      value is double && value == value.truncateToDouble()
          ? value.toInt()
          : value;

  /// The insufficient-stock message (contract §1 step 5): the UI
  /// shows the available count only.
  static String insufficientStockMessage({
    required String productName,
    required int available,
  }) =>
      'المتاح دلوقتي من $productName هو $available بس';

  /// Shape validation for a one-way complaint (contract §3/§6:
  /// exact keys name/email/phone/message/createdAt).
  static String? validateFeedbackInput({
    required String name,
    required String email,
    required String phone,
    required String message,
  }) {
    if (name.trim().isEmpty || name.trim().length > 100) {
      return 'اكتب الاسم (بحد أقصى 100 حرف)';
    }
    final mail = email.trim();
    if (mail.length > 100 || (mail.isNotEmpty && !mail.contains('@'))) {
      return 'اكتب إيميل صحيح';
    }
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 10 || digits.length > 15) {
      return 'اكتب رقم موبايل صحيح';
    }
    final msg = message.trim();
    if (msg.length < 10 || msg.length > 2000) {
      return 'اكتب الشكوى (من 10 لـ 2000 حرف)';
    }
    return null;
  }

  /// WhatsApp-order settings (contract §7/§9): read from
  /// storeSettings/settings, defaults false / '201557887719'.
  static const String defaultWhatsAppNumber = '201557887719';

  static ({bool enabled, String number}) parseWhatsAppSettings(
      Map<String, dynamic>? data) {
    final d = data ?? {};
    final number = ((d['whatsappNumber'] as String?) ?? '').trim();
    return (
      enabled: (d['whatsappOrderEnabled'] as bool?) ?? false,
      number: number.isEmpty ? defaultWhatsAppNumber : number,
    );
  }


  /// Signs in with an email OR a phone number + password.
  Future<UserCredential> signIn(String identifier, String password) async {
    _requireInit();
    try {
      final kind = resolveIdentifierKind(identifier);
      late final String email;
      if (kind == IdentifierKind.email) {
        email = identifier.trim();
      } else if (kind == IdentifierKind.phone) {
        final normalized = normalizeEgyptPhone(identifier)!;
        final doc = await db.collection('phones').doc(phoneLookupKey(normalized)).get();
        final found = doc.data()?['email'] as String?;
        if (found == null || found.isEmpty) {
          throw BackendException('رقم الموبايل ده مش مسجل كحساب أدمن');
        }
        email = found;
      } else {
        throw BackendException('الإيميل أو رقم الموبايل مش صحيح');
      }
      final cred = await auth.signInWithEmailAndPassword(email: email, password: password);
      Diagnostics.instance.log('Signed in as $email');
      return cred;
    } on BackendException {
      rethrow;
    } on FirebaseAuthException catch (e) {
      Diagnostics.instance.log('Sign-in failed: ${e.code}');
      throw BackendException(_friendlyAuthError(e));
    } catch (e) {
      Diagnostics.instance.log('Sign-in failed: $e');
      throw BackendException('تعذر تسجيل الدخول: $e');
    }
  }

  Future<void> _writeAdminProfile({
    required String uid,
    required String email,
    required String phone,
  }) async {
    final normalized = normalizeEgyptPhone(phone);
    await db.collection('admins').doc(uid).set({
      'email': email,
      'phone': phone,
      'role': 'admin',
      'createdAt': FieldValue.serverTimestamp(),
    });
    if (normalized != null) {
      await db.collection('phones').doc(phoneLookupKey(normalized)).set({
        'email': email,
        'uid': uid,
      });
    }
  }

  /// First admin account (primary app, used right after the invite gate).
  Future<UserCredential> createFirstAdmin({
    required String email,
    required String phone,
    required String password,
  }) async {
    _requireInit();
    try {
      final cred = await auth.createUserWithEmailAndPassword(email: email, password: password);
      await _writeAdminProfile(uid: cred.user!.uid, email: email, phone: phone);
      Diagnostics.instance.log('First admin created: $email');
      return cred;
    } on FirebaseAuthException catch (e) {
      Diagnostics.instance.log('Create admin failed: ${e.code}');
      throw BackendException(_friendlyAuthError(e));
    }
  }

  /// Team member account via a SECONDARY FirebaseApp, so the signed-in
  /// admin is never signed out by creating a member account.
  Future<void> createMemberAccount({
    required String email,
    required String phone,
    required String password,
  }) async {
    _requireInit();
    FirebaseApp? secondary;
    try {
      secondary = await Firebase.initializeApp(
        name: 'secondary',
        options: StoreFirebaseOptions.options,
      );
      final secondaryAuth = FirebaseAuth.instanceFor(app: secondary);
      final cred = await secondaryAuth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      await _writeAdminProfile(uid: cred.user!.uid, email: email, phone: phone);
      Diagnostics.instance.log('Team member created: $email');
    } on FirebaseAuthException catch (e) {
      Diagnostics.instance.log('Create member failed: ${e.code}');
      throw BackendException(_friendlyAuthError(e));
    } finally {
      if (secondary != null) {
        await secondary.delete();
      }
    }
  }

  Future<void> signOut() async {
    await auth.signOut();
    try {
      await GoogleSignIn.instance.disconnect();
    } catch (_) {
      // Not signed in with Google — nothing to disconnect.
    }
    Diagnostics.instance.log('Signed out');
  }

  /// Sends a password-reset email to [email] (email identifiers only).
  Future<void> sendPasswordReset(String email) async {
    _requireInit();
    try {
      await auth.sendPasswordResetEmail(email: email.trim());
      Diagnostics.instance.log('Password reset sent to $email');
    } on FirebaseAuthException catch (e) {
      Diagnostics.instance.log('Password reset failed: ${e.code}');
      throw BackendException(_friendlyAuthError(e));
    }
  }

  /// "Remember me" preference for the sign-in screen. Stored only as a
  /// preference: session persistence itself stays Firebase's (persist
  /// until explicit sign-out) and is never weakened by this flag.
  Future<bool> getRememberMe() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('remember_me') ?? false;
  }

  Future<void> setRememberMe(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('remember_me', value);
  }

  /// Google sign-in for admins, with the admin gate enforced: after a
  /// successful Google sign-in, the admins doc is checked; a Google
  /// account that is NOT an admin is signed out immediately and the
  /// sign-in is rejected. Never bypasses the invite gate order — the
  /// gate + account-choice screens still come first in the app flow.
  Future<UserCredential> signInWithGoogle() async {
    _requireInit();
    try {
      final googleUser = await GoogleSignIn.instance.authenticate();
      final googleAuth = googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );
      final userCred = await auth.signInWithCredential(credential);
      final uid = userCred.user!.uid;
      final adminDoc = await db.collection('admins').doc(uid).get();
      final role = adminDoc.data()?['role'] as String?;
      if (role != 'admin') {
        await auth.signOut();
        try {
          await GoogleSignIn.instance.disconnect();
        } catch (_) {}
        Diagnostics.instance.log('Google sign-in rejected: not an admin');
        throw BackendException('هذا الحساب ليس حساب أدمن');
      }
      Diagnostics.instance.log('Google sign-in accepted as admin');
      return userCred;
    } on BackendException {
      rethrow;
    } on FirebaseAuthException catch (e) {
      Diagnostics.instance.log('Google sign-in failed: ${e.code}');
      throw BackendException(_friendlyAuthError(e));
    } catch (e) {
      Diagnostics.instance.log('Google sign-in failed: $e');
      throw BackendException('تعذر تسجيل الدخول بـ Google: $e');
    }
  }

  // ---- Storefront content ----

  Stream<DocumentSnapshot<Map<String, dynamic>>> brandStream() =>
      db.collection('storeSettings').doc('settings').snapshots();

  Future<void> setBrand({required String brandName, String tagline = ''}) async {
    _requireInit();
    await _auditedBatch(
      writes: {
        'storeSettings/settings': {'brandName': brandName, 'tagline': tagline},
      },
      sensitive: const {},
      operation: 'update',
    );
  }

  /// WhatsApp-order settings (contract §7/§9): the toggle + number
  /// the storefront reads at boot. Defaults live in
  /// parseWhatsAppSettings (false / '201557887719').
  Future<void> setWhatsAppOrder({
    required bool enabled,
    required String number,
  }) async {
    _requireInit();
    final trimmed = number.trim();
    if (trimmed.isEmpty || !RegExp(r'^\d{10,15}$').hasMatch(trimmed)) {
      throw BackendException('اكتب رقم واتساب صحيح (أرقام بس، بكود الدولة)');
    }
    await _auditedBatch(
      writes: {
        'storeSettings/settings': {
          'whatsappOrderEnabled': enabled,
          'whatsappNumber': trimmed,
        },
      },
      sensitive: const {},
      operation: 'update',
    );
  }

  /// v1.1.2 scope #8: the homepage editor's document. The website
  /// builder reads storeSettings/homepage with an exact field shape
  /// (see lib/core/homepage.dart) — this writes the FULL doc with
  /// set() (no merge) so the stored shape is always exactly what
  /// the editor produced. Called ONLY from the editor's Save button;
  /// previews and Cancel never touch Firestore.
  ///
  /// Phase 2: the stored doc is the eight contract fields PLUS the
  /// audit metadata the rules require (operationId + updatedAt) —
  /// the website builder reads only the contract fields and ignores
  /// the metadata, so the exact-shape contract still holds for it.
  Stream<DocumentSnapshot<Map<String, dynamic>>> homepageStream() =>
      db.collection('storeSettings').doc('homepage').snapshots();

  Future<void> setHomepage(Map<String, dynamic> doc) async {
    _requireInit();
    await _auditedBatch(
      writes: {'storeSettings/homepage': Map<String, dynamic>.from(doc)},
      sensitive: const {},
      operation: 'update',
      merge: false,
    );
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> categoriesStream() =>
      db.collection('categories').orderBy('createdAt').snapshots();

  Future<void> addCategory(String name) async {
    _requireInit();
    final ref = db.collection('categories').doc();
    await _auditedBatch(
      writes: {
        'categories/${ref.id}': {'name': name, 'createdAt': FieldValue.serverTimestamp()},
      },
      sensitive: const {},
      operation: 'create',
    );
  }

  Future<void> renameCategory(String id, String name) async {
    _requireInit();
    await _auditedBatch(
      writes: {'categories/$id': {'name': name}},
      sensitive: const {},
      operation: 'update',
    );
  }

  Future<void> deleteCategory(String id) async {
    _requireInit();
    final products =
        await db.collection('products').where('categoryId', isEqualTo: id).limit(1).get();
    if (products.docs.isNotEmpty) {
      throw BackendException('القسم ده فيه منتجات — انقلها لقسم تاني الأول أو امسحها');
    }
    await _auditedDelete(
      collection: 'categories',
      docId: id,
      changedFields: const ['name'],
    );
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> productsStream() =>
      db.collection('products').orderBy('createdAt').snapshots();

  /// Pricing (Model P, Technical Plan §1/§9): `price` is the
  /// effective (charged) price; [ProductData.basePrice] is the
  /// display-only anchor. An empty base price, or one equal to the
  /// price, means NO sale — the field is written null, never a 0%
  /// badge. The write is a merge (`_auditedBatch` uses
  /// `SetOptions(merge: true)`), so fields the form does not own
  /// stay untouched; `basePrice` itself is always owned by this
  /// form, so it is always written (value or null).
  ///
  /// `discountSetAt` (B5): set on the first discounted save, kept
  /// on re-saves, cleared when the discount is removed.
  ///
  /// [belowCostConfirmed] (decision D4): true only when the admin
  /// confirmed a below-cost price a second time, on a separate tap;
  /// it is recorded in the audit entry's top-level new values.
  Future<void> saveProduct(ProductData p,
      {bool belowCostConfirmed = false}) async {
    _requireInit();
    // wholeNum: the new rules require `price is int` — a stored
    // double 100.0 fails that check, so whole EGP prices are stored
    // as ints (fractional prices, if any, stay doubles).
    final data = <String, dynamic>{
      'name': p.name,
      'price': wholeNum(p.price),
      'description': p.description,
      'categoryId': p.categoryId,
      'images': p.images.map((img) => img.toMap()).toList(),
    };
    // Model P: basePrice null, or equal to price, means NO sale.
    final hasDiscount = isOnSale(basePrice: p.basePrice, price: p.price);
    data['basePrice'] = hasDiscount ? wholeNum(p.basePrice!) : null;
    switch (resolveDiscountSetAt(
        existing: p.discountSetAt, hasDiscount: hasDiscount)) {
      case DiscountSetAtAction.setNow:
        data['discountSetAt'] = FieldValue.serverTimestamp();
      case DiscountSetAtAction.clear:
        data['discountSetAt'] = null;
      case DiscountSetAtAction.keep:
        break; // merge write: the stored stamp stays untouched.
    }
    final id = p.id.isEmpty ? db.collection('products').doc().id : p.id;
    if (p.id.isEmpty) {
      data['createdAt'] = FieldValue.serverTimestamp();
      // A brand-new product has no inventory doc yet (0 available),
      // so it starts out of stock — otherwise the storefront treats
      // a missing inStock flag as available.
      data['inStock'] = false;
    }
    await _auditedBatch(
      writes: {'products/$id': data},
      sensitive: {
        'products/$id': {
          'price': p.price,
          'basePrice': hasDiscount ? wholeNum(p.basePrice!) : null,
          if (p.id.isEmpty) 'inStock': false,
        },
      },
      operation: p.id.isEmpty ? 'create' : 'update',
      topNewValues: belowCostConfirmed
          ? const {'belowCostConfirmed': true}
          : const {},
    );
  }

  Future<void> deleteProduct(String id) async {
    _requireInit();
    await _auditedDelete(
      collection: 'products',
      docId: id,
      changedFields: const ['name', 'price', 'description', 'categoryId', 'images'],
    );
  }

  /// Featured toggle (contract §9): the storefront lists every
  /// product with featured == true first. Audited write; `featured`
  /// is not a sensitive field, so no new value is recorded.
  Future<void> setProductFeatured(String id, bool featured) async {
    _requireInit();
    await _auditedBatch(
      writes: {'products/$id': {'featured': featured}},
      sensitive: const {},
      operation: 'update',
    );
  }

  /// Live recent-orders stream for the dashboard preview (limit 100).
  /// The Orders tab paginates instead — see fetchOrdersPage().
  Stream<QuerySnapshot<Map<String, dynamic>>> ordersStream() => db
      .collection('orders')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  /// One page of orders, newest first. Returns the docs + the cursor
  /// for the next page (null when there is no next page). The Orders
  /// tab uses this instead of the fixed-limit stream (v1.4 §5.2).
  Future<({List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, QueryDocumentSnapshot<Map<String, dynamic>>? lastDoc})> fetchOrdersPage({
    QueryDocumentSnapshot<Map<String, dynamic>>? startAfter,
    int pageSize = 20,
  }) async {
    _requireInit();
    var query = db
        .collection('orders')
        .orderBy('createdAt', descending: true)
        .limit(pageSize);
    if (startAfter != null) query = query.startAfterDocument(startAfter);
    final snap = await query.get();
    return (
      docs: snap.docs,
      lastDoc: snap.docs.length < pageSize ? null : snap.docs.last,
    );
  }

  /// The unified order state machine (v1.4 Decision 23). The rules
  /// enforce it too — this client-side check only gives a clear
  /// message before the write; the rules are the final guard.
  static const Map<String, List<String>> orderTransitions = {
    'new': ['accepted', 'cancelled', 'expired'],
    'accepted': ['preparing', 'cancelled'],
    'preparing': ['ready', 'cancelled'],
    'ready': ['in_transit', 'cancelled'],
    'in_transit': ['delivered'],
    'delivered': [],
    'cancelled': ['new'],
    'expired': [],
  };

  static bool isAllowedOrderTransition(String from, String to) =>
      (orderTransitions[from] ?? []).contains(to);

  static const Map<String, String> orderStatusLabels = {
    'new': 'جديد',
    'accepted': 'مقبول',
    'preparing': 'بيتجهز',
    'ready': 'جاهز',
    'in_transit': 'في الطريق',
    'delivered': 'تم التوصيل',
    'cancelled': 'ملغي',
    'expired': 'منتهي',
  };

  /// Moves an order to [status]. Stock-moving transitions (cancel →
  /// release the reservation; deliver → release + deduct from stock;
  /// expire → release, sweep only) run inside ONE transaction that
  /// updates inventory, inStock, movements, the order, and the audit
  /// entry atomically (v1.4 §6.3). Reopen (cancelled → new, contract
  /// §2) is now a STOCK-MOVING transaction too: it re-checks
  /// availability per line, re-reserves, and deletes the cancel stamp
  /// (cancelledAt + cancelReason) — the audit docIds are derived from
  /// the real write keys, including the deleted fields. Pure status
  /// steps (accept → prepare → ready → in transit) are an audited
  /// batch on the order alone. The lifecycle timestamps
  /// (acceptedAt / deliveredAt / cancelledAt) are stamped with the
  /// transition; cancelReason is set on cancel/expire.
  Future<void> setOrderStatus(String id, String status, {String? reason}) async {
    _requireInit();
    final orderRef = db.collection('orders').doc(id);
    final snap = await orderRef.get();
    final order = snap.data();
    if (order == null) throw BackendException('الطلب مش موجود');
    final from = (order['status'] ?? '') as String;
    if (!isAllowedOrderTransition(from, status)) {
      throw BackendException('مينفعش تنقل الطلب من ${orderStatusLabels[from] ?? from} لـ ${orderStatusLabels[status] ?? status}');
    }
    if (status == 'cancelled' || status == 'delivered' || status == 'expired') {
      await _stockMovingTransition(
        id,
        status,
        from: from,
        reason: reason,
        actorUid: auth.currentUser?.uid ?? '',
        actorName: auth.currentUser?.email ?? '',
        source: 'flutter_admin',
      );
      Diagnostics.instance.log('Order $id: $from -> $status (stock moved)');
      return;
    }
    if (from == 'cancelled' && status == 'new') {
      await _reopenTransition(id);
      Diagnostics.instance.log('Order $id: cancelled -> new (re-reserved)');
      return;
    }
    final orderUpdate = <String, dynamic>{'status': status};
    if (status == 'accepted') orderUpdate['acceptedAt'] = FieldValue.serverTimestamp();
    await _auditedBatch(
      writes: {'orders/$id': orderUpdate},
      sensitive: {'orders/$id': {'status': status}},
      operation: 'status_change',
      oldValues: {'orders/$id': {'status': from}},
      topNewValues: {'status': status},
    );
    Diagnostics.instance.log('Order $id: $from -> $status');
  }

  /// The stock-moving transaction shared by cancel / deliver /
  /// expire (contract §2, §5). [expireBefore] is set only by the lazy
  /// sweep: inside the transaction the order is re-checked (still
  /// 'new' AND createdAt + 24h <= [expireBefore]) and the transition
  /// is silently skipped when it no longer applies — idempotent by
  /// construction. Returns true when the transition ran.
  Future<bool> _stockMovingTransition(
    String id,
    String status, {
    required String from,
    String? reason,
    required String actorUid,
    required String actorName,
    required String source,
    DateTime? expireBefore,
  }) async {
    var ran = false;
    final orderRef = db.collection('orders').doc(id);
    await db.runTransaction((tx) async {
      final freshSnap = await tx.get(orderRef);
      final fresh = freshSnap.data();
      if (fresh == null) throw BackendException('الطلب مش موجود');
      if (expireBefore != null) {
        if ((fresh['status'] ?? '') != 'new') return;
        final createdAt = (fresh['createdAt'] as Timestamp?)?.toDate();
        if (!isReservationExpired(createdAt: createdAt, now: expireBefore)) {
          return;
        }
      } else if ((fresh['status'] ?? '') != from) {
        throw BackendException('الطلب اتغير من حد تاني — حدّث الصفحة وحاول تاني');
      }
      final auditRef = db.collection('audit').doc();
      final opId = auditRef.id;
      final now = FieldValue.serverTimestamp();
      // The order write (built first, below) also stamps the
      // lifecycle fields — deliveredAt on deliver, cancelledAt +
      // cancelReason on cancel/expire. The audit's docIds entry
      // MUST list every key the write actually sets: the rules
      // check diff().affectedKeys() coverage, so a hard-coded
      // ['status', 'operationId', 'updatedAt'] denies the cancel /
      // deliver write even with the new rules deployed (the
      // lifecycle fields are new keys, hence affected). Deriving
      // the list from the real write keeps the two in sync.
      final orderUpdate = <String, dynamic>{
        'status': status,
        'operationId': opId,
        'updatedAt': now,
      };
      if (status == 'delivered') orderUpdate['deliveredAt'] = now;
      if (status == 'cancelled' || status == 'expired') {
        orderUpdate['cancelledAt'] = now;
        orderUpdate['cancelReason'] = reason ??
            (status == 'expired'
                ? 'reservation_expired'
                : 'cancelled_by_admin');
      }
      final orderChangedFields = orderUpdate.keys.toList();
      final docIds = <String, List<String>>{
        'orders/$id': orderChangedFields,
      };
      final newValuesByDoc = <String, Map<String, dynamic>>{
        'orders/$id': {'status': status},
      };
      final documents = <Map<String, dynamic>>[];
      final items = (fresh['items'] as List<dynamic>? ?? []);
      for (final line in items) {
        final m = line as Map<String, dynamic>;
        final productId = (m['productId'] ?? '') as String;
        final qty = ((m['qty'] ?? 0) as num).toInt();
        if (productId.isEmpty || qty <= 0) continue;
        final invRef = db.collection('inventory').doc(productId);
        final invSnap = await tx.get(invRef);
        final inv = invSnap.data() ?? {};
        final stock = ((inv['stock'] ?? 0) as num).toInt();
        final reserved = ((inv['reserved'] ?? 0) as num).toInt();
        final newReserved = (reserved - qty).clamp(0, 1 << 30);
        final newStock = status == 'delivered' ? (stock - qty).clamp(0, 1 << 30) : stock;
        final newAvailable = newStock - newReserved;
        tx.set(invRef, {
          'reserved': newReserved,
          'stock': newStock,
          'operationId': opId,
          'updatedAt': now,
        }, SetOptions(merge: true));
        tx.set(db.collection('products').doc(productId), {
          'inStock': newAvailable > 0,
          'operationId': opId,
          'updatedAt': now,
        }, SetOptions(merge: true));
        tx.set(db.collection('movements').doc(), {
          'productId': productId,
          'type': status == 'delivered'
              ? 'order_deliver'
              : status == 'expired'
                  ? 'reservation_expire'
                  : 'order_cancel',
          'qty': status == 'delivered' ? -qty : qty,
          'orderId': id,
          'source': source,
          'actorUid': actorUid,
          'createdAt': now,
        });
        docIds['inventory/$productId'] = ['reserved', 'stock', 'operationId', 'updatedAt'];
        docIds['products/$productId'] = ['inStock', 'operationId', 'updatedAt'];
        newValuesByDoc['inventory/$productId'] = {'stock': newStock, 'reserved': newReserved};
        newValuesByDoc['products/$productId'] = {'inStock': newAvailable > 0};
        documents.add({
          'collection': 'inventory',
          'docId': productId,
          'changedFields': ['reserved', 'stock'],
          'oldValues': {'stock': stock, 'reserved': reserved},
          'newValues': {'stock': newStock, 'reserved': newReserved},
        });
        documents.add({
          'collection': 'products',
          'docId': productId,
          'changedFields': ['inStock'],
          'oldValues': {},
          'newValues': {'inStock': newAvailable > 0},
        });
      }
      tx.set(orderRef, orderUpdate, SetOptions(merge: true));
      documents.insert(0, {
        'collection': 'orders',
        'docId': id,
        'changedFields': orderChangedFields,
        'oldValues': {'status': from},
        'newValues': {'status': status},
      });
      tx.set(auditRef, {
        'operationId': opId,
        'actor': actorUid,
        'actorName': actorName,
        'timestamp': now,
        'collection': 'orders',
        'docId': id,
        'operation': 'status_change',
        'changedFields': docIds.values.expand((e) => e).toSet().toList(),
        'oldValues': {'status': from},
        'newValues': {'status': status},
        'docIds': docIds,
        'newValuesByDoc': newValuesByDoc,
        'documents': documents,
        'source': source,
      });
      ran = true;
    });
    return ran;
  }

  /// Reopen (cancelled → new, contract §2): a STOCK-MOVING
  /// transaction. Reads the order + inventory per line, throws with
  /// the product name + available count when any line is short,
  /// re-reserves, refreshes products.inStock, writes
  /// 'reopen_reserve' movements, sets status 'new' and DELETES
  /// cancelledAt + cancelReason. The audit docIds are derived from
  /// the real write keys, including the deleted fields.
  Future<void> _reopenTransition(String id) async {
    final orderRef = db.collection('orders').doc(id);
    await db.runTransaction((tx) async {
      final freshSnap = await tx.get(orderRef);
      final fresh = freshSnap.data();
      if (fresh == null) throw BackendException('الطلب مش موجود');
      if ((fresh['status'] ?? '') != 'cancelled') {
        throw BackendException('الطلب اتغير من حد تاني — حدّث الصفحة وحاول تاني');
      }
      final auditRef = db.collection('audit').doc();
      final opId = auditRef.id;
      final now = FieldValue.serverTimestamp();
      final uid = auth.currentUser?.uid ?? '';
      final email = auth.currentUser?.email ?? '';
      final docIds = <String, List<String>>{};
      final newValuesByDoc = <String, Map<String, dynamic>>{};
      final documents = <Map<String, dynamic>>[];
      final items = (fresh['items'] as List<dynamic>? ?? []);
      for (final line in items) {
        final m = line as Map<String, dynamic>;
        final productId = (m['productId'] ?? '') as String;
        final qty = ((m['qty'] ?? 0) as num).toInt();
        if (productId.isEmpty || qty <= 0) continue;
        final invRef = db.collection('inventory').doc(productId);
        final invSnap = await tx.get(invRef);
        final inv = invSnap.data() ?? {};
        final stock = ((inv['stock'] ?? 0) as num).toInt();
        final reserved = ((inv['reserved'] ?? 0) as num).toInt();
        final available = stock - reserved;
        if (qty > available) {
          final productSnap = await tx.get(db.collection('products').doc(productId));
          final name = ((productSnap.data() ?? {})['name'] ?? productId) as String;
          throw BackendException(insufficientStockMessage(
            productName: name,
            available: available < 0 ? 0 : available,
          ));
        }
        final newReserved = reserved + qty;
        final newAvailable = stock - newReserved;
        tx.set(invRef, {
          'reserved': newReserved,
          'stock': stock,
          'operationId': opId,
          'updatedAt': now,
        }, SetOptions(merge: true));
        tx.set(db.collection('products').doc(productId), {
          'inStock': newAvailable > 0,
          'operationId': opId,
          'updatedAt': now,
        }, SetOptions(merge: true));
        tx.set(db.collection('movements').doc(), {
          'productId': productId,
          'type': 'reopen_reserve',
          'qty': -qty,
          'orderId': id,
          'source': 'flutter_admin',
          'actorUid': uid,
          'createdAt': now,
        });
        docIds['inventory/$productId'] = ['reserved', 'stock', 'operationId', 'updatedAt'];
        docIds['products/$productId'] = ['inStock', 'operationId', 'updatedAt'];
        newValuesByDoc['inventory/$productId'] = {'stock': stock, 'reserved': newReserved};
        newValuesByDoc['products/$productId'] = {'inStock': newAvailable > 0};
        documents.add({
          'collection': 'inventory',
          'docId': productId,
          'changedFields': ['reserved', 'stock'],
          'oldValues': {'stock': stock, 'reserved': reserved},
          'newValues': {'stock': stock, 'reserved': newReserved},
        });
        documents.add({
          'collection': 'products',
          'docId': productId,
          'changedFields': ['inStock'],
          'oldValues': {},
          'newValues': {'inStock': newAvailable > 0},
        });
      }
      final orderUpdate = <String, dynamic>{
        'status': 'new',
        'operationId': opId,
        'updatedAt': now,
        'cancelledAt': FieldValue.delete(),
        'cancelReason': FieldValue.delete(),
      };
      final orderChangedFields = orderUpdate.keys.toList();
      docIds['orders/$id'] = orderChangedFields;
      newValuesByDoc['orders/$id'] = {'status': 'new'};
      tx.set(orderRef, orderUpdate, SetOptions(merge: true));
      documents.insert(0, {
        'collection': 'orders',
        'docId': id,
        'changedFields': orderChangedFields,
        'oldValues': {'status': 'cancelled'},
        'newValues': {'status': 'new'},
      });
      tx.set(auditRef, {
        'operationId': opId,
        'actor': uid,
        'actorName': email,
        'timestamp': now,
        'collection': 'orders',
        'docId': id,
        'operation': 'status_change',
        'changedFields': docIds.values.expand((e) => e).toSet().toList(),
        'oldValues': {'status': 'cancelled'},
        'newValues': {'status': 'new'},
        'docIds': docIds,
        'newValuesByDoc': newValuesByDoc,
        'documents': documents,
        'source': 'flutter_admin',
      });
    });
  }

  /// Lazy sweep (contract §5, replaces the scheduled sweep):
  /// releases expired 'new' orders (createdAt older than 24h).
  /// Runs on app boot (AdminShell), when the orders list loads, and
  /// every 30 minutes while the app is open. Best-effort: never
  /// throws to the UI, every failure is logged. Returns how many
  /// orders were expired. The query filters status == 'new' only
  /// (single-field index) and the TTL check happens client-side +
  /// again inside each transaction, so no composite index is needed.
  bool _sweepRunning = false;

  Future<int> runLazySweep() async {
    if (!initialized || auth.currentUser == null) return 0;
    if (_sweepRunning) return 0;
    _sweepRunning = true;
    try {
      final snap = await db
          .collection('orders')
          .where('status', isEqualTo: 'new')
          .limit(100)
          .get();
      final now = DateTime.now();
      var expired = 0;
      for (final doc in snap.docs) {
        final data = doc.data();
        final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
        if (!isReservationExpired(createdAt: createdAt, now: now)) continue;
        try {
          // The audit actor MUST be the signed-in admin's uid, not
          // the literal 'sweep': the rules' audit entry requires
          // actor == request.auth.uid, so a 'sweep' actor denies
          // the whole expire transaction (and the stock never
          // releases). The sweep is still identifiable by
          // source == 'sweep' on the audit entry + movements.
          // (The PC sweep already does it this way.)
          final ran = await _stockMovingTransition(
            doc.id,
            'expired',
            from: 'new',
            reason: 'reservation_expired',
            actorUid: auth.currentUser?.uid ?? '',
            actorName: auth.currentUser?.email ?? '',
            source: 'sweep',
            expireBefore: now,
          );
          if (ran) expired++;
        } catch (e) {
          Diagnostics.instance.log('Lazy sweep: failed to expire ${doc.id}: $e');
        }
      }
      if (expired > 0) {
        Diagnostics.instance.log('Lazy sweep: expired $expired order(s)');
      }
      return expired;
    } on FirebaseException catch (e) {
      Diagnostics.instance.log('Lazy sweep failed: ${e.code} ${e.message}');
      return 0;
    } finally {
      _sweepRunning = false;
    }
  }

  /// Admin note on an order (v1.4 §7). A note never changes the
  /// status — the rules allow a status-unchanged update.
  Future<void> setOrderNotes(String id, String notes) async {
    _requireInit();
    await _auditedBatch(
      writes: {'orders/$id': {'notes': notes.trim()}},
      sensitive: const {},
      operation: 'update',
    );
  }

  /// COD payment status (cod_pending / cod_paid / cod_refused /
  /// cod_failed). Admin-only in the rules; no stock moves with it.
  Future<void> setOrderPaymentStatus(String id, String paymentStatus) async {
    _requireInit();
    if (!{'cod_pending', 'cod_paid', 'cod_refused', 'cod_failed'}.contains(paymentStatus)) {
      throw BackendException('حالة الدفع مش صحيحة');
    }
    await _auditedBatch(
      writes: {'orders/$id': {'paymentStatus': paymentStatus}},
      sensitive: {'orders/$id': {'paymentStatus': paymentStatus}},
      operation: 'update',
      topNewValues: {'paymentStatus': paymentStatus},
    );
  }

  // ---- Customers / inventory / shipping companies ----

  /// Derived customers (grouped by phone, from orders) — the
  /// queryable exposure for the customers UI (v1.4 §4.4, file 8).
  /// Reads at most [limit] recent orders; the export path uses
  /// deriveCustomers() over the full export instead.
  Future<List<Map<String, dynamic>>> customersList({int limit = 500}) async {
    _requireInit();
    final snap = await db
        .collection('orders')
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get();
    final orders = snap.docs.map((d) => _jsonDoc(d.id, d.data())).toList();
    return deriveCustomers(orders);
  }

  /// Inventory keyed by product id: {stock, reserved, available,
  /// inStock, minStock}. The admin apps read it for the stock-visibility
  /// display; the storefront never sees quantities.
  Future<Map<String, Map<String, dynamic>>> inventoryMap() async {
    _requireInit();
    final snap = await db.collection('inventory').get();
    final map = <String, Map<String, dynamic>>{};
    for (final d in snap.docs) {
      final data = d.data();
      final stock = ((data['stock'] ?? 0) as num).toInt();
      final reserved = ((data['reserved'] ?? 0) as num).toInt();
      map[d.id] = {
        'stock': stock,
        'reserved': reserved,
        'available': stock - reserved,
        'inStock': (stock - reserved) > 0,
        'minStock': ((data['minStock'] ?? 5) as num).toInt(),
      };
    }
    return map;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> shippingCompaniesStream() =>
      db.collection('shippingCompanies').orderBy('name').snapshots();

  Future<List<Map<String, dynamic>>> fetchShippingCompanies() async {
    _requireInit();
    final snap = await db.collection('shippingCompanies').orderBy('name').get();
    return snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
  }

  // ---- Manual orders (contract §1, no-functions) ----
  //
  // Creates an order on behalf of a customer (phone order) with ONE
  // Firestore client transaction — the same transaction the
  // storefront runs, with source 'admin_manual' and the admin's UID.
  // No Cloud Function is involved: prices/totals come from the
  // DATABASE prices just read, stock is reserved in the same
  // transaction, and the audit entry rides along (§4). Permission is
  // checked client-side here AND re-checked by the rules from
  // admins/{uid}.
  // After the transaction commits, products.inStock is refreshed
  // by the §13 second write (batched, up to 3 tries, best-effort).
  // Returns {'order': {...}, 'created': bool} — created:false means
  // the clientOrderId already existed (idempotent retry).
  Future<Map<String, dynamic>> createManualOrder({
    required String clientOrderId,
    required List<Map<String, dynamic>> items,
    required String customerName,
    required String customerPhone,
    required String customerAddress,
    String? shippingCompanyId,
    String? notes,
  }) async {
    _requireInit();
    if (!await hasPermission('orders_create_manual')) {
      throw BackendException('ماعندكش صلاحية إنشاء طلبات يدوية');
    }
    final shapeError = validateManualOrderInput(
      customerName: customerName,
      customerPhone: customerPhone,
      customerAddress: customerAddress,
      items: items,
    );
    if (shapeError != null) throw BackendException(shapeError);
    final merged = dedupeManualItems(items);
    final uid = auth.currentUser?.uid;
    if (uid == null) throw BackendException('سجّل الدخول الأول');
    final email = auth.currentUser?.email ?? '';
    Map<String, dynamic> result;
    try {
      result = await db.runTransaction<Map<String, dynamic>>((tx) async {
        final orderRef = db.collection('orders').doc(clientOrderId);
        // Idempotency first: a retry with the same clientOrderId
        // returns the existing order — no stock work, no duplicate.
        final existing = await tx.get(orderRef);
        if (existing.exists) {
          final data = existing.data() ?? {};
          return {
            'order': {'id': existing.id, ...data},
            'created': false,
            'newInStock': <String, bool>{},
          };
        }
        // Read products + inventory (one read per line), validate
        // against the DATABASE prices and the real availability.
        final lines = <Map<String, dynamic>>[];
        for (final line in merged) {
          final productId = (line['productId'] ?? '') as String;
          final qty = ((line['qty'] ?? 0) as num).toInt();
          final productSnap = await tx.get(db.collection('products').doc(productId));
          if (!productSnap.exists) {
            throw BackendException('منتج مش موجود في المتجر');
          }
          final product = productSnap.data() ?? {};
          final rawPrice = (product['price'] ?? 0) as num;
          if (!rawPrice.isFinite || rawPrice <= 0) {
            throw BackendException('سعر المنتج مش صحيح');
          }
          final price = wholeNum(rawPrice);
          // Pricing (Model P): the per-line base price is snapshotted
          // onto the order so the record alone reconstructs what the
          // customer saw. Null, or equal to the price, means no sale;
          // a stored base below the price is invalid data and is
          // treated as no sale rather than failing the order.
          final rawBase = product['basePrice'];
          var basePrice = rawBase is num ? rawBase.toInt() : null;
          if (basePrice != null && basePrice <= price) basePrice = null;
          final invSnap = await tx.get(db.collection('inventory').doc(productId));
          final inv = invSnap.data() ?? {};
          final stock = ((inv['stock'] ?? 0) as num).toInt();
          final reserved = ((inv['reserved'] ?? 0) as num).toInt();
          final available = stock - reserved;
          if (qty > available) {
            throw BackendException(insufficientStockMessage(
              productName: (product['name'] ?? productId) as String,
              available: available < 0 ? 0 : available,
            ));
          }
          lines.add({
            'productId': productId,
            'name': (product['name'] ?? '') as String,
            'price': price,
            'basePrice': basePrice,
            'qty': qty,
            'stock': stock,
            'reserved': reserved,
            'minStock': ((inv['minStock'] ?? 5) as num).toInt(),
            'costPrice': ((inv['costPrice'] ?? 0) as num).toInt(),
          });
        }
        // Totals from the DATABASE prices, never a client total.
        // The fixed delivery fee is read from
        // storeSettings/settings (Technical Plan §2/§5):
        // fee-default-free (decision 2026-11-27) — an unset fee
        // means free delivery, so no order is ever blocked on it.
        // The fee is client-asserted on the manual path (decision
        // D2: the fee split is kept).
        final settingsSnap =
            await tx.get(db.collection('storeSettings').doc('settings'));
        final feeSettings =
            parseDeliveryFeeSettings(settingsSnap.data());
        final deliveryFee = feeSettings.deliveryFee;
        final computed = computeOrderTotals(
          lines
              .map((l) => {
                    'price': l['price'] as num,
                    'qty': l['qty'] as int,
                    'basePrice': l['basePrice'] as int?,
                  })
              .toList(),
          deliveryFee: deliveryFee,
          freeDeliveryThreshold: feeSettings.freeDeliveryThreshold,
        );
        // The stored fee is the EFFECTIVE fee (0 when the D3
        // threshold waives it); amountDue is the cash due at the door.
        final effectiveFee = computed.deliveryFee ?? deliveryFee;
        final now = FieldValue.serverTimestamp();
        // The audit id is minted here (client-side random id) so the
        // order can carry it as auditId; the entry itself is written
        // post-commit (M1 audit-split, see below).
        final auditId = db.collection('audit').doc().id;
        // 'items' coverage: a manual order with any on-sale line
        // records 'items' in the audit entry — the same helper
        // convertDraft uses. (The rules no longer CHECK coverage
        // since the audit-split, M1 — the entry keeps the full
        // coverage so the log still reconstructs the order.)
        final hasBasePrice = lines.any((l) => l['basePrice'] != null);
        final docIds = <String, List<String>>{
          'orders/$clientOrderId':
              orderAuditFields(hasBasePrice: hasBasePrice),
        };
        final newValuesByDoc = <String, Map<String, dynamic>>{
          'orders/$clientOrderId': {
            'status': 'new',
            'total': wholeNum(computed.total),
            'saleSavings': wholeNum(computed.saleSavings),
            'deliveryFee': effectiveFee,
            'amountDue': wholeNum(computed.amountDue!),
            if (hasBasePrice)
              'items': lines
                  .map((l) => {
                        'productId': l['productId'],
                        'name': l['name'],
                        'price': l['price'],
                        'basePrice': l['basePrice'],
                        'qty': l['qty'],
                      })
                  .toList(),
          },
        };
        final documents = <Map<String, dynamic>>[];
        final newInStock = <String, bool>{};
        // Reserve stock (absolute set, merge). The rules enforce
        // reserved <= stock, so an over-reservation is denied.
        for (final line in lines) {
          final productId = (line['productId'] ?? '') as String;
          final qty = (line['qty'] ?? 0) as int;
          final stock = (line['stock'] ?? 0) as int;
          final reserved = (line['reserved'] ?? 0) as int;
          final newReserved = reserved + qty;
          newInStock[productId] = (stock - newReserved) > 0;
          final invRef = db.collection('inventory').doc(productId);
          tx.set(invRef, {
            'productId': productId,
            'stock': stock,
            'reserved': newReserved,
            'minStock': ((line['minStock'] ?? 5) as num).toInt(),
            'costPrice': ((line['costPrice'] ?? 0) as num).toInt(),
            'operationId': auditId,
            'updatedAt': now,
          }, SetOptions(merge: true));
          // M1 (2026-11-27, Option 3): the movement-ledger write for
          // the reserve left this transaction — it is written
          // post-commit by _writeOrderMovementsAndAudit.
          // docIds must cover every key the inventory write sets
          // (the rules check diff coverage); the sensitive values
          // (stock/reserved) are recorded in newValuesByDoc.
          docIds['inventory/$productId'] = [
            'productId',
            'stock',
            'reserved',
            'minStock',
            'costPrice',
            'operationId',
            'updatedAt',
          ];
          newValuesByDoc['inventory/$productId'] = {
            'stock': stock,
            'reserved': newReserved,
          };
          documents.add({
            'collection': 'inventory',
            'docId': productId,
            'changedFields': ['reserved', 'stock'],
            'oldValues': {'stock': stock, 'reserved': reserved},
            'newValues': {'stock': stock, 'reserved': newReserved},
          });
        }
        // Create the order (doc id = clientOrderId), fields EXACTLY
        // as functions/lib/orders.js createOrderTx builds them, PLUS
        // auditId — and nothing else (the rules enforce the exact
        // key set, so no operationId field here).
        final order = <String, dynamic>{
          'id': clientOrderId,
          'clientOrderId': clientOrderId,
          'customerName': customerName.trim(),
          'customerPhone': customerPhone.trim(),
          'customerAddress': customerAddress.trim(),
          'items': lines
              .map((l) => {
                    'productId': l['productId'],
                    'name': l['name'],
                    'price': l['price'],
                    'basePrice': l['basePrice'],
                    'qty': l['qty'],
                  })
              .toList(),
          'subtotal': wholeNum(computed.subtotal),
          'total': wholeNum(computed.total),
          // Pricing snapshot (Technical Plan §2): the order alone
          // reconstructs what the customer saw. No attemptId —
          // manual orders have no checkout attempt.
          'saleSavings': wholeNum(computed.saleSavings),
          'deliveryFee': effectiveFee,
          // The fee was verified set above, so amountDue is non-null.
          'amountDue': wholeNum(computed.amountDue!),
          'status': 'new',
          'paymentStatus': 'cod_pending',
          'source': 'admin_manual',
          'createdBy': uid,
          'shippingCompanyId': (shippingCompanyId ?? '').trim().isEmpty
              ? null
              : shippingCompanyId!.trim(),
          'trackingNumber': null,
          'notes': (notes ?? '').trim().isEmpty ? null : notes!.trim(),
          'createdAt': now,
          'updatedAt': now,
          'acceptedAt': null,
          'deliveredAt': null,
          'cancelledAt': null,
          'cancelReason': null,
          'auditId': auditId,
        };
        tx.set(orderRef, order);
        documents.insert(0, {
          'collection': 'orders',
          'docId': clientOrderId,
          'changedFields': docIds['orders/$clientOrderId']!,
          'oldValues': {},
          'newValues': {
            'status': 'new',
            'total': wholeNum(computed.total),
            'saleSavings': wholeNum(computed.saleSavings),
            'deliveryFee': effectiveFee,
            'amountDue': wholeNum(computed.amountDue!),
          },
        });
        // M1 (2026-11-27, audit-split): the audit entry is NOT
        // written inside this transaction any more — it is built
        // here, returned, and written AFTER the order commits by
        // _writeOrderMovementsAndAudit (best-effort, retry, never
        // throws). Same fields as the old in-tx write, except the
        // timestamp: the audit-create rule requires
        // timestamp == request.time of the audit write itself, so
        // the helper stamps a FRESH server timestamp at write time
        // instead of reusing the transaction's `now`.
        final auditEntry = <String, dynamic>{
          'operationId': auditId,
          'actor': uid,
          'actorName': email,
          'collection': 'orders',
          'docId': clientOrderId,
          'operation': 'manual_order_create',
          'changedFields': docIds.values.expand((e) => e).toSet().toList(),
          'oldValues': {},
          'newValues': {
            'status': 'new',
            'total': wholeNum(computed.total),
            'saleSavings': wholeNum(computed.saleSavings),
            'deliveryFee': effectiveFee,
            'amountDue': wholeNum(computed.amountDue!),
          },
          'docIds': docIds,
          'newValuesByDoc': newValuesByDoc,
          'documents': documents,
          'source': 'createManualOrder',
        };
        return {
          'order': order,
          'created': true,
          'newInStock': newInStock,
          'auditId': auditId,
          'auditEntry': auditEntry,
          'movementLines': lines
              .map((l) => {
                    'productId': l['productId'],
                    'qty': l['qty'],
                  })
              .toList(),
        };
      });
    } on BackendException {
      rethrow;
    } on FirebaseException catch (e) {
      Diagnostics.instance.log('Manual order failed: ${e.code} ${e.message}');
      if (e.code == 'permission-denied') {
        throw BackendException(
            'تعذر إنشاء الطلب — الكمية أكبر من المتاح أو البيانات مرفوضة، راجع الكميات وحاول تاني');
      }
      throw BackendException('تعذر إنشاء الطلب: ${e.message ?? e.code}');
    }
    if (result['created'] == true) {
      Diagnostics.instance.log('Manual order created: $clientOrderId');
      await _refreshInStock(
          (result['newInStock'] as Map<String, bool>?) ?? {});
      // M1: movements + audit AFTER the commit, only on a real
      // create — never on an idempotent retry (created == false)
      // and never when the transaction threw (we never get here).
      // Best-effort: a failure is logged, the order stands, and
      // the orphan-orders check repairs the missing audit entry.
      await _writeOrderMovementsAndAudit(
        auditId: (result['auditId'] ?? '') as String,
        auditEntry:
            (result['auditEntry'] as Map<String, dynamic>?) ?? const {},
        movementLines: (result['movementLines'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .toList() ??
            const [],
        orderId: clientOrderId,
        source: 'createManualOrder',
        actorUid: uid,
      );
    }
    return {'order': result['order'], 'created': result['created']};
  }

  /// §13 second write: refresh products.inStock from the inventory
  /// values the order transaction just wrote. Batched, up to 3 tries,
  /// best-effort — a failure only leaves a stale availability flag
  /// (logged here, corrected by the next admin sync / sweep).
  Future<void> _refreshInStock(Map<String, bool> newInStock) async {
    if (newInStock.isEmpty) return;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        await _auditedBatch(
          writes: {
            for (final e in newInStock.entries)
              'products/${e.key}': {'inStock': e.value},
          },
          sensitive: {
            for (final e in newInStock.entries)
              'products/${e.key}': {'inStock': e.value},
          },
          operation: 'update',
        );
        return;
      } catch (e) {
        Diagnostics.instance.log(
            'inStock refresh failed (attempt $attempt/3): $e');
      }
    }
  }

  /// M1 (2026-11-27, Option 3 + audit-split): the movement-ledger
  /// writes + the audit entry for a newly created order, written
  /// AFTER the order transaction commits. Best-effort with up to 3
  /// attempts each, NEVER throws: a missing movement or audit entry
  /// must never fail an order the customer already has — the
  /// orphan-orders check (see [findOrphanOrders]) repairs a missing
  /// audit entry. Only called when the transaction really created
  /// the order (created == true), never on an idempotent retry.
  Future<void> _writeOrderMovementsAndAudit({
    required String auditId,
    required Map<String, dynamic> auditEntry,
    required List<Map<String, dynamic>> movementLines,
    required String orderId,
    required String source,
    required String actorUid,
  }) async {
    // Movements: one batch, one doc per line — the EXACT fields the
    // transaction used to write, except createdAt, which is a FRESH
    // server timestamp (the admin branch of the movements rule has
    // no shape constraint; a fresh timestamp keeps the ledger
    // honest about when the entry landed).
    if (movementLines.isNotEmpty) {
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          final batch = db.batch();
          for (final line in movementLines) {
            batch.set(db.collection('movements').doc(), {
              'productId': line['productId'],
              'type': 'order_reserve',
              'qty': -((line['qty'] ?? 0) as int),
              'orderId': orderId,
              'source': source,
              'actorUid': actorUid,
              'createdAt': FieldValue.serverTimestamp(),
            });
          }
          await batch.commit();
          break;
        } catch (e) {
          Diagnostics.instance.log(
              'Order movements write failed (attempt $attempt/3, order $orderId): $e');
        }
      }
    }
    // Audit: the entry built inside the transaction, with a FRESH
    // timestamp — the audit-create rule (firestore.rules match
    // /audit) requires timestamp == request.time of THIS write, so
    // the transaction's `now` sentinel cannot be reused. The admin
    // branch also requires actor == request.auth.uid,
    // operationId == the doc id, a non-empty docIds map and a
    // newValuesByDoc map — all carried over unchanged.
    if (auditId.isNotEmpty && auditEntry.isNotEmpty) {
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          await db.collection('audit').doc(auditId).set({
            ...auditEntry,
            'timestamp': FieldValue.serverTimestamp(),
          });
          break;
        } catch (e) {
          Diagnostics.instance.log(
              'Order audit write failed (attempt $attempt/3, order $orderId): $e');
        }
      }
    }
  }

  // ---- Feedback, one-way cards (contract §6) ----
  //
  // No status, no priority, no replies, no tracking code, no lookup.
  // A complaint is a direct write of {name, email, phone, message,
  // createdAt}; the admin only reads the cards and can delete spam.

  /// Creates a complaint on a customer's behalf (same one-way shape
  /// as the storefront contact form). Returns the new doc id.
  Future<String> submitFeedback({
    required String name,
    required String email,
    required String phone,
    required String message,
  }) async {
    _requireInit();
    final error = validateFeedbackInput(
      name: name,
      email: email,
      phone: phone,
      message: message,
    );
    if (error != null) throw BackendException(error);
    final ref = db.collection('feedback').doc();
    try {
      await ref.set({
        'name': name.trim(),
        'email': email.trim(),
        'phone': phone.replaceAll(RegExp(r'[^0-9]'), ''),
        'message': message.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (e) {
      Diagnostics.instance.log('submitFeedback failed: ${e.code} ${e.message}');
      throw BackendException('تعذر حفظ الشكوى: ${e.message ?? e.code}');
    }
    Diagnostics.instance.log('Feedback submitted: ${ref.id}');
    return ref.id;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> feedbackStream() => db
      .collection('feedback')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  /// Deletes a complaint card (spam). Audited delete — the rules
  /// allow admin delete with the deterministic delete-audit entry.
  Future<void> deleteFeedback(String id) async {
    _requireInit();
    await _auditedDelete(
      collection: 'feedback',
      docId: id,
      changedFields: const ['name', 'email', 'phone', 'message', 'createdAt'],
    );
    Diagnostics.instance.log('Feedback deleted: $id');
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> teamStream() =>
      db.collection('admins').snapshots();

  /// Removes a team member from the team list (v1.1.2). Deletes the
  /// member's admins doc and, best-effort, their phone lookup. NEVER
  /// removes the signed-in admin themself. Honest limit, same as
  /// DeliveryFlow: the Firebase Auth login itself cannot be deleted
  /// from the app (client SDK limit) — a removed member's Auth login
  /// must be deleted from the Firebase console if sign-in must be
  /// fully revoked; removing the admins doc already hides them from
  /// the team and from Google sign-in's admin gate.
  Future<void> removeTeamMember(String uid) async {
    _requireInit();
    if (auth.currentUser?.uid == uid) {
      throw BackendException('مينفعش تشيل حسابك انت من الفريق');
    }
    final doc = await db.collection('admins').doc(uid).get();
    final phone = (doc.data()?['phone'] ?? '') as String;
    final normalized = normalizeEgyptPhone(phone);
    if (normalized != null) {
      try {
        await db.collection('phones').doc(phoneLookupKey(normalized)).delete();
      } catch (e) {
        Diagnostics.instance.log('Team removal: phone lookup kept: $e');
      }
    }
    await db.collection('admins').doc(uid).delete();
    Diagnostics.instance.log('Team member removed: $uid');
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> sessionsStream() => db
      .collection('analytics')
      .doc('sessions')
      .collection('items')
      .orderBy('startedAt', descending: true)
      .limit(100)
      .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> attemptsStream() => db
      .collection('analytics')
      .doc('attempts')
      .collection('items')
      .orderBy('startedAt', descending: true)
      .limit(100)
      .snapshots();

  // ---- Incomplete orders + journey tracking (2026-11-27) ----
  //
  // A checkout draft is a LEAD, not an order: the storefront autosaves
  // it while the visitor types (local first, server after 10s idle),
  // and an admin converts it only after verbal confirmation — one
  // transaction: status check + moot check + stock/price re-check +
  // reserve + create order (doc id = draft id) + mark converted.
  // Canonical schemas: docs/incomplete-orders-schema.md.
  // Per-day visits come from GA4 only — no invented Firestore count.

  /// The 27 governorates (stable ids, same list as the storefront
  /// PURE-HELPERS block and scripts/seed-governorates.js). Used as
  /// the fallback when the `storeSettings/governorates` doc is
  /// missing; the admin toggles `active` per entry in settings.
  static const List<Map<String, String>> governorates27 = [
    {'id': 'cairo', 'name': 'القاهرة'},
    {'id': 'giza', 'name': 'الجيزة'},
    {'id': 'alexandria', 'name': 'الإسكندرية'},
    {'id': 'dakahlia', 'name': 'الدقهلية'},
    {'id': 'red-sea', 'name': 'البحر الأحمر'},
    {'id': 'beheira', 'name': 'البحيرة'},
    {'id': 'fayoum', 'name': 'الفيوم'},
    {'id': 'gharbia', 'name': 'الغربية'},
    {'id': 'ismailia', 'name': 'الإسماعيلية'},
    {'id': 'menofia', 'name': 'المنوفية'},
    {'id': 'minya', 'name': 'المنيا'},
    {'id': 'qalyubia', 'name': 'القليوبية'},
    {'id': 'new-valley', 'name': 'الوادي الجديد'},
    {'id': 'suez', 'name': 'السويس'},
    {'id': 'asyut', 'name': 'أسيوط'},
    {'id': 'sohag', 'name': 'سوهاج'},
    {'id': 'qena', 'name': 'قنا'},
    {'id': 'luxor', 'name': 'الأقصر'},
    {'id': 'aswan', 'name': 'أسوان'},
    {'id': 'sharqia', 'name': 'الشرقية'},
    {'id': 'port-said', 'name': 'بورسعيد'},
    {'id': 'damietta', 'name': 'دمياط'},
    {'id': 'kafr-el-sheikh', 'name': 'كفر الشيخ'},
    {'id': 'beni-suef', 'name': 'بني سويف'},
    {'id': 'matrouh', 'name': 'مطروح'},
    {'id': 'north-sinai', 'name': 'شمال سيناء'},
    {'id': 'south-sinai', 'name': 'جنوب سيناء'},
  ];

  /// Egyptian mobile validation (same rule as the storefront): an
  /// 11-digit 01[0125] number; a pasted +20 / 20 country code folds
  /// back to the local 01… form first.
  static bool isValidEgyptianMobile(String? phone) {
    var digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length == 12 && digits.startsWith('20')) {
      digits = '0${digits.substring(2)}';
    }
    return RegExp(r'^01[0125][0-9]{8}$').hasMatch(digits);
  }

  /// Visible seconds -> stored dwell band token (ASCII). 9s -> '<10s';
  /// 10s and 60s -> '10-60s'; 61s -> '>60s'. Hidden-tab time is never
  /// passed in (the storefront excludes it).
  static String dwellBand(int visibleSeconds) {
    if (visibleSeconds < 10) return '<10s';
    if (visibleSeconds <= 60) return '10-60s';
    return '>60s';
  }

  /// Journey summaries carry `schemaVersion: 1` on every event.
  static const int journeySchemaVersion = 1;

  /// Cap a journey product list at 20 entries (oldest kept — the
  /// first 20 win) and count the overflow — mirrors the storefront
  /// flushJourney cap and the rules' journeyEntriesOk (≤ 20).
  static ({List<Map<String, dynamic>> entries, int overflowCount})
      capJourneyEntries(List<Map<String, dynamic>> entries) {
    if (entries.length <= 20) {
      return (entries: entries, overflowCount: 0);
    }
    return (
      entries: entries.sublist(0, 20),
      overflowCount: entries.length - 20,
    );
  }

  /// Human label for a journey action. Unknown action types render
  /// as plain text (the schema is append-only — new actions must
  /// never break the admin view).
  static String journeyActionLabel(String action) {
    switch (action) {
      case 'view':
        return 'شاف المنتج';
      case 'add':
        return 'ضاف للسلة';
      case 'checkout_start':
        return 'بدأ الطلب';
      default:
        return action;
    }
  }

  /// One cart line's availability from live inventory: available is
  /// (stock - reserved). ok: qty fits; out: nothing available; short:
  /// some available, less than qty.
  static ({String state, int availableQty}) lineAvailability({
    required int availableQty,
    required int qty,
  }) {
    final avail = availableQty < 0 ? 0 : availableQty;
    if (avail <= 0) return (state: 'out', availableQty: 0);
    if (qty <= avail) return (state: 'ok', availableQty: avail);
    return (state: 'short', availableQty: avail);
  }

  /// Draft completeness 0–100: 25 points each for a name, a valid
  /// phone, a non-empty cart, and an address (governorate + detailed,
  /// or the combined field).
  static int draftTriageScore({
    required bool hasName,
    required bool hasPhone,
    required bool hasCart,
    required bool hasAddress,
  }) =>
      (hasName ? 25 : 0) +
      (hasPhone ? 25 : 0) +
      (hasCart ? 25 : 0) +
      (hasAddress ? 25 : 0);

  /// The triage MINIMUM for the Incomplete Orders list (design brief
  /// entry 17): a draft is callable — and therefore listable — only
  /// when it has a non-empty cart, a name, and a full valid Egyptian
  /// mobile. Address is NOT part of the minimum (it scores 25 points
  /// in draftTriageScore but a draft without it still lists).
  static bool draftMeetsTriage({
    required bool hasName,
    required bool hasPhone,
    required bool hasCart,
  }) =>
      hasName && hasPhone && hasCart;

  /// Map form of [draftMeetsTriage] for a raw draft document (the
  /// list screen's rows are maps): name non-empty, phone a full
  /// valid Egyptian mobile, cart non-empty.
  static bool draftMeetsTriageMap(Map<String, dynamic> d) {
    final cart = (d['cart'] as List<dynamic>? ?? []);
    return draftMeetsTriage(
      hasName: ((d['name'] ?? '') as String).trim().isNotEmpty,
      hasPhone: isValidEgyptianMobile((d['phone'] ?? '') as String),
      hasCart: cart.isNotEmpty,
    );
  }

  /// The visible drafts for the Incomplete Orders list: triage
  /// first (below-minimum drafts never appear), then dedup by phone
  /// (newest first wins). Status is deliberately NOT filtered — a
  /// `dead` or `converted` draft that meets triage stays visible as
  /// a closed record (CUJ 2). Input is expected newest-first.
  static List<Map<String, dynamic>> filterVisibleDrafts(
      List<Map<String, dynamic>> drafts) {
    final triaged = drafts.where(draftMeetsTriageMap).toList();
    return dedupDraftsByPhone(triaged);
  }

  /// The order id the moot badge links to: the draft's own
  /// `mootOrderId` field (written by convertDraft when the phone
  /// already ordered) when present, else the newest order for the
  /// draft's phone from the list-time phone lookup. Null when the
  /// draft is not moot by either source.
  static String? mootOrderIdFor(
    Map<String, dynamic> draft,
    Map<String, Map<String, dynamic>> ordersByPhone,
  ) {
    final stored = ((draft['mootOrderId'] ?? '') as String).trim();
    if (stored.isNotEmpty) return stored;
    final phone = ((draft['phone'] ?? '') as String).trim();
    if (phone.isEmpty) return null;
    final order = ordersByPhone[phone];
    if (order == null) return null;
    final id = (order['id'] ?? '') as String;
    return id.isEmpty ? null : id;
  }

  /// The audit docIds list for a new order document: the money
  /// fields always, plus 'items' whenever any line carries a base
  /// price — so the log still reconstructs the order in full.
  /// (The rules no longer CHECK coverage since the audit-split,
  /// M1 — this list is the log's completeness, not a gate.)
  /// Shared by createManualOrder and convertDraft so the two paths
  /// can never drift apart.
  static List<String> orderAuditFields({required bool hasBasePrice}) => [
        'status',
        'total',
        'saleSavings',
        'deliveryFee',
        'amountDue',
        if (hasBasePrice) 'items',
      ];

  /// The draft state machine (schema doc §2). Terminal states
  /// (converted, dead) have no outgoing transition.
  static const Map<String, List<String>> draftTransitions = {
    'new': ['contacted', 'no-answer', 'converted', 'dead'],
    'contacted': ['no-answer', 'converted', 'dead'],
    'no-answer': ['contacted', 'converted', 'dead'],
    'converted': [],
    'dead': [],
  };

  static bool draftCanTransition(String from, String to) =>
      (draftTransitions[from] ?? []).contains(to);

  /// Governorate list resolution: a missing/unreadable document falls
  /// back to the full hardcoded 27 so checkout never breaks; a
  /// document with zero active entries is the "not set up" state.
  static ({List<Map<String, String>> entries, bool fromFallback, bool notSetUp})
      governorateFallback(List<dynamic>? entries) {
    if (entries == null) {
      return (
        entries: governorates27
            .map((g) => {'id': g['id']!, 'name': g['name']!})
            .toList(),
        fromFallback: true,
        notSetUp: false,
      );
    }
    final active = entries
        .whereType<Map<String, dynamic>>()
        .where((e) =>
            e['active'] == true &&
            (e['id'] as String?)?.isNotEmpty == true &&
            (e['name'] as String?)?.isNotEmpty == true)
        .map((e) => {'id': e['id'] as String, 'name': e['name'] as String})
        .toList();
    if (active.isEmpty) {
      return (entries: <Map<String, String>>[], fromFallback: false, notSetUp: true);
    }
    return (entries: active, fromFallback: false, notSetUp: false);
  }

  /// Dedupe drafts by phone (newest first wins): a visitor on two
  /// devices is two drafts, but the admin list shows one row per
  /// phone. Drafts with no phone are kept as-is. Input is expected
  /// newest-first (the list query order); output keeps that order.
  static List<Map<String, dynamic>> dedupDraftsByPhone(
      List<Map<String, dynamic>> drafts) {
    final seenPhones = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final d in drafts) {
      final phone = (d['phone'] ?? '') as String;
      final key = normalizeEgyptPhone(phone) ??
          phone.replaceAll(RegExp(r'\D'), '');
      if (key.isEmpty) {
        out.add(d);
        continue;
      }
      if (seenPhones.add(key)) out.add(d);
    }
    return out;
  }

  /// Live drafts stream (newest sync first, limit 100). The
  /// Incomplete Orders tab paginates instead — see fetchDraftsPage().
  Stream<QuerySnapshot<Map<String, dynamic>>> draftsStream() => db
      .collection('checkoutDrafts')
      .orderBy('lastSyncAt', descending: true)
      .limit(100)
      .snapshots();

  /// One page of drafts, newest sync first. Returns the docs + the
  /// cursor for the next page (null when there is no next page).
  Future<({List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, QueryDocumentSnapshot<Map<String, dynamic>>? lastDoc})> fetchDraftsPage({
    QueryDocumentSnapshot<Map<String, dynamic>>? startAfter,
    int pageSize = 20,
  }) async {
    _requireInit();
    var query = db
        .collection('checkoutDrafts')
        .orderBy('lastSyncAt', descending: true)
        .limit(pageSize);
    if (startAfter != null) query = query.startAfterDocument(startAfter);
    final snap = await query.get();
    return (
      docs: snap.docs,
      lastDoc: snap.docs.length < pageSize ? null : snap.docs.last,
    );
  }

  /// Count of drafts still in `new` (for the nav label). One-shot
  /// aggregate count, not a live listener.
  Future<int> newDraftsCount() async {
    _requireInit();
    final snap = await db
        .collection('checkoutDrafts')
        .where('status', isEqualTo: 'new')
        .count()
        .get();
    return snap.count ?? 0;
  }

  /// One draft, live (detail view).
  Stream<DocumentSnapshot<Map<String, dynamic>>> draftStream(String id) =>
      db.collection('checkoutDrafts').doc(id).snapshots();

  /// One draft, one-shot (conversion reads it inside the tx instead).
  Future<Map<String, dynamic>?> fetchDraft(String id) async {
    _requireInit();
    final snap = await db.collection('checkoutDrafts').doc(id).get();
    return snap.data();
  }

  /// One order by id, one-shot (the moot badge opens its detail).
  Future<DocumentSnapshot<Map<String, dynamic>>> fetchOrder(String id) async {
    _requireInit();
    return db.collection('orders').doc(id).get();
  }

  /// Drafts created today that carry a valid phone (dashboard funnel
  /// card). One-shot get (limit 200) + client-side phone filter —
  /// no composite index needed.
  Future<int> draftsWithPhoneTodayCount() async {
    _requireInit();
    final now = DateTime.now();
    final start = Timestamp.fromDate(DateTime(now.year, now.month, now.day));
    final snap = await db
        .collection('checkoutDrafts')
        .where('createdAt', isGreaterThanOrEqualTo: start)
        .limit(200)
        .get();
    return snap.docs
        .where((d) =>
            isValidEgyptianMobile((d.data()['phone'] ?? '') as String))
        .length;
  }

  /// Non-cancelled orders created today (dashboard funnel card).
  Future<int> ordersTodayCount() async {
    _requireInit();
    final now = DateTime.now();
    final start = Timestamp.fromDate(DateTime(now.year, now.month, now.day));
    final snap = await db
        .collection('orders')
        .where('createdAt', isGreaterThanOrEqualTo: start)
        .limit(200)
        .get();
    return snap.docs
        .where((d) => (d.data()['status'] ?? '') != 'cancelled')
        .length;
  }

  /// Change a draft's status (merge-only, audited). The transition
  /// itself is validated here; the rules let any admin/manager write
  /// a draft, so this is the guard that stops e.g. resurrecting a
  /// converted draft.
  Future<void> updateDraftStatus(String id, String status) async {
    _requireInit();
    final current = await fetchDraft(id);
    if (current == null) throw BackendException('المسودة مش موجودة');
    final from = (current['status'] ?? 'new') as String;
    if (from != status && !draftCanTransition(from, status)) {
      throw BackendException('مينفعش تغير الحالة من $from لـ $status');
    }
    await _auditedBatch(
      writes: {
        'checkoutDrafts/$id': {'status': status},
      },
      sensitive: {
        'checkoutDrafts/$id': {'status': status},
      },
      operation: 'update',
    );
    Diagnostics.instance.log('Draft $id status -> $status');
  }

  /// Delete a draft manually (audited delete — the rules require the
  /// deterministic delete-audit entry).
  Future<void> deleteDraft(String id) async {
    _requireInit();
    await _auditedDelete(
      collection: 'checkoutDrafts',
      docId: id,
      changedFields: const [
        'sessionId',
        'sessionToken',
        'name',
        'phone',
        'cart',
        'status',
      ],
    );
    Diagnostics.instance.log('Draft deleted: $id');
  }

  /// The journey summary for one session (doc id == session id).
  /// Returns null when the visitor has no recorded journey.
  Future<Map<String, dynamic>?> journeySummaryFor(String sessionId) async {
    _requireInit();
    final snap =
        await db.collection('journeySummaries').doc(sessionId).get();
    return snap.data();
  }

  /// True when this phone placed a real order at or after [since].
  /// Single-field query (limit 10) + client-side date filter — no
  /// composite index needed. A null [since] (draft without a
  /// createdAt) can never be established as moot.
  Future<bool> isPhoneOrdered(String phone, DateTime? since) async {
    _requireInit();
    if (since == null) return false;
    final snap = await db
        .collection('orders')
        .where('customerPhone', isEqualTo: phone)
        .limit(10)
        .get();
    for (final doc in snap.docs) {
      final createdAt = (doc.data()['createdAt'] as Timestamp?)?.toDate();
      if (createdAt != null && !createdAt.isBefore(since)) return true;
    }
    return false;
  }

  /// The newest real order per phone (for the list-time "already
  /// ordered" badge). One `whereIn` query per chunk of 10 phones —
  /// the visible page is 20 drafts, so at most two queries.
  Future<Map<String, Map<String, dynamic>>> fetchOrdersByPhones(
      List<String> phones) async {
    _requireInit();
    final out = <String, Map<String, dynamic>>{};
    final unique = phones.where((p) => p.trim().isNotEmpty).toSet().toList();
    for (var start = 0; start < unique.length; start += 10) {
      final chunk = unique.sublist(
          start, (start + 10).clamp(0, unique.length));
      final snap = await db
          .collection('orders')
          .where('customerPhone', whereIn: chunk)
          .limit(50)
          .get();
      for (final doc in snap.docs) {
        final data = doc.data();
        final phone = (data['customerPhone'] ?? '') as String;
        final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
        final prev = out[phone];
        final prevAt = prev == null
            ? null
            : (prev['createdAt'] as Timestamp?)?.toDate();
        if (prev == null ||
            (createdAt != null &&
                (prevAt == null || createdAt.isAfter(prevAt)))) {
          out[phone] = {'id': doc.id, ...data};
        }
      }
    }
    return out;
  }

  /// Convert a draft into a real order — ONE transaction:
  /// (1) read the draft; converted returns the existing order,
  /// dead refuses; (2) moot check (same phone ordered at/after the
  /// draft was created — the draft is then marked moot, no order);
  /// (3) re-read products + inventory; a price change or a stock
  /// shortage returns a result, never an order; (4) reserve + create
  /// the order (doc id = draft id, source admin_manual) + mark the
  /// draft converted. Double-tap returns the existing order.
  ///
  /// Returns a result map: `result` is `ok` | `PRICE_CHANGED` |
  /// `INSUFFICIENT_STOCK` | `MOOT` | `ALREADY_CONVERTED`, plus
  /// `order` (the order map, when there is one), `mootOrderId`
  /// (when moot), `created` and `newInStock`. Hard errors (missing
  /// draft, dead draft, no permission) throw
  /// BackendException.
  Future<Map<String, dynamic>> convertDraft({
    required String draftId,
    required String customerName,
    required String customerPhone,
    String? customerPhone2,
    String? governorate,
    String? detailedAddress,
    required String customerAddress,
    String? shippingCompanyId,
    String? notes,
  }) async {
    _requireInit();
    if (!await hasPermission('orders_create_manual')) {
      throw BackendException('ماعندكش صلاحية إنشاء طلبات يدوية');
    }
    if (customerName.trim().isEmpty) throw BackendException('اكتب اسم العميل');
    if (!isValidEgyptianMobile(customerPhone)) {
      throw BackendException('اكتب رقم موبايل صحيح');
    }
    if (customerPhone2 != null &&
        customerPhone2.trim().isNotEmpty &&
        !isValidEgyptianMobile(customerPhone2)) {
      throw BackendException('رقم الموبايل الاحتياطي مش صحيح');
    }
    if (customerAddress.trim().isEmpty) {
      throw BackendException('اكتب العنوان');
    }
    final uid = auth.currentUser?.uid;
    if (uid == null) throw BackendException('سجّل الدخول الأول');
    final email = auth.currentUser?.email ?? '';
    // (2) Moot check, BEFORE the transaction: this cloud_firestore
    // version's Transaction.get takes only a DocumentReference, not
    // a query, so the phone lookup runs here (single-field query,
    // limit 10, client-side date filter — no composite index). The
    // transaction below still re-checks the draft status, so a draft
    // converted by another admin in between returns the existing
    // order instead of a duplicate.
    final preDraft = await fetchDraft(draftId);
    if (preDraft == null) throw BackendException('المسودة مش موجودة');
    if ((preDraft['status'] ?? 'new') == 'dead') {
      throw BackendException('المسودة دي اتقفلت ومينفعش تتحول لطلب');
    }
    final preCreatedAt = (preDraft['createdAt'] as Timestamp?)?.toDate();
    if (preCreatedAt != null) {
      final priorSnap = await db
          .collection('orders')
          .where('customerPhone', isEqualTo: customerPhone.trim())
          .limit(10)
          .get();
      for (final doc in priorSnap.docs) {
        final createdAt =
            (doc.data()['createdAt'] as Timestamp?)?.toDate();
        if (createdAt != null && !createdAt.isBefore(preCreatedAt)) {
          await _auditedBatch(
            writes: {
              'checkoutDrafts/$draftId': {'mootOrderId': doc.id},
            },
            sensitive: const {},
            operation: 'update',
          );
          return {
            'result': 'MOOT',
            'mootOrderId': doc.id,
            'order': {'id': doc.id, ...doc.data()},
            'created': false,
            'newInStock': <String, bool>{},
          };
        }
      }
    }
    Map<String, dynamic> result;
    try {
      result = await db.runTransaction<Map<String, dynamic>>((tx) async {
        final draftRef = db.collection('checkoutDrafts').doc(draftId);
        final draftSnap = await tx.get(draftRef);
        if (!draftSnap.exists) {
          throw BackendException('المسودة مش موجودة');
        }
        final draft = draftSnap.data() ?? {};
        final status = (draft['status'] ?? 'new') as String;
        final orderRef = db.collection('orders').doc(draftId);
        if (status == 'converted') {
          final existing = await tx.get(orderRef);
          if (existing.exists) {
            return {
              'result': 'ALREADY_CONVERTED',
              'order': {'id': existing.id, ...(existing.data() ?? {})},
              'created': false,
              'newInStock': <String, bool>{},
            };
          }
          throw BackendException('المسودة دي اتحولت قبل كده بس الطلب مش موجود');
        }
        if (status == 'dead') {
          throw BackendException('المسودة دي اتقفلت ومينفعش تتحول لطلب');
        }
        final cart = (draft['cart'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();
        if (cart.isEmpty) {
          throw BackendException('المسودة دي مفيهاش منتجات');
        }
        final merged = dedupeManualItems(cart
            .map((l) => {
                  'productId': (l['productId'] ?? '') as String,
                  'qty': ((l['qty'] ?? 0) as num).toInt(),
                })
            .toList());
        if (merged.length > maxProductsPerOrder) {
          throw BackendException('الطلب فيه منتجات أكتر من الحد المسموح (7)');
        }
        // (3) Re-read products + inventory; stock/price re-check
        // against the DATABASE prices and the price the customer saw.
        final lines = <Map<String, dynamic>>[];
        for (final line in merged) {
          final productId = (line['productId'] ?? '') as String;
          final qty = ((line['qty'] ?? 0) as num).toInt();
          if (qty < 1 || qty > maxQtyPerLine) {
            throw BackendException('الكمية لازم تكون بين 1 و 20');
          }
          final productSnap =
              await tx.get(db.collection('products').doc(productId));
          if (!productSnap.exists) {
            throw BackendException('منتج مش موجود في المتجر');
          }
          final product = productSnap.data() ?? {};
          final rawPrice = (product['price'] ?? 0) as num;
          if (!rawPrice.isFinite || rawPrice <= 0) {
            throw BackendException('سعر المنتج مش صحيح');
          }
          final price = wholeNum(rawPrice);
          final rawBase = product['basePrice'];
          var basePrice = rawBase is num ? rawBase.toInt() : null;
          if (basePrice != null && basePrice <= price) basePrice = null;
          final invSnap =
              await tx.get(db.collection('inventory').doc(productId));
          final inv = invSnap.data() ?? {};
          final stock = ((inv['stock'] ?? 0) as num).toInt();
          final reserved = ((inv['reserved'] ?? 0) as num).toInt();
          final available = stock - reserved;
          if (qty > available) {
            return {
              'result': 'INSUFFICIENT_STOCK',
              'productId': productId,
              'productName': (product['name'] ?? productId) as String,
              'availableQty': available < 0 ? 0 : available,
              'created': false,
              'newInStock': <String, bool>{},
            };
          }
          final priceAtDraft = (cart
                  .firstWhere((l) => (l['productId'] ?? '') == productId,
                      orElse: () => <String, dynamic>{})['priceAtDraft'] as num?)
              ?.toInt();
          if (priceAtDraft != null && wholeNum(price) != priceAtDraft) {
            return {
              'result': 'PRICE_CHANGED',
              'productId': productId,
              'productName': (product['name'] ?? productId) as String,
              'oldPrice': priceAtDraft,
              'newPrice': wholeNum(price),
              'created': false,
              'newInStock': <String, bool>{},
            };
          }
          lines.add({
            'productId': productId,
            'name': (product['name'] ?? '') as String,
            'price': price,
            'basePrice': basePrice,
            'qty': qty,
            'stock': stock,
            'reserved': reserved,
            'minStock': ((inv['minStock'] ?? 5) as num).toInt(),
            'costPrice': ((inv['costPrice'] ?? 0) as num).toInt(),
          });
        }
        // Delivery fee from settings (fee-default-free, decision
        // 2026-11-27: an unset fee means free delivery, so a
        // conversion is never blocked on it).
        final settingsSnap =
            await tx.get(db.collection('storeSettings').doc('settings'));
        final feeSettings =
            parseDeliveryFeeSettings(settingsSnap.data());
        final deliveryFee = feeSettings.deliveryFee;
        final computed = computeOrderTotals(
          lines
              .map((l) => {
                    'price': l['price'] as num,
                    'qty': l['qty'] as int,
                    'basePrice': l['basePrice'] as int?,
                  })
              .toList(),
          deliveryFee: deliveryFee,
          freeDeliveryThreshold: feeSettings.freeDeliveryThreshold,
        );
        final effectiveFee = computed.deliveryFee ?? deliveryFee;
        final now = FieldValue.serverTimestamp();
        // The audit id is minted here (client-side random id) so the
        // order can carry it as auditId; the entry itself is written
        // post-commit (M1 audit-split, see below).
        final auditId = db.collection('audit').doc().id;
        final hasBasePrice = lines.any((l) => l['basePrice'] != null);
        final orderDocIds = <String, List<String>>{
          'orders/$draftId': orderAuditFields(hasBasePrice: hasBasePrice),
        };
        final orderNewValues = <String, dynamic>{
          'status': 'new',
          'total': wholeNum(computed.total),
          'saleSavings': wholeNum(computed.saleSavings),
          'deliveryFee': effectiveFee,
          'amountDue': wholeNum(computed.amountDue!),
        };
        final newValuesByDoc = <String, Map<String, dynamic>>{
          'orders/$draftId': {
            ...orderNewValues,
            if (hasBasePrice)
              'items': lines
                  .map((l) => {
                        'productId': l['productId'],
                        'name': l['name'],
                        'price': l['price'],
                        'basePrice': l['basePrice'],
                        'qty': l['qty'],
                      })
                  .toList(),
          },
        };
        final documents = <Map<String, dynamic>>[];
        final newInStock = <String, bool>{};
        // (4) Reserve stock (absolute set, merge). The rules enforce
        // reserved <= stock, so an over-reservation is denied.
        for (final line in lines) {
          final productId = (line['productId'] ?? '') as String;
          final qty = (line['qty'] ?? 0) as int;
          final stock = (line['stock'] ?? 0) as int;
          final reserved = (line['reserved'] ?? 0) as int;
          final newReserved = reserved + qty;
          newInStock[productId] = (stock - newReserved) > 0;
          final invRef = db.collection('inventory').doc(productId);
          tx.set(invRef, {
            'productId': productId,
            'stock': stock,
            'reserved': newReserved,
            'minStock': ((line['minStock'] ?? 5) as num).toInt(),
            'costPrice': ((line['costPrice'] ?? 0) as num).toInt(),
            'operationId': auditId,
            'updatedAt': now,
          }, SetOptions(merge: true));
          // M1 (2026-11-27, Option 3): the movement-ledger write
          // for the reserve left this transaction — it is written
          // post-commit by _writeOrderMovementsAndAudit.
          orderDocIds['inventory/$productId'] = [
            'productId',
            'stock',
            'reserved',
            'minStock',
            'costPrice',
            'operationId',
            'updatedAt',
          ];
          newValuesByDoc['inventory/$productId'] = {
            'stock': stock,
            'reserved': newReserved,
          };
          documents.add({
            'collection': 'inventory',
            'docId': productId,
            'changedFields': ['reserved', 'stock'],
            'oldValues': {'stock': stock, 'reserved': reserved},
            'newValues': {'stock': stock, 'reserved': newReserved},
          });
        }
        // Create the order (doc id = draft id), same field list as
        // createManualOrder, PLUS the draft's contact fields
        // (backup phone, governorate, detailed address).
        final order = <String, dynamic>{
          'id': draftId,
          'clientOrderId': draftId,
          'customerName': customerName.trim(),
          'customerPhone': customerPhone.trim(),
          'customerPhone2': (customerPhone2 ?? '').trim().isEmpty
              ? null
              : customerPhone2!.trim(),
          'governorate': (governorate ?? '').trim().isEmpty
              ? null
              : governorate!.trim(),
          'detailedAddress': (detailedAddress ?? '').trim().isEmpty
              ? null
              : detailedAddress!.trim(),
          'customerAddress': customerAddress.trim(),
          'items': lines
              .map((l) => {
                    'productId': l['productId'],
                    'name': l['name'],
                    'price': l['price'],
                    'basePrice': l['basePrice'],
                    'qty': l['qty'],
                  })
              .toList(),
          'subtotal': wholeNum(computed.subtotal),
          'total': wholeNum(computed.total),
          'saleSavings': wholeNum(computed.saleSavings),
          'deliveryFee': effectiveFee,
          'amountDue': wholeNum(computed.amountDue!),
          'status': 'new',
          'paymentStatus': 'cod_pending',
          'source': 'admin_manual',
          'createdBy': uid,
          'shippingCompanyId': (shippingCompanyId ?? '').trim().isEmpty
              ? null
              : shippingCompanyId!.trim(),
          'trackingNumber': null,
          'notes': (notes ?? '').trim().isEmpty ? null : notes!.trim(),
          'createdAt': now,
          'updatedAt': now,
          'acceptedAt': null,
          'deliveredAt': null,
          'cancelledAt': null,
          'cancelReason': null,
          'auditId': auditId,
        };
        tx.set(orderRef, order);
        documents.insert(0, {
          'collection': 'orders',
          'docId': draftId,
          'changedFields': orderDocIds['orders/$draftId']!,
          'oldValues': {},
          'newValues': orderNewValues,
        });
        // M1 (2026-11-27, audit-split): the audit entry is NOT
        // written inside this transaction any more — it is built
        // here, returned, and written AFTER the order commits by
        // _writeOrderMovementsAndAudit (best-effort, retry, never
        // throws). Same fields as the old in-tx write, except the
        // timestamp: the audit-create rule requires
        // timestamp == request.time of the audit write itself, so
        // the helper stamps a FRESH server timestamp at write time
        // instead of reusing the transaction's `now`.
        final auditEntry = <String, dynamic>{
          'operationId': auditId,
          'actor': uid,
          'actorName': email,
          'collection': 'orders',
          'docId': draftId,
          'operation': 'manual_order_create',
          'changedFields': orderDocIds.values.expand((e) => e).toSet().toList(),
          'oldValues': {},
          'newValues': orderNewValues,
          'docIds': orderDocIds,
          'newValuesByDoc': newValuesByDoc,
          'documents': documents,
          'source': 'convertDraft',
        };
        // Mark the draft converted (orderId = the new order id).
        tx.set(draftRef, {
          'status': 'converted',
          'orderId': draftId,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        return {
          'result': 'ok',
          'order': order,
          'created': true,
          'newInStock': newInStock,
          'auditId': auditId,
          'auditEntry': auditEntry,
          'movementLines': lines
              .map((l) => {
                    'productId': l['productId'],
                    'qty': l['qty'],
                  })
              .toList(),
        };
      });
    } on BackendException {
      rethrow;
    } on FirebaseException catch (e) {
      Diagnostics.instance.log('Draft conversion failed: ${e.code} ${e.message}');
      if (e.code == 'permission-denied') {
        throw BackendException(
            'تعذر تحويل المسودة — الكمية أكبر من المتاح أو البيانات مرفوضة، راجع الكميات وحاول تاني');
      }
      throw BackendException('تعذر تحويل المسودة: ${e.message ?? e.code}');
    }
    if (result['created'] == true) {
      Diagnostics.instance.log('Draft converted to order: $draftId');
      await _refreshInStock(
          (result['newInStock'] as Map<String, bool>?) ?? {});
      // M1: movements + audit AFTER the commit, only on a real
      // create — never on an idempotent retry / moot / insufficient
      // stock / price-changed return (created == false) and never
      // when the transaction threw (we never get here). Best-effort:
      // a failure is logged, the order stands, and the
      // orphan-orders check repairs the missing audit entry.
      await _writeOrderMovementsAndAudit(
        auditId: (result['auditId'] ?? '') as String,
        auditEntry:
            (result['auditEntry'] as Map<String, dynamic>?) ?? const {},
        movementLines: (result['movementLines'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .toList() ??
            const [],
        orderId: draftId,
        source: 'convertDraft',
        actorUid: uid,
      );
    }
    return result;
  }

  // ---- Orphan orders (M1 audit-split backstop, 2026-11-27) ----
  //
  // The audit entry is written AFTER the order commits now, so a
  // crash (or a failed post-commit write) can leave an order with
  // no matching audit entry — an "orphan". The check below is the
  // on-demand backstop: bounded to the most recent 100 orders, run
  // only when an admin taps the button in the Orders tab.

  /// The most recent [limit] orders (newest first) whose audit
  /// entry is missing: no audit doc exists for the order's auditId,
  /// or the order carries no auditId at all. Each entry is the
  /// order map plus its 'id'.
  Future<List<Map<String, dynamic>>> findOrphanOrders({int limit = 100}) async {
    _requireInit();
    final snap = await db
        .collection('orders')
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get();
    final orders = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
    // One audit get per order, in parallel — a sequential walk over
    // 100 orders would take seconds.
    final auditSnaps =
        await Future.wait<DocumentSnapshot<Map<String, dynamic>>?>(
      orders.map((o) async {
        final auditId = (o['auditId'] ?? '') as String;
        if (auditId.isEmpty) return null;
        return db.collection('audit').doc(auditId).get();
      }),
    );
    final orphans = <Map<String, dynamic>>[];
    for (var i = 0; i < orders.length; i++) {
      final auditSnap = auditSnaps[i];
      if (auditSnap == null || !auditSnap.exists) orphans.add(orders[i]);
    }
    return orphans;
  }

  /// Builds the audit entry that repairs one orphan [order]: the
  /// same money-field coverage as the original order audit entry
  /// (status, total, saleSavings, deliveryFee, amountDue, plus
  /// 'items' when any line has a non-null basePrice), plus the
  /// markers `repaired: true` and `originalCreatedAt` (the order's
  /// createdAt).
  ///
  /// DESIGN CORRECTION (vs the design doc §2, which says "actor =
  /// the order's creator, timestamp = the order's createdAt"): that
  /// literal spec cannot pass the audit-create rule (firestore.rules
  /// match /audit) — the admin branch requires timestamp ==
  /// request.time (a past createdAt would be denied) and actor ==
  /// request.auth.uid (a storefront order's creator is anonymous —
  /// there is no uid). So the repair uses the REPAIRING admin
  /// (actor = [actorUid], actorName = [actorEmail]) and a FRESH
  /// serverTimestamp() at repair time; the original values are
  /// preserved in the markers instead.
  Map<String, dynamic> orphanRepairAuditEntry({
    required Map<String, dynamic> order,
    required String auditId,
    required String actorUid,
    required String actorEmail,
  }) {
    final hasBasePrice =
        ((order['items'] as List?) ?? []).any((it) =>
            it is Map<String, dynamic> && it['basePrice'] != null);
    final orderFields = orderAuditFields(hasBasePrice: hasBasePrice);
    final orderNewValues = <String, dynamic>{
      'status': order['status'] ?? 'new',
      'total': order['total'],
      'saleSavings': order['saleSavings'],
      'deliveryFee': order['deliveryFee'],
      'amountDue': order['amountDue'],
      if (hasBasePrice) 'items': order['items'],
    };
    return {
      'operationId': auditId,
      'actor': actorUid,
      'actorName': actorEmail,
      'timestamp': FieldValue.serverTimestamp(),
      'collection': 'orders',
      'docId': order['id'],
      'operation': order['source'] == 'storefront'
          ? 'create'
          : 'manual_order_create',
      'changedFields': orderFields,
      'oldValues': {},
      'newValues': {
        'status': order['status'] ?? 'new',
        'total': order['total'],
        'saleSavings': order['saleSavings'],
        'deliveryFee': order['deliveryFee'],
        'amountDue': order['amountDue'],
      },
      'docIds': {'orders/${order['id']}': orderFields},
      'newValuesByDoc': {'orders/${order['id']}': orderNewValues},
      'documents': [
        {
          'collection': 'orders',
          'docId': order['id'],
          'changedFields': orderFields,
          'oldValues': {},
          'newValues': orderNewValues,
        },
      ],
      'source': 'repairOrphanOrder',
      'repaired': true,
      'originalCreatedAt': order['createdAt'],
    };
  }

  /// Writes the missing audit entry for one orphan [order] and
  /// returns true. Returns false (no write) when the entry already
  /// exists — another admin repaired it first, or the check raced
  /// the post-commit write. Throws [BackendException] when the
  /// write itself fails, so the UI can show the error. The entry
  /// shape is built by [orphanRepairAuditEntry]; the actor is the
  /// REPAIRING admin (see the design correction in that method's
  /// docs).
  Future<bool> repairOrphanOrder(Map<String, dynamic> order) async {
    _requireInit();
    final uid = auth.currentUser?.uid;
    if (uid == null) throw BackendException('سجّل الدخول الأول');
    final email = auth.currentUser?.email ?? '';
    var auditId = (order['auditId'] ?? '') as String;
    var newAuditId = false;
    if (auditId.isEmpty) {
      // A pre-audit order carries no auditId at all: mint one and
      // stamp it on the order, so a re-check sees it as repaired.
      auditId = db.collection('audit').doc().id;
      newAuditId = true;
    }
    final existing = await db.collection('audit').doc(auditId).get();
    if (existing.exists) return false;
    final entry = orphanRepairAuditEntry(
      order: order,
      auditId: auditId,
      actorUid: uid,
      actorEmail: email,
    );
    try {
      await db.collection('audit').doc(auditId).set(entry);
    } on FirebaseException catch (e) {
      Diagnostics.instance.log(
          'Orphan repair failed (${order['id']}): ${e.code} ${e.message}');
      throw BackendException('تعذر إصلاح الطلب: ${e.message ?? e.code}');
    }
    if (newAuditId) {
      // The audited batch carries its own audit entry for the
      // auditId change, so this order update is self-consistent.
      await _auditedBatch(
        writes: {'orders/${order['id']}': {'auditId': auditId}},
        sensitive: const {},
        operation: 'update',
      );
    }
    Diagnostics.instance.log(
        'Orphan order repaired: ${order['id']} (audit $auditId)');
    return true;
  }

  // ---- Governorates + deletion config + quota (settings) ----

  /// Live governorate list (one doc, all 27, stable ids + active
  /// flags). The screen falls back to [governorateFallback] when the
  /// doc is missing.
  Stream<DocumentSnapshot<Map<String, dynamic>>> governoratesStream() =>
      db.collection('storeSettings').doc('governorates').snapshots();

  /// Save the governorate activation list (merge-only, audited).
  Future<void> saveGovernorates(List<Map<String, dynamic>> entries) async {
    _requireInit();
    if (entries.length > 27) {
      throw BackendException('المحافظات 27 بس');
    }
    await _auditedBatch(
      writes: {
        'storeSettings/governorates': {'entries': entries},
      },
      sensitive: const {},
      operation: 'update',
    );
    Diagnostics.instance.log('Governorates saved (${entries.length} entries)');
  }

  /// Live deletion config (autoDeleteDays, 0 = manual only).
  Stream<DocumentSnapshot<Map<String, dynamic>>> deletionConfigStream() =>
      db.collection('storeSettings').doc('deletion').snapshots();

  /// Save the scheduled auto-delete (X days, 0 = manual only).
  Future<void> saveDeletionConfig(int autoDeleteDays) async {
    _requireInit();
    if (autoDeleteDays < 0 || autoDeleteDays > 365) {
      throw BackendException('عدد الأيام لازم يكون بين 0 و 365');
    }
    await _auditedBatch(
      writes: {
        'storeSettings/deletion': {'autoDeleteDays': autoDeleteDays},
      },
      sensitive: const {},
      operation: 'update',
    );
    Diagnostics.instance.log('Deletion config saved: $autoDeleteDays days');
  }

  /// Live quota doc (cutoffLevel + dailyEstimate).
  Stream<DocumentSnapshot<Map<String, dynamic>>> quotaStream() =>
      db.collection('storeSettings').doc('quota').snapshots();

  /// Manual quota cut-off flip: 'none' | 'journeys' | 'drafts'.
  /// Order writes are never cut.
  Future<void> setQuotaCutoff(String level) async {
    _requireInit();
    if (!['none', 'journeys', 'drafts'].contains(level)) {
      throw BackendException('مستوى الإيقاف مش صحيح');
    }
    await _auditedBatch(
      writes: {
        'storeSettings/quota': {'cutoffLevel': level},
      },
      sensitive: const {},
      operation: 'update',
    );
    Diagnostics.instance.log('Quota cutoff -> $level');
  }

  /// Rough daily write estimate (drafts + journey summaries created
  /// today, ~2 writes each: create + one update). Count queries only,
  /// no invented visits — visits come from GA4, not Firestore.
  Future<({int draftsToday, int journeysToday, int estimatedWrites})>
      dailyWriteEstimate() async {
    _requireInit();
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final start = Timestamp.fromDate(startOfDay);
    final draftsSnap = await db
        .collection('checkoutDrafts')
        .where('createdAt', isGreaterThanOrEqualTo: start)
        .count()
        .get();
    final journeysSnap = await db
        .collection('journeySummaries')
        .where('startedAt', isGreaterThanOrEqualTo: start)
        .count()
        .get();
    final draftsToday = draftsSnap.count ?? 0;
    final journeysToday = journeysSnap.count ?? 0;
    return (
      draftsToday: draftsToday,
      journeysToday: journeysToday,
      estimatedWrites: draftsToday * 2 + journeysToday * 2,
    );
  }

  /// Exports products + orders + derived customers + store settings as
  /// plain JSON-ready data — the v1 backup path. This runs entirely in
  /// the app (no bucket, no billing). Firestore's managed export to a
  /// storage bucket is Blaze-gated and is NOT the v1 path.
  Future<Map<String, dynamic>> exportAll() async {
    _requireInit();
    final productsSnap = await db.collection('products').get();
    final ordersSnap = await db.collection('orders').get();
    final settingsSnap = await db.collection('storeSettings').doc('settings').get();
    final products = productsSnap.docs.map((d) => _jsonDoc(d.id, d.data())).toList();
    final orders = ordersSnap.docs.map((d) => _jsonDoc(d.id, d.data())).toList();
    return {
      'exportedAt': DateTime.now().toIso8601String(),
      'storeSettings': settingsSnap.data() == null
          ? {}
          : _jsonDoc('settings', settingsSnap.data()!),
      'products': products,
      'orders': orders,
      'customers': deriveCustomers(orders),
    };
  }

  static Map<String, dynamic> _jsonDoc(String id, Map<String, dynamic> data) {
    return {'id': id, ..._jsonValue(data) as Map<String, dynamic>};
  }

  static dynamic _jsonValue(dynamic value) {
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _jsonValue(v)));
    }
    if (value is List) return value.map(_jsonValue).toList();
    return value;
  }
  Future<int> seedSamplesIfEmpty({
    required List<Map<String, dynamic>> categories,
    required List<Map<String, dynamic>> products,
  }) async {
    _requireInit();
    final existing = await db.collection('products').limit(1).get();
    if (existing.docs.isNotEmpty) return 0;
    // Phase 2: the seed writes go through the audited batch too — the
    // rules deny any admin write without its audit entry.
    final writes = <String, Map<String, dynamic>>{};
    final catIds = <String, String>{};
    for (final c in categories) {
      final id = db.collection('categories').doc().id;
      catIds[c['id'] as String] = id;
      writes['categories/$id'] = {
        'name': c['name'],
        'createdAt': FieldValue.serverTimestamp(),
      };
    }
    for (final p in products) {
      final id = db.collection('products').doc().id;
      writes['products/$id'] = {
        'name': p['name'],
        'price': p['price'],
        'description': p['description'],
        'categoryId': catIds[p['categoryId']] ?? '',
        'images': <Map<String, dynamic>>[],
        'createdAt': FieldValue.serverTimestamp(),
      };
    }
    await _auditedBatch(
      writes: writes,
      sensitive: {
        for (final e in writes.entries)
          if (e.key.startsWith('products/')) e.key: {'price': e.value['price']},
      },
      operation: 'create',
    );
    return products.length;
  }
}
