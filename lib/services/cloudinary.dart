// Cloudinary image uploads — free plan, NO card, NO backend, NO secret.
//
// Uploads use an UNSIGNED preset, so the app holds no Cloudinary secret:
// only cloudName + uploadPreset (client-safe identifiers). The upload is a
// plain HTTP multipart POST; the returned secure_url + public_id are saved
// in the Firestore product doc.
//
// PLACEHOLDERS: cloudName and uploadPreset are NOT known yet — Mo supplies
// them once the Cloudinary account + preset exist. Nothing is invented
// here; while they are empty, uploads fail loudly and the admin can still
// paste an image link instead.
//
// Preset restrictions to apply when the preset is created (documented here
// so they are applied exactly once, at creation time):
//   - folder: store-products
//   - allowed formats: jpg, png, webp
//   - unsigned: yes (no secret in the app, ever)
// The app also compresses on-device (max 1200px, quality 80) before upload.
//
// Removal policy: removing an image deletes its entry from the product
// doc only — the image disappears from the store immediately. The app
// NEVER calls Cloudinary's destroy API (it needs the api_secret, which
// must never be in client code). Files left on Cloudinary after a remove
// are orphans: unreferenced, unserved, cleaned later from the Cloudinary
// dashboard (or a small signed backend, later).
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/diagnostics.dart';

class CloudinaryConfig {
  // TODO: supplied by Mo once the Cloudinary account + unsigned preset exist.
  static const String cloudName = '';
  static const String uploadPreset = '';

  static bool get isConfigured =>
      cloudName.isNotEmpty && uploadPreset.isNotEmpty;
}

class CloudinaryImage {
  CloudinaryImage({required this.url, required this.publicId});
  final String url;
  final String publicId;

  Map<String, dynamic> toMap() => {'url': url, 'publicId': publicId};

  factory CloudinaryImage.fromMap(Map<String, dynamic> m) => CloudinaryImage(
        url: (m['url'] ?? '') as String,
        publicId: (m['publicId'] ?? '') as String,
      );
}

class CloudinaryUploadException implements Exception {
  CloudinaryUploadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Uploads image bytes to Cloudinary via the unsigned preset.
/// Returns the stored image (secure_url + public_id).
Future<CloudinaryImage> uploadImageToCloudinary(
  Uint8List bytes, {
  String filename = 'product.jpg',
}) async {
  if (!CloudinaryConfig.isConfigured) {
    throw CloudinaryUploadException(
      'رفع الصور لسه مش متظبط — ضيف لينك صورة لحد ما يتظبط إعداد Cloudinary',
    );
  }
  final uri = Uri.parse(
    'https://api.cloudinary.com/v1_1/${CloudinaryConfig.cloudName}/image/upload',
  );
  final request = http.MultipartRequest('POST', uri)
    ..fields['upload_preset'] = CloudinaryConfig.uploadPreset
    ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
  try {
    final streamed = await request.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      Diagnostics.instance.log('Cloudinary upload failed: ${streamed.statusCode}');
      throw CloudinaryUploadException('فشل رفع الصورة (خطأ ${streamed.statusCode})');
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    final url = (json['secure_url'] ?? '') as String;
    final publicId = (json['public_id'] ?? '') as String;
    if (url.isEmpty) {
      throw CloudinaryUploadException('الرفع خلص من غير لينك صورة — حاول تاني');
    }
    return CloudinaryImage(url: url, publicId: publicId);
  } catch (e) {
    if (e is CloudinaryUploadException) rethrow;
    Diagnostics.instance.log('Cloudinary upload error: $e');
    throw CloudinaryUploadException('تعذر رفع الصورة — اتأكد من الإنترنت وحاول تاني');
  }
}
