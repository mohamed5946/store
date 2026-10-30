// Cloudinary config tests — placeholders must stay empty until Mo supplies
// real values; nothing is invented here.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/services/cloudinary.dart';

void main() {
  test('cloudinary config is placeholder until supplied', () {
    expect(CloudinaryConfig.isConfigured, isFalse);
    expect(CloudinaryConfig.cloudName, isEmpty);
    expect(CloudinaryConfig.uploadPreset, isEmpty);
  });

  test('upload without config fails loudly, never silently', () async {
    await expectLater(
      uploadImageToCloudinary(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<CloudinaryUploadException>()),
    );
  });

  test('image map round-trip', () {
    final img = CloudinaryImage(url: 'https://example.com/x.jpg', publicId: 'store-products/x');
    final back = CloudinaryImage.fromMap(img.toMap());
    expect(back.url, img.url);
    expect(back.publicId, img.publicId);
  });
}
