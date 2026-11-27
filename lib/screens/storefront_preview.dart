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
import 'package:flutter/services.dart';

import '../services/cloudinary.dart';
import '../theme/store_design.dart';

const Color _previewText = Color(0xFF1D1D1F);
const Color _previewBlue = Color(0xFF0A84FF);
const Color _previewMuted = Color(0xFF86868B);

/// Template-driven colors for the storefront preview widgets
/// (design doc file 12, Alternative K — parameterize the existing
/// widgets from the template tokens, no new dependency). Defaults
/// are the preview's long-standing values, so existing callers
/// (Settings, product editor) render exactly as before when no
/// tokens are passed; a template's tokens make the preview look
/// like that template's live site (the old blue hard-coding would
/// misrepresent the teal live site).
class PreviewTokens {
  const PreviewTokens({
    this.background = Colors.white,
    this.surface = const Color(0xFFF5F5F7),
    this.text = _previewText,
    this.muted = _previewMuted,
    this.accent = _previewBlue,
    this.radius = 18,
  });

  final Color background;
  final Color surface;
  final Color text;
  final Color muted;
  final Color accent;
  final double radius;

  /// Builds tokens from a template's token map (gateway-validated,
  /// so any unparsable value falls back to the default).
  factory PreviewTokens.fromTemplate(Map<String, String> tokens) {
    Color? parseColor(String? v) {
      if (v == null) return null;
      final s = v.trim();
      final hex = RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$')
          .firstMatch(s);
      if (hex != null) {
        var h = hex.group(1)!;
        if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
        if (h.length == 6) h = 'FF$h';
        final value = int.tryParse(h, radix: 16);
        if (value != null) return Color(value);
        return null;
      }
      final rgba = RegExp(
              r'^rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([0-9.]+)\s*\)$')
          .firstMatch(s);
      if (rgba != null) {
        final r = int.tryParse(rgba.group(1)!);
        final g = int.tryParse(rgba.group(2)!);
        final b = int.tryParse(rgba.group(3)!);
        final a = double.tryParse(rgba.group(4)!);
        if (r != null && g != null && b != null && a != null) {
          return Color.fromRGBO(r, g, b, a);
        }
      }
      return null;
    }

    double parseRadius(String? v) {
      final m = v == null ? null : RegExp(r'^(\d+)px$').firstMatch(v.trim());
      final n = m == null ? null : double.tryParse(m.group(1)!);
      return (n == null || n < 0 || n > 64) ? 18 : n;
    }

    return PreviewTokens(
      background: parseColor(tokens['bg']) ?? Colors.white,
      surface: parseColor(tokens['surfaceStrong']) ??
          const Color(0xFFF5F5F7),
      text: parseColor(tokens['text']) ?? _previewText,
      muted: parseColor(tokens['textSoft']) ?? _previewMuted,
      accent: parseColor(tokens['accent']) ?? _previewBlue,
      radius: parseRadius(tokens['radius']),
    );
  }
}

/// Live preview of the storefront header + hero, exactly as the
/// website shows them. Empty drafts fall back to the website's own
/// defaults, so the preview never shows a blank header.
class StorefrontHeaderPreview extends StatelessWidget {
  const StorefrontHeaderPreview({
    super.key,
    required this.brandName,
    required this.tagline,
    this.tokens = const PreviewTokens(),
  });

  final String brandName;
  final String tagline;

  /// Template tokens (file 12): when given, the preview renders in
  /// the template's colors; the default keeps the old look.
  final PreviewTokens tokens;

