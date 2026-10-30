// Storefront preview widgets — pure, no backend calls, so they are
// widget-testable and CANNOT write anything: they only render the
// draft values the caller passes. Used by Settings (brand/tagline
// preview) and the product editor (product card preview). Nothing
// writes to Firestore until the caller taps Save; Cancel discards
// the draft by simply not calling Save.
//
// The markup mirrors the live website (storefront/index.html +
// styles.css, byte-identical in v1.1.2): a white translucent header
// with the brand, the hero tagline, and a white product card with a
// square image, name, blue price and an "add to cart" button.

import 'package:flutter/material.dart';

import '../services/cloudinary.dart';

const Color _previewText = Color(0xFF1D1D1F);
const Color _previewBlue = Color(0xFF0A84FF);
const Color _previewMuted = Color(0xFF86868B);

/// Live preview of the storefront header + hero, exactly as the
/// website shows them. Empty drafts fall back to the website's own
/// defaults, so the preview never shows a blank header.
class StorefrontHeaderPreview extends StatelessWidget {
  const StorefrontHeaderPreview({
    super.key,
    required this.brandName,
    required this.tagline,
  });

  final String brandName;
  final String tagline;

  @override
  Widget build(BuildContext context) {
    final brand = brandName.trim().isEmpty ? 'المتجر' : brandName.trim();
    final tag = tagline.trim().isEmpty
        ? 'كل اللي تحتاجه، في مكان واحد'
        : tagline.trim();
    return Container(
      key: const Key('storefront-header-preview'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E5EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Website <header>: sticky white bar, brand + cart button.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFE5E5EA))),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  brand,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: _previewText,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _previewBlue,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'السلة (0)',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          // Website hero <h1>: the tagline.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              tag,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: _previewText,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Text(
              'اطلب دلوقتي وادفع عند الاستلام',
              style: TextStyle(color: _previewMuted, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// v1.1.2 scope #8: live preview of the homepage draft, rendered
/// website-style. Pure — takes only draft values plus name/image
/// lookups the caller already has, so it can never write anything.
/// [heroProducts] and [featuredProduct] are display maps with
/// 'name' and 'imageUrl' keys; [promoBanners] are banner maps in the
/// homepage-doc shape; [deliveryBanner] is the delivery map.
class HomepagePreview extends StatelessWidget {
  const HomepagePreview({
    super.key,
    required this.heroProducts,
    required this.featuredProduct,
    required this.promoBanners,
    required this.deliveryBanner,
  });

  final List<Map<String, String>> heroProducts;
  final Map<String, String>? featuredProduct;
  final List<Map<String, dynamic>> promoBanners;
  final Map<String, String> deliveryBanner;

  @override
  Widget build(BuildContext context) {
    final featured = featuredProduct;
    return Container(
      key: const Key('homepage-preview'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E5EA)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'معاينة واجهة الموقع',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: _previewText,
            ),
          ),
          const SizedBox(height: 8),
          // Hero strip: ordered hero products.
          if (heroProducts.isEmpty)
            const Text(
              'مفيش منتجات في الواجهة لسه — ضيف لحد 4 منتجات.',
              style: TextStyle(color: _previewMuted, fontSize: 13),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final p in heroProducts) ...[
                    Container(
                      width: 110,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          _previewThumb(
                              p['imageUrl'] ?? '', p['name'] ?? '', 64),
                          const SizedBox(height: 6),
                          Text(
                            p['name'] ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _previewText,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          if (featured != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                _previewThumb(
                    featured['imageUrl'] ?? '', featured['name'] ?? '', 40),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'المنتج المميز: ${featured['name'] ?? ''}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _previewText,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (promoBanners.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'بانرات ترويجية: ${promoBanners.length}',
              style: const TextStyle(fontSize: 13, color: _previewMuted),
            ),
          ],
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _previewThumb(
                    deliveryBanner['imageUrl'] ?? '',
                    deliveryBanner['title'] ?? '',
                    40),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        deliveryBanner['title']!.isEmpty
                            ? 'بانر التوصيل'
                            : deliveryBanner['title']!,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: _previewText,
                        ),
                      ),
                      if (deliveryBanner['subtitle']!.isNotEmpty)
                        Text(
                          deliveryBanner['subtitle']!,
                          style: const TextStyle(
                              fontSize: 12, color: _previewMuted),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewThumb(String url, String name, double size) {
    if (url.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_previewBlue, Color(0xFF64D2FF)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          name.isEmpty ? '؟' : name.characters.first,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        deliveryUrl(url),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (c, e, st) => Container(
          width: size,
          height: size,
          color: _previewMuted,
          child: const Icon(Icons.broken_image_outlined,
              color: Colors.white, size: 20),
        ),
      ),
    );
  }
}
class StorefrontProductCardPreview extends StatelessWidget {
  const StorefrontProductCardPreview({
    super.key,
    required this.name,
    required this.priceText,
    this.imageUrl,
  });

  final String name;
  final String priceText;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final displayName = name.trim().isEmpty ? 'اسم المنتج' : name.trim();
    final url = (imageUrl ?? '').trim();
    return Container(
      key: const Key('storefront-product-card-preview'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: url.isEmpty
                  ? Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [_previewBlue, Color(0xFF64D2FF)],
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        displayName.characters.first,
                        style: const TextStyle(
                          fontSize: 42,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    )
                  : Image.network(
                      deliveryUrl(url),
                      fit: BoxFit.cover,
                      errorBuilder: (c, e, st) => Container(
                        color: _previewMuted,
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image_outlined,
                            color: Colors.white),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: _previewText,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$priceText ج.م',
                    style: const TextStyle(
                      color: _previewBlue,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: _previewBlue,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      'أضف للسلة',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
