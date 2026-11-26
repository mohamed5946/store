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
//         linkId: string }
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
  };
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