  @override
  Widget build(BuildContext context) {
    final brand = brandName.trim().isEmpty ? 'المتجر' : brandName.trim();
    final tag = tagline.trim().isEmpty
        ? 'كل اللي تحتاجه، في مكان واحد'
        : tagline.trim();
    return Container(
      key: const Key('storefront-header-preview'),
      decoration: BoxDecoration(
        color: tokens.background,
        borderRadius: BorderRadius.circular(tokens.radius),
        border: Border.all(color: tokens.muted.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Website <header>: sticky white bar, brand + cart button.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: tokens.muted.withValues(alpha: 0.3))),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  brand,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: tokens.text,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: tokens.accent,
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
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: tokens.text,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Text(
              'اطلب دلوقتي وادفع عند الاستلام',
              style: TextStyle(color: tokens.muted, fontSize: 13),
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
    this.tokens = const PreviewTokens(),
  });

  final List<Map<String, String>> heroProducts;
  final Map<String, String>? featuredProduct;
  final List<Map<String, dynamic>> promoBanners;
  final Map<String, String> deliveryBanner;

  /// Template tokens (file 12); the default keeps the old look.
  final PreviewTokens tokens;

  @override
  Widget build(BuildContext context) {
    final featured = featuredProduct;
    return Container(
      key: const Key('homepage-preview'),
      decoration: BoxDecoration(
        color: tokens.background,
        borderRadius: BorderRadius.circular(tokens.radius),
        border: Border.all(color: tokens.muted.withValues(alpha: 0.3)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'معاينة واجهة الموقع',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: tokens.text,
            ),
          ),
          const SizedBox(height: 8),
          // Hero strip: ordered hero products.
          if (heroProducts.isEmpty)
            Text(
              'مفيش منتجات في الواجهة لسه — ضيف لحد 4 منتجات.',
              style: TextStyle(color: tokens.muted, fontSize: 13),
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
                        color: tokens.surface,
                        borderRadius:
                            BorderRadius.circular(tokens.radius / 2),
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
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: tokens.text,
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
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: tokens.text,
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
              style: TextStyle(fontSize: 13, color: tokens.muted),
            ),
          ],
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: tokens.surface,
              borderRadius: BorderRadius.circular(tokens.radius / 2),
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
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: tokens.text,
                        ),
                      ),
                      if (deliveryBanner['subtitle']!.isNotEmpty)
                        Text(
                          deliveryBanner['subtitle']!,
                          style: TextStyle(
                              fontSize: 12, color: tokens.muted),
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
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              tokens.accent,
              tokens.accent.withValues(alpha: 0.55),
            ],
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
          color: tokens.muted,
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
    this.basePriceText,
    this.imageUrl,
    this.tokens = const PreviewTokens(),
  });

  final String name;
  final String priceText;

  /// Optional "السعر قبل الخصم" draft (Model P): when it parses to
  /// a base strictly above the price, the card shows the struck
  /// through base + % badge + "وفّر X", exactly like the live site.
  /// Null/empty/equal means no sale.
  final String? basePriceText;
  final String? imageUrl;

  /// Template tokens (file 12); the default keeps the old look.
  final PreviewTokens tokens;

  @override
  Widget build(BuildContext context) {
    final displayName = name.trim().isEmpty ? 'اسم المنتج' : name.trim();
    final url = (imageUrl ?? '').trim();
    // Sale display (Technical Plan §8). This file stays pure — no
    // backend calls — so the % math is the same integer formula as
    // Backend.salePercent, kept in sync with it: round halves up,
    // badge suppressed when rounded % × base ≠ exact saving
    // (base 199 → 149 shows only "وفّر 50", never a 25% badge).
    final price = int.tryParse(priceText.trim());
    final base = int.tryParse((basePriceText ?? '').trim());
    final onSale = price != null && base != null && base > price;
    final saving = onSale ? base - price : 0;
    final pct = onSale
        ? (((base - price) * 200 + base) ~/ (base * 2))
        : null;
    final showPct =
        onSale && pct != null && pct * base == saving * 100;
    return Container(
      key: const Key('storefront-product-card-preview'),
      decoration: BoxDecoration(
        color: tokens.background,
        borderRadius: BorderRadius.circular(tokens.radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(tokens.radius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: url.isEmpty
                  ? Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            tokens.accent,
                            tokens.accent.withValues(alpha: 0.55),
                          ],
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
                        color: tokens.muted,
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
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: tokens.text,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (onSale)
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      children: [
                        Text(
                          '$priceText ج.م',
                          style: TextStyle(
                            color: tokens.accent,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          '$basePriceText ج.م',
                          style: TextStyle(
                            color: tokens.muted,
                            decoration: TextDecoration.lineThrough,
                          ),
                        ),
                        if (showPct)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: tokens.accent,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'خصم $pct٪',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    )
                  else
                    Text(
                      '$priceText ج.م',
                      style: TextStyle(
                        color: tokens.accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  if (onSale)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'وفّر $saving ج.م',
                        style: TextStyle(
                          color: tokens.accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: tokens.accent,
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

/// Real template preview link (spec entry 15 — REPLACES the
/// hand-built mock preview for templates).
///
/// The old mock rendered a hand-built header + product card in the
/// template's tokens and misrepresented exactly the templates that
/// differ most from classic, so it is deleted from the template
/// screen. This widget shows the real `?preview=<slug>` link
/// instead: opening it renders the real shell + the real bundle +
/// the real live products, visibly stamped as a preview. The
/// preview checkout is a dry run through the frozen shell (info →
/// review, stopping at confirm) — no preview action may call
/// placeOrderTx or reserve stock.
///
/// NOTE on scope: the PreviewTokens widgets above (header / homepage
/// / product-card previews) stay — they serve the brand editor and
/// the product editor, which preview draft field values, not
/// templates. Only the template-screen mock usage is deleted.
class RealTemplatePreviewLink extends StatelessWidget {
  const RealTemplatePreviewLink({
    super.key,
    required this.previewUrl,
    required this.templateName,
    this.onCopy,
  });

  /// The full ?preview= URL (unguessable slug; never linked from
  /// the live site, never indexed).
  final String previewUrl;
  final String templateName;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final tokens = StoreGlass.of(context);
    return Container(
      key: const Key('real-template-preview-link'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.cardTop,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.visibility_outlined, color: tokens.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'معاينة حقيقية — $templateName',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'الرابط ده بيفتح الموقع الحقيقي بالقالب ده والمنتجات والأسعار الحقيقية، وعليه ختم "معاينة".',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          SelectableText(
            previewUrl,
            style: TextStyle(
              fontSize: 13,
              color: tokens.accent,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: const Text('نسخ رابط المعاينة'),
                  onPressed: () async {
                    await Clipboard.setData(
                        ClipboardData(text: previewUrl));
                    onCopy?.call();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'المعاينة تجربة بس: خطوة الدفع بتقف عند المراجعة ومفيش طلب بيتعمل ولا مخزون بيتحجز ولا كود خصم بيتسحب.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
