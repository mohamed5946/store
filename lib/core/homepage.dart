// Store Admin v1.1.2 scope #8: the site homepage editor's document
// shape. This file is the CONTRACT with the separate website
// builder: it reads storeSettings/homepage with EXACTLY these
// fields — do not rename anything here without coordinating with
// that builder.
//
//   storeSettings/homepage:
//   {
//     heroProductIds: string[] (max 4, ordered),
//     promoBanners: [
//       { imageUrl, title, subtitle,
//         linkType: 'category' | 'product' | 'none',
//         linkId: string,
//         endDate: string (ISO 8601 date-time, Africa/Cairo,
//           optional — D2: the real sale window a countdown counts
//           from; no end date → no countdown, never a tick toward
//           nothing) }
//     ],
//     featuredProductId: string,
//     deliveryBanner: { title, subtitle, imageUrl },
//     heroImageUrl: string (default ""),
//     heroTitle: string (default ""),
//     heroAccent: string (default ""),
//     heroSubtitle: string (default ""),
//   }
//
// The four hero* fields are the storefront's hero overrides (see
// storefront/app.js header): the storefront reads them, the editor
// has no UI for them yet, but they ride through parse + build
// unchanged so an editor save never wipes them (Decision 27).
//
// Pure builders only — no Firebase, no I/O — so the shape is
// unit-testable and the editor preview can never write anything:
// the doc is produced ONLY when the user taps Save.

/// Maximum hero products the storefront hero shows.
const int maxHeroProducts = 4;

/// Builds one promo banner map in the exact website-builder shape.
/// An unknown linkType falls back to 'none' rather than shipping a
/// value the storefront cannot route.
Map<String, dynamic> promoBannerMap({
  required String imageUrl,
  required String title,
  required String subtitle,
  required String linkType,
  required String linkId,
  String? endDate,
}) {
  final safeLinkType = linkType == 'category' || linkType == 'product'
      ? linkType
      : 'none';
  return <String, dynamic>{
    'imageUrl': imageUrl,
    'title': title,
    'subtitle': subtitle,
    'linkType': safeLinkType,
    // A 'none' banner carries no target, even if the editor held one.
    'linkId': safeLinkType == 'none' ? '' : linkId,
    // D2: the real promo end date. Empty string = no end date = no
    // countdown. The key is always emitted so the stored shape is
    // fixed; the storefront treats "" exactly like missing.
    'endDate': (endDate ?? '').trim(),
  };
}

/// Validates a promo end date (D2): empty means "no countdown" and
/// is always valid; otherwise it must be an ISO 8601 date-time
/// (Africa/Cairo — a naive value is read as Cairo time by the
/// storefront). Returns an Arabic error message, or null when valid.
String? validatePromoEndDate(String? value) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return null;
  if (!v.contains('T')) {
    return 'تاريخ الانتهاء لازم يكون تاريخ ووقت (مثال: 2026-12-01T23:59:00+02:00)';
  }
  // DateTime.tryParse normalizes out-of-range fields (month 13
  // becomes next January) instead of rejecting them, so the shape
  // is checked first: real month/day/hour/minute ranges, optional
  // seconds + fractional part, optional Z or ±HH:MM offset.
  final shape = RegExp(
      r'^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])T([01]\d|2[0-3]):[0-5]\d(:[0-5]\d(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$');
  if (!shape.hasMatch(v) || DateTime.tryParse(v) == null) {
    return 'تاريخ الانتهاء مش بصيغة ISO 8601 صحيحة';
  }
  return null;
}

/// Builds the full homepage doc. Hero ids are truncated to the first
/// [maxHeroProducts] in order — the editor UI also blocks adding a
/// fifth, so this is a second line of defence, never a surprise.
/// The four hero* fields default to "" and are always emitted: the
/// storefront treats "" exactly like missing, and emitting them keeps
/// the stored shape fixed so an editor save round-trips them.
Map<String, dynamic> buildHomepageDoc({
  required List<String> heroProductIds,
  required List<Map<String, dynamic>> promoBanners,
  required String featuredProductId,
  required Map<String, dynamic> deliveryBanner,
  String heroImageUrl = '',
  String heroTitle = '',
  String heroAccent = '',
  String heroSubtitle = '',
}) {
  return <String, dynamic>{
    'heroProductIds': heroProductIds.take(maxHeroProducts).toList(),
    'promoBanners': promoBanners
        .map((b) => promoBannerMap(
              imageUrl: (b['imageUrl'] ?? '') as String,
              title: (b['title'] ?? '') as String,
              subtitle: (b['subtitle'] ?? '') as String,
              linkType: (b['linkType'] ?? 'none') as String,
              linkId: (b['linkId'] ?? '') as String,
              endDate: (b['endDate'] ?? '') as String,
            ))
        .toList(),
    'featuredProductId': featuredProductId,
    'deliveryBanner': <String, dynamic>{
      'title': (deliveryBanner['title'] ?? '') as String,
      'subtitle': (deliveryBanner['subtitle'] ?? '') as String,
      'imageUrl': (deliveryBanner['imageUrl'] ?? '') as String,
    },
    'heroImageUrl': heroImageUrl,
    'heroTitle': heroTitle,
    'heroAccent': heroAccent,
    'heroSubtitle': heroSubtitle,
  };
}

/// Reads a homepage doc back into editor-friendly pieces. Unknown or
/// missing fields degrade to empty values, never a crash — the doc
/// may predate this editor.
Map<String, dynamic> parseHomepageDoc(Map<String, dynamic>? doc) {
  final d = doc ?? {};
  final hero = (d['heroProductIds'] as List<dynamic>? ?? [])
      .map((e) => e.toString())
      .toList();
  final banners = (d['promoBanners'] as List<dynamic>? ?? [])
      .whereType<Map<String, dynamic>>()
      .map((b) => <String, dynamic>{
            'imageUrl': (b['imageUrl'] ?? '') as String,
            'title': (b['title'] ?? '') as String,
            'subtitle': (b['subtitle'] ?? '') as String,
            'linkType': (b['linkType'] ?? 'none') as String,
            'linkId': (b['linkId'] ?? '') as String,
            'endDate': (b['endDate'] ?? '') as String,
          })
      .toList();
  final delivery = (d['deliveryBanner'] as Map<String, dynamic>?) ?? {};
  return <String, dynamic>{
    'heroProductIds': hero,
    'promoBanners': banners,
    'featuredProductId': (d['featuredProductId'] ?? '') as String,
    'deliveryBanner': <String, dynamic>{
      'title': (delivery['title'] ?? '') as String,
      'subtitle': (delivery['subtitle'] ?? '') as String,
      'imageUrl': (delivery['imageUrl'] ?? '') as String,
    },
    'heroImageUrl': (d['heroImageUrl'] ?? '') as String,
    'heroTitle': (d['heroTitle'] ?? '') as String,
    'heroAccent': (d['heroAccent'] ?? '') as String,
    'heroSubtitle': (d['heroSubtitle'] ?? '') as String,
  };
}
