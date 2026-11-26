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
    );
  }
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
  // 10 get()/getAfter() calls per operation, and the order-create
  // rule costs N+3 for a manual order, so an 8-line manual order
  // with a code is denied by the platform (7 lines = 10 calls,
  // the safe max). Same cap in the storefront + PC.
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

  /// Totals from DATABASE prices (contract §1 step 4):
  /// subtotal = Σ price*qty; discountAmount =
  /// round(subtotal * percent / 100); total = subtotal - discountAmount.
  /// [lines] are {'price': num, 'qty': int} with trusted prices.
  static ({num subtotal, int? discountPercent, num discountAmount, num total})
      computeOrderTotals(
    List<Map<String, dynamic>> lines,
    int? percent,
  ) {
    num subtotal = 0;
    for (final line in lines) {
      subtotal += ((line['price'] ?? 0) as num) * ((line['qty'] ?? 0) as num);
    }
    final p = percent ?? 0;
    final discountAmount = p == 0 ? 0 : (subtotal * p / 100).round();
    return (
      subtotal: subtotal,
      discountPercent: percent,
      discountAmount: discountAmount,
      total: subtotal - discountAmount,
    );
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
  /// exact keys name/email/address/message/createdAt).
  static String? validateFeedbackInput({
    required String name,
    required String email,
    required String address,
    required String message,
  }) {
    if (name.trim().isEmpty || name.trim().length > 100) {
      return 'اكتب الاسم (بحد أقصى 100 حرف)';
    }
    final mail = email.trim();
    if (mail.isEmpty || mail.length > 100 || !mail.contains('@')) {
      return 'اكتب إيميل صحيح';
    }
    if (address.trim().isEmpty || address.trim().length > 300) {
      return 'اكتب العنوان (بحد أقصى 300 حرف)';
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

  Future<void> saveProduct(ProductData p) async {
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
    final id = p.id.isEmpty ? db.collection('products').doc().id : p.id;
    if (p.id.isEmpty) {
      data['createdAt'] = FieldValue.serverTimestamp();
    }
    await _auditedBatch(
      writes: {'products/$id': data},
      sensitive: {
        'products/$id': {'price': p.price},
      },
      operation: p.id.isEmpty ? 'create' : 'update',
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
          final ran = await _stockMovingTransition(
            doc.id,
            'expired',
            from: 'new',
            reason: 'reservation_expired',
            actorUid: 'sweep',
            actorName: 'sweep',
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
  // transaction, the discount is claimed in the same transaction,
  // and the audit entry rides along (§4). Permission is checked
  // client-side here AND re-checked by the rules from admins/{uid}.
  // After the transaction commits, products.inStock is refreshed
  // by the §13 second write (batched, up to 3 tries, best-effort).
  // Returns {'order': {...}, 'created': bool} — created:false means
  // the clientOrderId already existed (idempotent retry).
  Future<Map<String, dynamic>> createManualOrder({
    required String clientOrderId,
    required List<Map<String, dynamic>> items,
    String? discountCode,
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
    final code = (discountCode ?? '').trim();
    Map<String, dynamic> result;
    try {
      result = await db.runTransaction<Map<String, dynamic>>((tx) async {
        final orderRef = db.collection('orders').doc(clientOrderId);
        // Idempotency first: a retry with the same clientOrderId
        // returns the existing order — no stock work, no discount
        // work, no duplicate.
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
            'qty': qty,
            'stock': stock,
            'reserved': reserved,
            'minStock': ((inv['minStock'] ?? 5) as num).toInt(),
            'costPrice': ((inv['costPrice'] ?? 0) as num).toInt(),
          });
        }
        // Discount: read the trusted record, verify, claim atomically.
        Map<String, dynamic>? discount;
        if (code.isNotEmpty) {
          final discSnap = await tx.get(db.collection('discounts').doc(code));
          if (!discSnap.exists) throw BackendException('كود الخصم مش صحيح');
          final record = discSnap.data() ?? {};
          if (record['active'] != true) {
            throw BackendException('كود الخصم مش فعال');
          }
          if (record['usedBy'] != null) {
            throw BackendException('كود الخصم ده اتستخدم قبل كده');
          }
          final expiresAt = record['expiresAt'];
          DateTime? expires;
          if (expiresAt is Timestamp) expires = expiresAt.toDate();
          if (expiresAt is num) {
            expires = DateTime.fromMillisecondsSinceEpoch(expiresAt.toInt());
          }
          if (expires != null && !expires.isAfter(DateTime.now())) {
            throw BackendException('كود الخصم انتهت صلاحيته');
          }
          final percent = ((record['percent'] ?? 0) as num).toInt();
          if (percent < 1 || percent > 100) {
            throw BackendException('كود الخصم مش صحيح');
          }
          discount = {'code': code, 'percent': percent};
        }
        // Totals from the DATABASE prices, never a client total.
        final computed = computeOrderTotals(
          lines
              .map((l) => {'price': l['price'] as num, 'qty': l['qty'] as int})
              .toList(),
          discount?['percent'] as int?,
        );
        final now = FieldValue.serverTimestamp();
        final auditRef = db.collection('audit').doc();
        final auditId = auditRef.id;
        final docIds = <String, List<String>>{
          'orders/$clientOrderId': ['status', 'total'],
        };
        final newValuesByDoc = <String, Map<String, dynamic>>{
          'orders/$clientOrderId': {
            'status': 'new',
            'total': wholeNum(computed.total),
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
          tx.set(db.collection('movements').doc(), {
            'productId': productId,
            'type': 'order_reserve',
            'qty': -qty,
            'orderId': clientOrderId,
            'source': 'createManualOrder',
            'actorUid': uid,
            'createdAt': now,
          });
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
        // Claim the discount (one use only, atomically in this tx).
        // Exactly usedBy + usedAt — the §3 claim shape, no
        // operationId on this write.
        if (discount != null) {
          tx.set(db.collection('discounts').doc(discount['code'] as String), {
            'usedBy': clientOrderId,
            'usedAt': now,
          }, SetOptions(merge: true));
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
                    'qty': l['qty'],
                  })
              .toList(),
          'subtotal': wholeNum(computed.subtotal),
          'discountCode': discount?['code'],
          'discountPercent': computed.discountPercent,
          'discountAmount': wholeNum(computed.discountAmount),
          'total': wholeNum(computed.total),
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
          'changedFields': ['status', 'total'],
          'oldValues': {},
          'newValues': {'status': 'new', 'total': wholeNum(computed.total)},
        });
        tx.set(auditRef, {
          'operationId': auditId,
          'actor': uid,
          'actorName': email,
          'timestamp': now,
          'collection': 'orders',
          'docId': clientOrderId,
          'operation': 'manual_order_create',
          'changedFields': docIds.values.expand((e) => e).toSet().toList(),
          'oldValues': {},
          'newValues': {'status': 'new', 'total': wholeNum(computed.total)},
          'docIds': docIds,
          'newValuesByDoc': newValuesByDoc,
          'documents': documents,
          'source': 'createManualOrder',
        });
        return {
          'order': order,
          'created': true,
          'newInStock': newInStock,
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

  // ---- Feedback, one-way cards (contract §6) ----
  //
  // No status, no priority, no replies, no tracking code, no lookup.
  // A complaint is a direct write of {name, email, address, message,
  // createdAt}; the admin only reads the cards and can delete spam.

  /// Creates a complaint on a customer's behalf (same one-way shape
  /// as the storefront contact form). Returns the new doc id.
  Future<String> submitFeedback({
    required String name,
    required String email,
    required String address,
    required String message,
  }) async {
    _requireInit();
    final error = validateFeedbackInput(
      name: name,
      email: email,
      address: address,
      message: message,
    );
    if (error != null) throw BackendException(error);
    final ref = db.collection('feedback').doc();
    try {
      await ref.set({
        'name': name.trim(),
        'email': email.trim(),
        'address': address.trim(),
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
      changedFields: const ['name', 'email', 'address', 'message', 'createdAt'],
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
