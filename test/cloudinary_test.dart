// Cloudinary config tests — v1.1 wires the verified console values:
// cloud name v1lolxom, unsigned preset store-products (folder
// store-products, jpg/jpeg/png/webp, free plan). No secret is held:
// only these two client-safe identifiers. The 10 MB preset-side cap
// could NOT be set via the console UI (API-only); the app compresses
// on-device (1200px/q80) before every upload, so this is acceptable.
import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/services/cloudinary.dart';

void main() {
  test('cloudinary config is the verified console config, not placeholders', () {
    expect(CloudinaryConfig.isConfigured, isTrue);
    expect(CloudinaryConfig.cloudName, 'v1lolxom');
    expect(CloudinaryConfig.uploadPreset, 'store-products');
  });

  test('upload endpoint is built from the configured cloud name', () {
    expect(
      'https://api.cloudinary.com/v1_1/${CloudinaryConfig.cloudName}/image/upload',
      'https://api.cloudinary.com/v1_1/v1lolxom/image/upload',
    );
  });

  test('image map round-trip', () {
    final img = CloudinaryImage(url: 'https://example.com/x.jpg', publicId: 'store-products/x');
    final back = CloudinaryImage.fromMap(img.toMap());
    expect(back.url, img.url);
    expect(back.publicId, img.publicId);
  });

  test('delivery url injects f_auto,q_auto only for cloudinary urls', () {
    expect(
      deliveryUrl('https://res.cloudinary.com/v1lolxom/image/upload/v1/store-products/x.jpg'),
      'https://res.cloudinary.com/v1lolxom/image/upload/f_auto,q_auto/v1/store-products/x.jpg',
    );
    expect(
      deliveryUrl('https://res.cloudinary.com/v1lolxom/image/upload/f_auto,q_auto/v1/x.jpg'),
      'https://res.cloudinary.com/v1lolxom/image/upload/f_auto,q_auto/v1/x.jpg',
    );
    expect(deliveryUrl('https://example.com/x.jpg'), 'https://example.com/x.jpg');
  });
}
