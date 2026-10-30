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
// AUTO-OPTIMIZATION: every displayed Cloudinary URL goes through
// deliveryUrl(), which injects f_auto,q_auto so the storefront and the app
// always load the auto-format, auto-quality variant (fast loading).
//
// Removal policy: removing an image deletes its entry from the product
// doc only — the image disappears from the store immediately. The app
// NEVER calls Cloudinary's destroy API (it needs the api_secret, which
// must never be in client code). Files left on Cloudinary after a remove
// are orphans: unreferenced, unserved, cleaned later from the Cloudinary
// dashboard (or a small signed backend, later).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// Delivery URL with auto format + auto quality. Non-Cloudinary URLs
/// (pasted links) pass through unchanged.
String deliveryUrl(String url) {
  if (!url.contains('res.cloudinary.com')) return url;
  if (url.contains('f_auto')) return url;
  return url.replaceFirst('/upload/', '/upload/f_auto,q_auto/');
}

class CloudinaryUploadException implements Exception {
  CloudinaryUploadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Uploads image bytes to Cloudinary via the unsigned preset, reporting
/// real upload progress (0.0–1.0) as bytes are flushed to the socket.
/// Returns the stored image (secure_url + public_id).
Future<CloudinaryImage> uploadImageToCloudinary(
  Uint8List bytes, {
  void Function(double progress)? onProgress,
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
  final boundary = '----storeadmin${DateTime.now().millisecondsSinceEpoch}';
  final header = utf8.encode(
    '--$boundary\r\n'
    'Content-Disposition: form-data; name="upload_preset"\r\n\r\n'
    '${CloudinaryConfig.uploadPreset}\r\n'
    '--$boundary\r\n'
    'Content-Disposition: form-data; name="file"; filename="$filename"\r\n'
    'Content-Type: application/octet-stream\r\n\r\n',
  );
  final footer = utf8.encode('\r\n--$boundary--\r\n');
  final total = header.length + bytes.length + footer.length;
  var sent = 0;
  void report(int n) {
    sent += n;
    onProgress?.call((sent / total).clamp(0.0, 1.0));
  }

  final client = HttpClient();
  try {
    final request = await client.postUrl(uri);
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'multipart/form-data; boundary=$boundary',
    );
    request.contentLength = total;
    request.add(header);
    report(header.length);
    const chunk = 65536;
    for (var offset = 0; offset < bytes.length; offset += chunk) {
      final end = (offset + chunk).clamp(0, bytes.length);
      request.add(bytes.sublist(offset, end));
      await request.flush();
      report(end - offset);
    }
    request.add(footer);
    report(footer.length);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      Diagnostics.instance.log('Cloudinary upload failed: ${response.statusCode}');
      throw CloudinaryUploadException('فشل رفع الصورة (خطأ ${response.statusCode})');
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
  } finally {
    client.close();
  }
}
