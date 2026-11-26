// Backend service: Firebase Auth + Firestore for the Store project.
// All failures are logged to Diagnostics with their real reason and
// rethrown as plain-language messages — never swallowed silently.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
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
  });
  final String id;
  final String name;
  final double price;
  final String description;
  final String categoryId;

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

  /// Maps a callable's structured error (details.code) to a plain
  /// Arabic message for the screen. The code is the stable machine
  /// code the function returns; the message is what the admin sees.
  String _friendlyCallableError(FirebaseFunctionsException e) {
    final details = e.details;
    final code = (details is Map ? details['code'] : null) as String? ?? e.code;
    switch (code) {
      case 'PRICE_CHANGED':
        return 'اتغير سعر منتج من اللي شفتهم — راجع الأسعار وحاول تاني';
      case 'TOTAL_CHANGED':
        return 'اتغير الإجمالي — راجع الإجمالي وحاول تاني';
      case 'INSUFFICIENT_STOCK':
        return 'الكمية المطلوبة أكبر من المتاح في المخزون';
      case 'DISCOUNT_INVALID':
        return 'كود الخصم مش صحيح';
      case 'DISCOUNT_USED':
        return 'كود الخصم ده اتستخدم قبل كده';
      case 'ORDER_TOO_LARGE':
        return 'الطلب فيه منتجات أكتر من الحد المسموح (10)';
      case 'RATE_LIMITED':
        return 'محاولات كتير في وقت قصير — استنى شوية وحاول تاني';
      case 'PERMISSION_DENIED':
        return 'ماعندكش صلاحية تعمل العملية دي';
      case 'NOT_FOUND':
        return 'البيانات المطلوبة مش موجودة';
      case 'BLOCKED':
        return 'الإرسال محظور مؤقتاً من الرقم ده';
      case 'INVALID_INPUT':
        return 'البيانات مش كاملة أو مش صحيحة';
      default:
        return 'حصل خطأ: $code';
    }
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
    final data = <String, dynamic>{
      'name': p.name,
      'price': p.price,
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
    'cancelled': [],
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
  /// release the reservation; deliver → release + deduct from stock)
  /// run inside ONE transaction that updates inventory, inStock,
  /// movements, the order, and the audit entry atomically (v1.4 §6.3).
  /// Pure status steps (accept → prepare → ready → in transit) are an
  /// audited batch on the order alone. The lifecycle timestamps
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
      await db.runTransaction((tx) async {
        final freshSnap = await tx.get(orderRef);
        final fresh = freshSnap.data();
        if (fresh == null) throw BackendException('الطلب مش موجود');
        if ((fresh['status'] ?? '') != from) {
          throw BackendException('الطلب اتغير من حد تاني — حدّث الصفحة وحاول تاني');
        }
        final auditRef = db.collection('audit').doc();
        final opId = auditRef.id;
        final now = FieldValue.serverTimestamp();
        final docIds = <String, List<String>>{
          'orders/$id': ['status', 'operationId', 'updatedAt'],
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
            'type': status == 'delivered' ? 'order_deliver' : 'order_cancel',
            'qty': status == 'delivered' ? -qty : qty,
            'orderId': id,
            'source': 'flutter_admin',
            'actorUid': auth.currentUser?.uid,
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
        final orderUpdate = <String, dynamic>{
          'status': status,
          'operationId': opId,
          'updatedAt': now,
        };
        if (status == 'accepted') orderUpdate['acceptedAt'] = now;
        if (status == 'delivered') orderUpdate['deliveredAt'] = now;
        if (status == 'cancelled' || status == 'expired') {
          orderUpdate['cancelledAt'] = now;
          orderUpdate['cancelReason'] = reason ?? (status == 'expired' ? 'reservation_expired' : 'cancelled_by_admin');
        }
        tx.set(orderRef, orderUpdate, SetOptions(merge: true));
        documents.insert(0, {
          'collection': 'orders',
          'docId': id,
          'changedFields': ['status'],
          'oldValues': {'status': from},
          'newValues': {'status': status},
        });
        tx.set(auditRef, {
          'operationId': opId,
          'actor': auth.currentUser?.uid ?? '',
          'actorName': auth.currentUser?.email ?? '',
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
          'source': 'flutter_admin',
        });
      });
      Diagnostics.instance.log('Order $id: $from -> $status (stock moved)');
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
  /// inStock}. The admin apps read it for the stock-visibility
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

  // ---- Callables: manual orders + feedback (v1.4 §6/§8) ----

  /// Creates an order on behalf of a customer (phone order). Runs the
  /// same trusted path as the storefront's placeOrder — same price /
  /// stock / discount validation, same reservation, same idempotency,
  /// same audit — with source 'admin_manual'. The form sends NO price,
  /// total, or discount-percent fields; a discount applies only via a
  /// code. The function re-checks the orders_create_manual permission
  /// server-side (the UI check in hasPermission() is not security).
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
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('createManualOrder');
      final res = await callable.call(<String, dynamic>{
        'clientOrderId': clientOrderId,
        'items': items,
        'discountCode': discountCode,
        'customer': {
          'name': customerName,
          'phone': customerPhone,
          'address': customerAddress,
        },
        'shippingCompanyId': shippingCompanyId,
        'notes': notes,
      });
      Diagnostics.instance.log('Manual order created: $clientOrderId');
      return Map<String, dynamic>.from(res.data as Map);
    } on FirebaseFunctionsException catch (e) {
      Diagnostics.instance.log('Manual order failed: ${e.code}');
      throw BackendException(_friendlyCallableError(e));
    }
  }

  /// Creates a feedback record on behalf of a customer (phone
  /// complaint). The storefront form itself lands in Phase 3; this is
  /// the Flutter manual-creation path (v1.4 §8). Returns the tracking
  /// code (and duplicate:true when the same phone + message was
  /// already submitted within 24h).
  Future<Map<String, dynamic>> submitFeedback({
    required String submissionId,
    required String type,
    required String category,
    required String title,
    required String message,
    String? orderId,
    String? phone,
  }) async {
    _requireInit();
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('submitFeedback');
      final res = await callable.call(<String, dynamic>{
        'submissionId': submissionId,
        'type': type,
        'category': category,
        'title': title,
        'message': message,
        'orderId': orderId,
        'phone': phone,
      });
      return Map<String, dynamic>.from(res.data as Map);
    } on FirebaseFunctionsException catch (e) {
      Diagnostics.instance.log('submitFeedback failed: ${e.code}');
      throw BackendException(_friendlyCallableError(e));
    }
  }

  /// Tracking-code lookup (tracking code + phone). Returns only
  /// {status, lastReply} — the function never says which part failed.
  Future<Map<String, dynamic>> getFeedbackStatus({
    required String trackingCode,
    required String phone,
  }) async {
    _requireInit();
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('getFeedbackStatus');
      final res = await callable.call(<String, dynamic>{
        'trackingCode': trackingCode,
        'phone': phone,
      });
      return Map<String, dynamic>.from(res.data as Map);
    } on FirebaseFunctionsException catch (e) {
      Diagnostics.instance.log('getFeedbackStatus failed: ${e.code}');
      throw BackendException(_friendlyCallableError(e));
    }
  }

  // ---- Feedback (admin side) ----

  static const Map<String, List<String>> feedbackTransitions = {
    'new': ['in_review', 'rejected', 'spam'],
    'in_review': ['awaiting_customer', 'resolved', 'rejected', 'spam'],
    'awaiting_customer': ['resolved', 'in_review'],
    'resolved': ['closed'],
    'closed': [],
    'rejected': [],
    'spam': [],
  };

  static bool isAllowedFeedbackTransition(String from, String to) =>
      (feedbackTransitions[from] ?? []).contains(to);

  static const Map<String, String> feedbackStatusLabels = {
    'new': 'جديدة',
    'in_review': 'قيد المراجعة',
    'awaiting_customer': 'بانتظار العميل',
    'resolved': 'تم الحل',
    'closed': 'مغلقة',
    'rejected': 'مرفوضة',
    'spam': 'سبام',
  };

  static const Map<String, String> feedbackPriorityLabels = {
    'low': 'عادية',
    'medium': 'متوسطة',
    'high': 'عالية',
    'urgent': 'عاجلة',
  };

  Stream<QuerySnapshot<Map<String, dynamic>>> feedbackStream() => db
      .collection('feedback')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> feedbackRepliesStream(String feedbackId) => db
      .collection('feedback')
      .doc(feedbackId)
      .collection('replies')
      .orderBy('createdAt')
      .snapshots();

  /// Moves a feedback record to [status] (state-machine validated;
  /// the rules enforce it too).
  Future<void> setFeedbackStatus(String id, String status) async {
    _requireInit();
    final snap = await db.collection('feedback').doc(id).get();
    final data = snap.data();
    if (data == null) throw BackendException('الشكوى مش موجودة');
    final from = (data['status'] ?? '') as String;
    if (!isAllowedFeedbackTransition(from, status)) {
      throw BackendException('مينفعش تنقل الشكوى من ${feedbackStatusLabels[from] ?? from} لـ ${feedbackStatusLabels[status] ?? status}');
    }
    await _auditedBatch(
      writes: {'feedback/$id': {'status': status}},
      sensitive: {'feedback/$id': {'status': status}},
      operation: 'feedback_status',
      oldValues: {'feedback/$id': {'status': from}},
      topNewValues: {'status': status},
    );
  }

  /// Sets the priority. 'urgent' is admin-only in the rules — the
  /// screen checks the role first and the rules deny a manager anyway.
  Future<void> setFeedbackPriority(String id, String priority) async {
    _requireInit();
    if (!{'low', 'medium', 'high', 'urgent'}.contains(priority)) {
      throw BackendException('الأولوية مش صحيحة');
    }
    await _auditedBatch(
      writes: {'feedback/$id': {'priority': priority}},
      sensitive: const {},
      operation: 'feedback_status',
    );
  }

  /// Admin reply on a feedback record. The reply is written to the
  /// replies subcollection in the SAME batch as the feedback update
  /// (repliesCount + lastReplyAt, plus a status move when [newStatus]
  /// is given) and the audit entry — so a reply never lands without
  /// its audit. The reply record shape is defined once in the
  /// functions (buildReplyRecord); the app writes the same shape.
  Future<void> replyToFeedback(String id, String text, {String? newStatus}) async {
    _requireInit();
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw BackendException('اكتب الرد الأول');
    final snap = await db.collection('feedback').doc(id).get();
    final data = snap.data();
    if (data == null) throw BackendException('الشكوى مش موجودة');
    final from = (data['status'] ?? '') as String;
    if (newStatus != null && !isAllowedFeedbackTransition(from, newStatus)) {
      throw BackendException('مينفعش تنقل الشكوى من ${feedbackStatusLabels[from] ?? from} لـ ${feedbackStatusLabels[newStatus] ?? newStatus}');
    }
    final batch = db.batch();
    final auditRef = db.collection('audit').doc();
    final opId = auditRef.id;
    final now = FieldValue.serverTimestamp();
    final replyRef = db.collection('feedback').doc(id).collection('replies').doc();
    batch.set(replyRef, {
      'adminUid': auth.currentUser?.uid ?? '',
      'adminName': auth.currentUser?.email ?? '',
      'text': trimmed,
      'createdAt': now,
      'visibleToCustomer': true,
    });
    final update = <String, dynamic>{
      'repliesCount': FieldValue.increment(1),
      'lastReplyAt': now,
      'operationId': opId,
      'updatedAt': now,
    };
    if (newStatus != null) update['status'] = newStatus;
    batch.set(db.collection('feedback').doc(id), update, SetOptions(merge: true));
    final changed = update.keys.toList();
    batch.set(auditRef, {
      'operationId': opId,
      'actor': auth.currentUser?.uid ?? '',
      'actorName': auth.currentUser?.email ?? '',
      'timestamp': now,
      'collection': 'feedback',
      'docId': id,
      'operation': 'feedback_reply',
      'changedFields': changed,
      'oldValues': {'status': from},
      'newValues': newStatus == null ? {} : {'status': newStatus},
      'docIds': {'feedback/$id': changed},
      'newValuesByDoc': {
        'feedback/$id': newStatus == null ? {} : {'status': newStatus},
      },
      'documents': [
        {
          'collection': 'feedback',
          'docId': id,
          'changedFields': changed,
          'oldValues': {'status': from},
          'newValues': newStatus == null ? {} : {'status': newStatus},
        }
      ],
      'source': 'flutter_admin',
    });
    try {
      await batch.commit();
    } on FirebaseException catch (e) {
      Diagnostics.instance.log('Feedback reply failed: ${e.code} ${e.message}');
      throw BackendException('تعذر إرسال الرد: ${e.message ?? e.code}');
    }
  }

  /// Marks a feedback record as spam AND blocks the sender's phone for
  /// 24 hours (feedbackBlocks). Both writes happen in one batch with
  /// the audit entry. The block key is `phone:<normalized phone>`.
  Future<void> markFeedbackSpam(String id) async {
    _requireInit();
    final snap = await db.collection('feedback').doc(id).get();
    final data = snap.data();
    if (data == null) throw BackendException('الشكوى مش موجودة');
    final from = (data['status'] ?? '') as String;
    if (!isAllowedFeedbackTransition(from, 'spam')) {
      throw BackendException('مينفعش تحوّل الشكوى دي لسبام من الحالة دي');
    }
    final customerRef = (data['customerRef'] as Map<String, dynamic>?) ?? {};
    final phone = (customerRef['phone'] ?? '') as String;
    final batch = db.batch();
    final auditRef = db.collection('audit').doc();
    final opId = auditRef.id;
    final now = FieldValue.serverTimestamp();
    batch.set(db.collection('feedback').doc(id), {
      'status': 'spam',
      'operationId': opId,
      'updatedAt': now,
    }, SetOptions(merge: true));
    if (phone.isNotEmpty) {
      batch.set(db.collection('feedbackBlocks').doc('phone:$phone'), {
        'type': 'phone',
        'value': phone,
        'blockedUntil': Timestamp.fromDate(DateTime.now().add(const Duration(hours: 24))),
        'reason': 'spam',
        'blockedBy': auth.currentUser?.uid ?? '',
        'createdAt': now,
      });
    }
    batch.set(auditRef, {
      'operationId': opId,
      'actor': auth.currentUser?.uid ?? '',
      'actorName': auth.currentUser?.email ?? '',
      'timestamp': now,
      'collection': 'feedback',
      'docId': id,
      'operation': 'feedback_status',
      'changedFields': ['status', 'operationId', 'updatedAt'],
      'oldValues': {'status': from},
      'newValues': {'status': 'spam'},
      'docIds': {'feedback/$id': ['status', 'operationId', 'updatedAt']},
      'newValuesByDoc': {'feedback/$id': {'status': 'spam'}},
      'documents': [
        {
          'collection': 'feedback',
          'docId': id,
          'changedFields': ['status'],
          'oldValues': {'status': from},
          'newValues': {'status': 'spam'},
        }
      ],
      'source': 'flutter_admin',
    });
    try {
      await batch.commit();
    } on FirebaseException catch (e) {
      Diagnostics.instance.log('Mark spam failed: ${e.code} ${e.message}');
      throw BackendException('تعذر التحويل لسبام: ${e.message ?? e.code}');
    }
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
