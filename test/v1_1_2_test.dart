// Store Admin v1.1.2 tests: in-app updater, stagger, bin autoplay,
// dashboard computation, homepage doc shape, and storefront
// previews. Pure tests run without Firebase; widget tests pump only
// pure widgets (no backend calls), so they need no runAsync.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/core/dashboard_stats.dart';
import 'package:storeadmin/core/homepage.dart';
import 'package:storeadmin/core/store_update.dart';
import 'package:storeadmin/screens/storefront_preview.dart';
import 'package:storeadmin/theme/store_design.dart';

void main() {
  group('updater manifest', () {
    test('valid manifest parses with all fields', () {
      final m = StoreUpdateManifest.tryParse(
        '{"versionCode": 5, "versionName": "1.1.3", '
        '"changelog": "Store Admin v1.1.3: fixes", '
        '"apkUrl": "https://example.test/app.apk", '
        '"apkSha256": "abcdef", "apkSizeBytes": 12345}',
      );
      expect(m, isNotNull);
      expect(m!.versionCode, 5);
      expect(m.versionName, '1.1.3');
      expect(m.changelog, contains('v1.1.3'));
      expect(m.apkSizeBytes, 12345);
    });

    test('missing apkSha256 is rejected, never half-trusted', () {
      expect(
        StoreUpdateManifest.tryParse(
          '{"versionCode": 5, "versionName": "1.1.3", '
          '"apkUrl": "https://example.test/app.apk"}',
        ),
        isNull,
      );
    });

    test('non-numeric versionCode is rejected', () {
      expect(
        StoreUpdateManifest.tryParse(
          '{"versionCode": "five", "versionName": "1.1.3", '
          '"apkUrl": "https://example.test/app.apk", '
          '"apkSha256": "abcdef"}',
        ),
        isNull,
      );
    });

    test('non-map body is rejected', () {
      expect(StoreUpdateManifest.tryParse('[1, 2, 3]'), isNull);
      expect(StoreUpdateManifest.tryParse('not json'), isNull);
    });

    test('isNewerThan is strict: equal or older never prompts', () {
      const m = StoreUpdateManifest(
        versionCode: 5,
        versionName: '1.1.3',
        changelog: '',
        apkUrl: 'https://example.test/app.apk',
        apkSha256: 'abcdef',
        apkSizeBytes: 0,
      );
      expect(m.isNewerThan(4), isTrue);
      expect(m.isNewerThan(5), isFalse);
      expect(m.isNewerThan(6), isFalse);
    });
  });

  group('remind-tonight suppression', () {
    test('same day before 18:00 suppresses', () {
      expect(
        StoreUpdateSession.isRemindSuppressed(
          remindCode: 5,
          remindSetAt: DateTime(2026, 10, 30, 10, 0),
          manifestCode: 5,
          now: DateTime(2026, 10, 30, 17, 59),
        ),
        isTrue,
      );
    });

    test('same day at/after 18:00 shows again', () {
      expect(
        StoreUpdateSession.isRemindSuppressed(
          remindCode: 5,
          remindSetAt: DateTime(2026, 10, 30, 10, 0),
          manifestCode: 5,
          now: DateTime(2026, 10, 30, 18, 0),
        ),
        isFalse,
      );
    });

    test('later day shows again; other code never suppresses', () {
      expect(
        StoreUpdateSession.isRemindSuppressed(
          remindCode: 5,
          remindSetAt: DateTime(2026, 10, 30, 10, 0),
          manifestCode: 5,
          now: DateTime(2026, 10, 31, 9, 0),
        ),
        isFalse,
      );
      expect(
        StoreUpdateSession.isRemindSuppressed(
          remindCode: 5,
          remindSetAt: DateTime(2026, 10, 30, 10, 0),
          manifestCode: 6,
          now: DateTime(2026, 10, 30, 12, 0),
        ),
        isFalse,
      );
      expect(
        StoreUpdateSession.isRemindSuppressed(
          remindCode: null,
          remindSetAt: null,
          manifestCode: 5,
          now: DateTime(2026, 10, 30, 12, 0),
        ),
        isFalse,
      );
    });
  });

  group('download verification + size', () {
    test('size mismatch is reported, never installed', () {
      const m = StoreUpdateManifest(
        versionCode: 5,
        versionName: '1.1.3',
        changelog: '',
        apkUrl: 'https://example.test/app.apk',
        apkSha256: '00',
        apkSizeBytes: 10,
      );
      expect(verifyDownloadedApk([1, 2, 3], m), contains('size mismatch'));
    });

    test('sha mismatch is reported; matching bytes pass', () {
      final bytes = [10, 20, 30, 40];
      final good = StoreUpdateManifest(
        versionCode: 5,
        versionName: '1.1.3',
        changelog: '',
        apkUrl: 'https://example.test/app.apk',
        apkSha256: sha256Hex(bytes),
        apkSizeBytes: bytes.length,
      );
      expect(verifyDownloadedApk(bytes, good), isNull);
      final bad = StoreUpdateManifest(
        versionCode: 5,
        versionName: '1.1.3',
        changelog: '',
        apkUrl: 'https://example.test/app.apk',
        apkSha256: 'deadbeef',
        apkSizeBytes: bytes.length,
      );
      expect(verifyDownloadedApk(bytes, bad), contains('SHA-256'));
    });

    test('formatApkSize uses real sizes only', () {
      expect(formatApkSize(56465651), '54 MB');
      expect(formatApkSize(1500), '1 KB');
      expect(formatApkSize(0), '');
    });
  });

  group('stagger math (DeliveryFlow pattern)', () {
    test('80ms steps, capped at index 7, 300ms items', () {
      expect(StaggeredItem.delayFor(0), Duration.zero);
      expect(StaggeredItem.delayFor(3), const Duration(milliseconds: 240));
      expect(StaggeredItem.delayFor(7), const Duration(milliseconds: 560));
      expect(StaggeredItem.delayFor(10), const Duration(milliseconds: 560));
      expect(StaggeredItem.itemDuration, const Duration(milliseconds: 300));
      expect(StaggeredItem.slideFraction, 0.2);
    });
  });

  group('dashboard stats from fixtures', () {
    test('counts, revenue ex-cancelled, funnel, today, abandoned', () {
      final now = DateTime(2026, 10, 30, 12, 0);
      final stats = computeDashboardStats(
        sessions: [
          {
            'durationMs': 120000,
            'startedAt': DateTime(2026, 10, 30, 9, 0),
            'steps': ['home', 'product'],
          },
          {
            'durationMs': 60000,
            'startedAt': DateTime(2026, 10, 29, 9, 0),
            'steps': ['home'],
          },
        ],
        orders: [
          {'total': 500, 'status': 'new'},
          {'total': 1000, 'status': 'delivered'},
          {'total': 2000, 'status': 'cancelled'},
          {'total': 300, 'status': 'preparing'},
        ],
        productsCount: 6,
        categoriesCount: 3,
        attempts: [
          {'ordered': false, 'contactName': 'أحمد'},
          {'ordered': true, 'contactName': 'منى'},
          {'ordered': false, 'contactName': ''},
        ],
        now: now,
      );
      expect(stats.visitsTotal, 2);
      expect(stats.visitsToday, 1);
      expect(stats.avgVisitSeconds, 90);
      expect(stats.ordersCount, 4);
      expect(stats.revenue, 1800);
      expect(stats.statusCounts['cancelled'], 1);
      expect(stats.productsCount, 6);
      expect(stats.categoriesCount, 3);
      expect(stats.abandonedCount, 1);
    });
  });

  group('homepage doc shape (website-builder contract)', () {
    test('exact keys, hero truncated to 4, banner link rules', () {
      final doc = buildHomepageDoc(
        heroProductIds: ['a', 'b', 'c', 'd', 'e', 'f'],
        promoBanners: [
          {
            'imageUrl': 'https://x.test/b.png',
            'title': 'عرض',
            'subtitle': 'خصم',
            'linkType': 'category',
            'linkId': 'cat1',
          },
          {
            'imageUrl': '',
            'title': 'بدون رابط',
            'subtitle': '',
            'linkType': 'bogus',
            'linkId': 'whatever',
          },
        ],
        featuredProductId: 'p1',
        deliveryBanner: {
          'title': 'توصيل سريع',
          'subtitle': 'خلال يوم',
          'imageUrl': 'https://x.test/d.png',
        },
      );
      expect(doc.keys.toSet(), {
        'heroProductIds',
        'promoBanners',
        'featuredProductId',
        'deliveryBanner',
      });
      expect(doc['heroProductIds'], ['a', 'b', 'c', 'd']);
      final banners = doc['promoBanners'] as List<dynamic>;
      expect(banners.length, 2);
      expect((banners[0] as Map)['linkType'], 'category');
      expect((banners[0] as Map)['linkId'], 'cat1');
      expect((banners[1] as Map)['linkType'], 'none');
      expect((banners[1] as Map)['linkId'], '');
      expect((doc['deliveryBanner'] as Map).keys.toSet(),
          {'title', 'subtitle', 'imageUrl'});
    });

    test('parse degrades unknown docs to empty defaults', () {
      final parsed = parseHomepageDoc(null);
      expect(parsed['heroProductIds'], isEmpty);
      expect(parsed['promoBanners'], isEmpty);
      expect(parsed['featuredProductId'], '');
      final partial = parseHomepageDoc({'heroProductIds': ['x']});
      expect(partial['heroProductIds'], ['x']);
      expect(partial['featuredProductId'], '');
    });
  });

  group('previews render drafts and write nothing', () {
    testWidgets('header preview shows draft brand + tagline',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: StorefrontHeaderPreview(
              brandName: 'متجري',
              tagline: 'أهلا بيك',
            ),
          ),
        ),
      );
      expect(find.text('متجري'), findsOneWidget);
      expect(find.text('أهلا بيك'), findsOneWidget);
    });

    testWidgets('header preview falls back to website defaults when empty',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: StorefrontHeaderPreview(brandName: '', tagline: ''),
          ),
        ),
      );
      expect(find.text('المتجر'), findsOneWidget);
      expect(find.text('كل اللي تحتاجه، في مكان واحد'), findsOneWidget);
    });

    testWidgets('product card preview shows draft name + price',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Center(
              child: SizedBox(
                width: 320,
                child: StorefrontProductCardPreview(
                  name: 'كريم مرطب',
                  priceText: '145',
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('كريم مرطب'), findsOneWidget);
      expect(find.text('145 ج.م'), findsOneWidget);
    });

    testWidgets('homepage preview shows hero order + featured + delivery',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: HomepagePreview(
              heroProducts: const [
                {'name': 'منتج أ', 'imageUrl': ''},
                {'name': 'منتج ب', 'imageUrl': ''},
              ],
              featuredProduct: const {'name': 'المميز', 'imageUrl': ''},
              promoBanners: const [
                {'title': 'عرض', 'linkType': 'none'}
              ],
              deliveryBanner: const {
                'title': 'توصيل سريع',
                'subtitle': 'خلال يوم',
                'imageUrl': '',
              },
            ),
          ),
        ),
      );
      expect(find.text('منتج أ'), findsOneWidget);
      expect(find.text('منتج ب'), findsOneWidget);
      expect(find.textContaining('المميز'), findsOneWidget);
      expect(find.text('توصيل سريع'), findsOneWidget);
      expect(find.text('بانرات ترويجية: 1'), findsOneWidget);
    });
  });

  testWidgets('bin autoplay fires onConfirmed exactly once after animation',
      (tester) async {
    var confirmed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Center(
            child: BinEatingDeleteButton(
              label: 'منتج',
              autoplay: true,
              onConfirmed: () => confirmed++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(confirmed, 1);
    expect(find.byKey(const Key('binSuccessCheck')), findsOneWidget);
  });

  test('no Material blue left in lib (website preview excepted)', () {
    // Exception, documented: storefront_preview.dart intentionally
    // mirrors the WEBSITE's own CSS blue (#0a84ff) so the preview
    // matches the live site — it is not app-theme Material blue.
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('storefront_preview.dart')) continue;
      final src = entity.readAsStringSync();
      if (src.contains('Colors.blue') || src.contains('0xFF0A84FF')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });
}
