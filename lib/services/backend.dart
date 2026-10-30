// Backend service: Firebase Auth + Firestore for the Store project.
// All failures are logged to Diagnostics with their real reason and
// rethrown as plain-language messages — never swallowed silently.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

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
    Diagnostics.instance.log('Signed out');
  }

  // ---- Storefront content ----

  Stream<DocumentSnapshot<Map<String, dynamic>>> brandStream() =>
      db.collection('storeSettings').doc('settings').snapshots();

  Future<void> setBrand({required String brandName, String tagline = ''}) async {
    _requireInit();
    await db.collection('storeSettings').doc('settings').set(
      {'brandName': brandName, 'tagline': tagline, 'updatedAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> categoriesStream() =>
      db.collection('categories').orderBy('createdAt').snapshots();

  Future<void> addCategory(String name) async {
    _requireInit();
    await db.collection('categories').add({
      'name': name,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> renameCategory(String id, String name) async {
    _requireInit();
    await db.collection('categories').doc(id).update({'name': name});
  }

  Future<void> deleteCategory(String id) async {
    _requireInit();
    final products =
        await db.collection('products').where('categoryId', isEqualTo: id).limit(1).get();
    if (products.docs.isNotEmpty) {
      throw BackendException('القسم ده فيه منتجات — انقلها لقسم تاني الأول أو امسحها');
    }
    await db.collection('categories').doc(id).delete();
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
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (p.id.isEmpty) {
      data['createdAt'] = FieldValue.serverTimestamp();
      await db.collection('products').add(data);
    } else {
      await db.collection('products').doc(p.id).set(data, SetOptions(merge: true));
    }
  }

  Future<void> deleteProduct(String id) async {
    _requireInit();
    await db.collection('products').doc(id).delete();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> ordersStream() => db
      .collection('orders')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  Future<void> setOrderStatus(String id, String status) async {
    _requireInit();
    await db.collection('orders').doc(id).update({'status': status});
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> teamStream() =>
      db.collection('admins').snapshots();

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

  /// Seeds the sample catalog (only when the admin asks, and only when the
  /// catalog is empty — never overwrites real data).
  Future<int> seedSamplesIfEmpty({
    required List<Map<String, dynamic>> categories,
    required List<Map<String, dynamic>> products,
  }) async {
    _requireInit();
    final existing = await db.collection('products').limit(1).get();
    if (existing.docs.isNotEmpty) return 0;
    final catIds = <String, String>{};
    for (final c in categories) {
      final ref = await db.collection('categories').add({
        'name': c['name'],
        'createdAt': FieldValue.serverTimestamp(),
      });
      catIds[c['id'] as String] = ref.id;
    }
    for (final p in products) {
      await db.collection('products').add({
        'name': p['name'],
        'price': p['price'],
        'description': p['description'],
        'categoryId': catIds[p['categoryId']] ?? '',
        'images': <Map<String, dynamic>>[],
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    return products.length;
  }
}
