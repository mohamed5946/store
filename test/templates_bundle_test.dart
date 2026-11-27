// Bundle gateway tests (spec entries 11, 18): the full bundle
// check list from storefront/templates/gateway-rules.json, the
// pointer history-stack semantics, approval freeze, preview slugs,
// and the D2 promo end-date field. Pure logic — no Firestore, no
// emulator.
//
// Parity note: the shared fixtures in test/templates/fixtures/
// (entry 22, rules child's work) do not exist yet in this tree, so
// these tests pin the same check list with inline fixtures. When
// the shared fixtures land, both gateways run against them and a
// fixture added there must pass or fail identically in both.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/core/homepage.dart';
import 'package:storeadmin/services/templates_service.dart';

Map<String, dynamic> validManifest({Map<String, dynamic>? overrides}) {
  final manifest = <String, dynamic>{
    'id': 'bazaar',
    'nameAr': 'بازار',
    'nameEn': 'Deal Bazaar',
    'version': '1.0.0',
    'shellMinVersion': '1.0.0',
    'bundleHash': 'a' * 64,
    'motion': 'lively',
    'dark': 'light-only',
    'behaviours': ['countdown-strip'],
    'sections': ['hero', 'products', 'delivery', 'contact'],
    'dataNeeds': ['deliveryFee'],
    'cartLayout': 'drawer',
    'modalLayout': 'default',
    'fonts': [
      {'family': 'Tajawal', 'weights': [400, 700], 'origin': 'self'},
    ],
  };
  if (overrides != null) manifest.addAll(overrides);
  return manifest;
}

Map<String, String> validSections() => {
      'hero.html':
          '<section data-section="header"><div data-section="brand"><span data-slot="brand-name"></span><span data-slot="whatsapp-number"></span></div><h1>عروض</h1></section>',
      'products.html':
          '<section><div data-slot="product-card"></div></section>',
      'delivery.html':
          '<section><span data-slot="delivery-fee"></span></section>',
      'contact.html': '<section><p>تواصل</p></section>',
    };

Map<String, dynamic> validTokens() => {
      'light': {
        'bg': '#ffffff',
        'bg2': '#f5f5f5',
        'surface': '#ffffff',
        'surfaceStrong': '#ffffff',
        'border': '#eeeeee',
        'text': '#141414',
        'textSoft': '#666666',
        'accent': '#f68b1e',
        'accent2': '#141414',
        'warm': '#f68b1e',
        'radius': '16px',
        'font': 'Tajawal',
      },
    };

const String validStyles =
    '.card { transform: translateY(0); transition: transform 300ms; }';

void main() {
  group('validateBundleManifest', () {
    test('a valid manifest passes', () {
      final report = validateBundleManifest(validManifest());
      expect(report.passed, isTrue);
      expect(report.failedChecks, isEmpty);
    });

    test('unknown id / id mismatch fail', () {
      expect(
          validateBundleManifest(validManifest(overrides: {'id': 'mall'}))
              .failedChecks,
          contains('manifest.id'));
      expect(
          validateBundleManifest(validManifest(), registryId: 'gallery')
              .failedChecks,
          contains('manifest.id.mismatch'));
    });

    test('bad version / shellMinVersion newer than live fail', () {
      expect(
          validateBundleManifest(validManifest(overrides: {'version': '1'}))
              .failedChecks,
          contains('manifest.version'));
      expect(
          validateBundleManifest(
                  validManifest(overrides: {'shellMinVersion': '2.0.0'}))
              .failedChecks,
          contains('manifest.shellMinVersion.newerThanShell'));
      expect(
          validateBundleManifest(
                  validManifest(overrides: {'shellMinVersion': '1.0.0'}))
              .passed,
          isTrue);
    });

    test('bad hash / missing name fail', () {
      expect(
          validateBundleManifest(
                  validManifest(overrides: {'bundleHash': 'xyz'}))
              .failedChecks,
          contains('manifest.bundleHash'));
      expect(
          validateBundleManifest(validManifest(overrides: {'nameAr': ''}))
              .failedChecks,
          contains('manifest.nameAr'));
    });

    test('missing required section / unknown behaviour / bad dataNeed fail',
        () {
      expect(
          validateBundleManifest(validManifest(
                  overrides: {'sections': ['hero', 'products']}))
              .failedChecks,
          contains('manifest.sections.missing.delivery'));
      expect(
          validateBundleManifest(
                  validManifest(overrides: {'behaviours': ['teleport']}))
              .failedChecks,
          contains('manifest.behaviours.teleport'));
      expect(
          validateBundleManifest(
                  validManifest(overrides: {'dataNeeds': ['stockCount']}))
              .failedChecks,
          contains('manifest.dataNeeds.stockCount'));
    });

    test('font origin outside the CSP allow-list / bad layout fail', () {
      expect(
          validateBundleManifest(validManifest(overrides: {
            'fonts': [
              {
                'family': 'Evil',
                'weights': [400],
                'origin': 'https://evil.example.com'
              }
            ]
          })).failedChecks,
          contains('manifest.fonts.origin'));
      expect(
          validateBundleManifest(
                  validManifest(overrides: {'cartLayout': 'popup'}))
              .failedChecks,
          contains('manifest.cartLayout'));
    });
  });

  group('validateBundleFiles', () {
    test('a valid bundle passes', () {
      final report = validateBundleFiles(
        manifest: validManifest(),
        sections: validSections(),
        stylesCss: validStyles,
        tokens: validTokens(),
        registryId: 'bazaar',
      );
      expect(report.passed, isTrue);
      expect(report.failedChecks, isEmpty);
    });

    test('missing tokens.json / missing delivery section / missing brand slot fail',
        () {
      final noTokens = validateBundleFiles(
        manifest: validManifest(),
        sections: validSections(),
        stylesCss: validStyles,
      );
      expect(noTokens.failedChecks, contains('tokens.json.missing'));

      final sections = validSections()..remove('delivery.html');
      expect(
          validateBundleFiles(
            manifest: validManifest(),
            sections: sections,
            stylesCss: validStyles,
            tokens: validTokens(),
          ).failedChecks,
          contains('sections.missing.delivery'));

      final noBrand = validSections()
        ..['hero.html'] = '<section><h1>عروض</h1></section>';
      expect(
          validateBundleFiles(
            manifest: validManifest(),
            sections: noBrand,
            stylesCss: validStyles,
            tokens: validTokens(),
          ).failedChecks,
          contains('brandSlot'));
    });

    test('no-JavaScript scan rejects script / handlers / javascript: / iframe',
        () {
      BundleValidationReport withSection(String html) {
        final sections = validSections()..['products.html'] = html;
        return validateBundleFiles(
          manifest: validManifest(),
          sections: sections,
          stylesCss: validStyles,
          tokens: validTokens(),
        );
      }

      expect(withSection('<section><script>alert(1)</script></section>')
          .failedChecks, contains('noJs.script'));
      expect(
          withSection(
                  '<section><img src="x" onerror="alert(1)"></section>')
              .failedChecks,
          contains('noJs.eventHandler'));
      expect(
          withSection(
                  '<section><a href="javascript:alert(1)">x</a></section>')
              .failedChecks,
          contains('noJs.javascriptUrl'));
      expect(withSection('<section><iframe src="x"></iframe></section>')
          .failedChecks, contains('noJs.iframe'));
      expect(withSection('<section><form></form></section>').failedChecks,
          contains('noJs.form'));
    });

    test('wa.me links pass — allow-listed contact origin (decision 3)',
        () {
      // WhatsApp is the store's own contact channel: https://wa.me/
      // is an allow-listed link origin (gateway-rules.json
      // linkOrigins), so bundles keep their hardcoded wa.me hrefs.
      // Any OTHER absolute href still fails.
      final sections = validSections()
        ..['contact.html'] =
            '<section><a href="https://wa.me/201557887719">واتساب</a></section>';
      final report = validateBundleFiles(
        manifest: validManifest(),
        sections: sections,
        stylesCss: validStyles,
        tokens: validTokens(),
      );
      expect(report.failedChecks, isNot(contains('href.external')));
      expect(report.passed, isTrue);
      final external = validSections()
        ..['contact.html'] =
            '<section><a href="https://example.com/x">خارجي</a></section>';
      expect(
          validateBundleFiles(
            manifest: validManifest(),
            sections: external,
            stylesCss: validStyles,
            tokens: validTokens(),
          ).failedChecks,
          contains('href.external'));
      final ownPage = validSections()
        ..['contact.html'] =
            '<section><a href="/products">المنتجات</a></section>';
      expect(
          validateBundleFiles(
            manifest: validManifest(),
            sections: ownPage,
            stylesCss: validStyles,
            tokens: validTokens(),
          ).passed,
          isTrue);
    });

    test('unknown slot / unknown action / unknown tag fail', () {
      BundleValidationReport withSection(String html) {
        final sections = validSections()..['products.html'] = html;
        return validateBundleFiles(
          manifest: validManifest(),
          sections: sections,
          stylesCss: validStyles,
          tokens: validTokens(),
        );
      }

      expect(
          withSection('<section><span data-slot="stock-count"></span></section>')
              .failedChecks,
          contains('slots.stock-count'));
      expect(
          withSection(
                  '<section><button data-action="buy-now"></button></section>')
              .failedChecks,
          contains('actions.buy-now'));
      expect(withSection('<section><table></table></section>').failedChecks,
          contains('tags.table'));
    });

    test('motion budget: width/blur/too-long fail, transform passes', () {
      BundleValidationReport withCss(String css) {
        return validateBundleFiles(
          manifest: validManifest(),
          sections: validSections(),
          stylesCss: css,
          tokens: validTokens(),
        );
      }

      expect(withCss('.a { transition: width 300ms; }').failedChecks,
          contains('motion.property'));
      expect(withCss('.a { transition: transform 2000ms; }').failedChecks,
          contains('motion.maxDuration'));
      expect(withCss('.a { filter: blur(4px); }').failedChecks,
          contains('motion.blur'));
      expect(
          withCss(
                  '@keyframes s { from { width: 10px; } to { width: 20px; } }')
              .failedChecks,
          contains('motion.keyframes'));
      expect(withCss(validStyles).passed, isTrue);
    });

    test('CSS scoping: forbidden selectors and display:none on a price fail',
        () {
      BundleValidationReport withCss(String css) {
        return validateBundleFiles(
          manifest: validManifest(),
          sections: validSections(),
          stylesCss: css,
          tokens: validTokens(),
        );
      }

      expect(withCss('#cartDrawer { color: red; }').failedChecks,
          contains('css.forbiddenSelector'));
      // display:none on a price INSIDE a transactional surface fails…
      expect(withCss('#modal .price { display: none; }').failedChecks,
          contains('css.hiddenTransactional'));
      // …but hiding an absent old-price block on a browsing surface
      // (the honest "absent → block hides" rule) does not.
      expect(withCss('.sl-old-price:empty { display: none; }').passed,
          isTrue);
      expect(withCss('.note { display: none; }').passed, isTrue);
    });

    test('infinite ambient loops are exempt from the duration cap', () {
      BundleValidationReport withCss(String css) {
        return validateBundleFiles(
          manifest: validManifest(),
          sections: validSections(),
          stylesCss: css,
          tokens: validTokens(),
        );
      }

      expect(
          withCss('.m { animation: marquee 20s linear infinite; }').passed,
          isTrue);
      expect(
          withCss('.z { animation: zoom 10s ease-in-out infinite alternate; }')
              .passed,
          isTrue);
      expect(withCss('.r { animation: rise 2000ms ease both; }').failedChecks,
          contains('motion.maxDuration'));
    });

    test('CSS properties outside the allow-list fail', () {
      final report = validateBundleFiles(
        manifest: validManifest(),
        sections: validSections(),
        stylesCss: '.a { float: left; }',
        tokens: validTokens(),
      );
      expect(report.failedChecks, contains('css.property.float'));
    });

    test('physical left/right is a warning, never a failure', () {
      final report = validateBundleFiles(
        manifest: validManifest(),
        sections: validSections(),
        stylesCss: '.a { left: 0; }',
        tokens: validTokens(),
      );
      expect(report.passed, isTrue);
      expect(report.warnings, contains('rtl.physicalPosition'));
    });

    test('dark tokens required only when dark is variant', () {
      final variant = validateBundleFiles(
        manifest: validManifest(overrides: {'dark': 'variant'}),
        sections: validSections(),
        stylesCss: validStyles,
        tokens: validTokens(),
      );
      expect(variant.failedChecks, contains('tokens.dark'));
      final lightOnly = validateBundleFiles(
        manifest: validManifest(overrides: {'dark': 'light-only'}),
        sections: validSections(),
        stylesCss: validStyles,
        tokens: validTokens(),
      );
      expect(lightOnly.passed, isTrue);
    });
  });

  group('bundle hash', () {
    test('canonical JSON is key-order independent', () {
      expect(
          canonicalJson({'b': 1, 'a': {'d': 4, 'c': 3}}),
          canonicalJson({'a': {'c': 3, 'd': 4}, 'b': 1}));
    });

    test('preview.png is never in the hashed file set', () {
      final files = canonicalBundleFiles(
        manifest: validManifest(),
        sections: validSections(),
        stylesCss: validStyles,
        tokens: validTokens(),
      );
      expect(files.keys, isNot(contains('preview.png')));
      expect(
          files.keys.toList()..sort(),
          ['manifest.json', 'sections/contact.html',
            'sections/delivery.html', 'sections/hero.html',
            'sections/products.html', 'styles.css', 'tokens.json']);
    });

    test('matching hash passes, tampered file fails', () {
      final manifest = validManifest();
      final files = canonicalBundleFiles(
        manifest: manifest,
        sections: validSections(),
        stylesCss: validStyles,
        tokens: validTokens(),
      );
      final hash = computeBundleHash(files);
      manifest['bundleHash'] = hash;
      final ok = validateBundleFiles(
        manifest: manifest,
        sections: validSections(),
        stylesCss: validStyles,
        tokens: validTokens(),
        expectedBundleHash: hash,
        registryId: 'bazaar',
      );
      expect(ok.passed, isTrue);
      final tampered = validateBundleFiles(
        manifest: manifest,
        sections: validSections(),
        stylesCss: '.card { color: red; }',
        tokens: validTokens(),
        expectedBundleHash: hash,
        registryId: 'bazaar',
      );
      expect(tampered.failedChecks, contains('bundleHash.mismatch'));
    });
  });

  group('classic wrap', () {
    Map<String, dynamic> classicManifest({String? bundleHash}) {
      return {
        'id': 'classic',
        'nameAr': 'الكلاسيكي',
        'nameEn': 'Classic',
        'version': '1.0.0',
        'shellMinVersion': '1.0.0',
        'bundleHash': bundleHash ?? 'd' * 64,
        'motion': 'calm',
        'dark': 'variant',
        'behaviours': [],
        'sections': [
          'hero',
          'marquee',
          'categories',
          'featured',
          'offers',
          'products',
          'delivery',
          'contact',
          'about'
        ],
        'dataNeeds': [],
        'cartLayout': 'drawer',
        'modalLayout': 'default',
        'fonts': [
          {'family': 'Tajawal', 'weights': [300, 400], 'origin': 'self'},
        ],
      };
    }

    test('wrap validates by identity + tokens + hash, skipping section checks',
        () {
      final manifest = classicManifest();
      final files = canonicalClassicWrapFiles(
        manifest: manifest,
        indexHtml: '<html><body>live site</body></html>',
        classicJson: '{"id": "classic"}',
        stylesCss: '.x { backdrop-filter: blur(4px); }',
        tokens: validTokens(),
      );
      // Dark tokens required: classic declares dark variant.
      final tokens = Map<String, dynamic>.from(validTokens())
        ..['dark'] = validTokens()['light'];
      final filesWithDark = canonicalClassicWrapFiles(
        manifest: manifest,
        indexHtml: '<html><body>live site</body></html>',
        classicJson: '{"id": "classic"}',
        stylesCss: '.x { backdrop-filter: blur(4px); }',
        tokens: tokens,
      );
      expect(files, isNot(filesWithDark));
      final hash = computeBundleHash(filesWithDark);
      manifest['bundleHash'] = hash;
      final report = validateBundleFiles(
        manifest: manifest,
        stylesCss: '.x { backdrop-filter: blur(4px); }',
        tokens: tokens,
        expectedBundleHash: hash,
        registryId: 'classic',
        indexHtml: '<html><body>live site</body></html>',
        classicJson: '{"id": "classic"}',
      );
      expect(report.passed, isTrue, reason: '${report.failedChecks}');
    });

    test('tampered wrap file fails the hash', () {
      final manifest = classicManifest();
      final tokens = Map<String, dynamic>.from(validTokens())
        ..['dark'] = validTokens()['light'];
      final files = canonicalClassicWrapFiles(
        manifest: manifest,
        indexHtml: '<html><body>live site</body></html>',
        classicJson: '{"id": "classic"}',
        stylesCss: '.x { color: red; }',
        tokens: tokens,
      );
      manifest['bundleHash'] = computeBundleHash(files);
      final report = validateBundleFiles(
        manifest: manifest,
        stylesCss: '.x { color: red; }',
        tokens: tokens,
        expectedBundleHash: manifest['bundleHash'] as String,
        registryId: 'classic',
        indexHtml: '<html><body>CHANGED</body></html>',
        classicJson: '{"id": "classic"}',
      );
      expect(report.failedChecks, contains('bundleHash.mismatch'));
    });
  });

  group('pointer history stack', () {
    List<Map<String, dynamic>> history(List<String> ids) => [
          for (final id in ids)
            {
              'templateId': id,
              'bundleVersion': '1.0.0',
              'bundleHash': 'h',
              'action': 'activate',
            },
        ];

    test('rollback target is the second-last entry', () {
      expect(rollbackTargetEntry(history(['classic', 'bazaar']))!['templateId'],
          'classic');
      expect(rollbackTargetEntry(history(['classic'])), isNull);
      expect(rollbackTargetEntry([]), isNull);
    });

    test('double rollback walks the stack backwards, never ping-pongs', () {
      var stack = history(['classic', 'bazaar']);
      // Activate A → B (history [A, B]), rollback → A.
      expect(rollbackTargetEntry(stack)!['templateId'], 'classic');
      stack = appendHistoryEntry(stack, {
        'templateId': 'classic',
        'bundleVersion': '1.0.0',
        'bundleHash': 'h',
        'action': 'rollback',
      });
      expect(stack.map((e) => e['templateId']).toList(),
          ['classic', 'bazaar', 'classic']);
      // Rollback again → B (the template live before A).
      expect(rollbackTargetEntry(stack)!['templateId'], 'bazaar');
      stack = appendHistoryEntry(stack, {
        'templateId': 'bazaar',
        'bundleVersion': '1.0.0',
        'bundleHash': 'h',
        'action': 'rollback',
      });
      expect(rollbackTargetEntry(stack)!['templateId'], 'classic');
    });
  });

  group('approval freeze + classic pin', () {
    test('approval binds the exact hash; a changed hash needs re-approval',
        () {
      final approved = parseTemplateDoc('bazaar', {
        'name': 'بازار',
        'nameAr': 'بازار',
        'nameEn': 'Deal Bazaar',
        'version': 1,
        'schemaVersion': 1,
        'status': 'approved',
        'bundleVersion': '1.0.0',
        'bundleHash': 'a' * 64,
        'shellMinVersion': '1.0.0',
        'approval': {
          'approver': 'mohamed',
          'shellVersion': '1.0.0',
          'bundleHash': 'a' * 64,
        },
      });
      expect(approved.approvalStillValid, isTrue);
      final changed = parseTemplateDoc('bazaar', {
        'name': 'بازار',
        'nameAr': 'بازار',
        'nameEn': 'Deal Bazaar',
        'version': 1,
        'schemaVersion': 1,
        'status': 'approved',
        'bundleVersion': '1.0.0',
        'bundleHash': 'b' * 64,
        'shellMinVersion': '1.0.0',
        'approval': {
          'approver': 'mohamed',
          'shellVersion': '1.0.0',
          'bundleHash': 'a' * 64,
        },
      });
      expect(changed.approvalStillValid, isFalse);
    });

    test('classic cannot be archived while live or in the history stack',
        () {
      expect(
          classicMayBeArchived(isLive: true, inHistory: false), isFalse);
      expect(
          classicMayBeArchived(isLive: false, inHistory: true), isFalse);
      expect(
          classicMayBeArchived(isLive: false, inHistory: false), isTrue);
    });

    test('bundle record carries the Hosting body path + glossary names',
        () {
      final record = parseTemplateDoc('scroll', {
        'name': 'اسكرول',
        'nameAr': 'اسكرول',
        'nameEn': 'Scroll',
        'version': 1,
        'schemaVersion': 1,
        'status': 'draft',
        'bundleVersion': '1.0.0',
        'bundleHash': 'c' * 64,
        'shellMinVersion': '1.0.0',
      });
      expect(record.isBundle, isTrue);
      expect(record.bodyPath, '/templates/scroll/1.0.0/manifest.json');
      expect(record.displayNameAr, 'اسكرول');
      expect(record.displayNameEn, 'Scroll');
      expect(record.shortHash, 'c' * 12);
    });

    test('v1 registry docs still validate through the old checks', () {
      expect(validateTemplateDoc(Templates.classic.toMap()).passed, isTrue);
      final badBundle = validateTemplateDoc({
        'name': 'x',
        'version': 1,
        'schemaVersion': 1,
        'status': 'draft',
        'bundleHash': 'not-a-hash',
        'bundleVersion': '1.0.0',
        'shellMinVersion': '1.0.0',
      });
      expect(badBundle.failedChecks, contains('manifest.bundleHash'));
    });
  });

  group('preview slugs', () {
    test('128-bit slug: 22 url-safe chars, unique per issue', () {
      final a = generatePreviewSlug();
      final b = generatePreviewSlug();
      expect(a.length, 22);
      expect(RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(a), isTrue);
      expect(a, isNot(b));
      expect(previewUrlForSlug(a),
          '$storefrontBaseUrl/?preview=$a');
    });
  });

  group('semver', () {
    test('compareSemver orders versions', () {
      expect(compareSemver('1.0.0', '1.0.0'), 0);
      expect(compareSemver('0.9.9', '1.0.0'), lessThan(0));
      expect(compareSemver('1.0.1', '1.0.0'), greaterThan(0));
      expect(compareSemver('x', '1.0.0'), lessThan(0));
    });
  });

  group('promo end date (D2)', () {
    test('empty means no countdown and is valid', () {
      expect(validatePromoEndDate(null), isNull);
      expect(validatePromoEndDate(''), isNull);
      expect(validatePromoEndDate('   '), isNull);
    });

    test('a valid ISO 8601 date-time passes', () {
      expect(validatePromoEndDate('2026-12-01T23:59:00+02:00'), isNull);
      expect(validatePromoEndDate('2026-12-01T23:59:00'), isNull);
    });

    test('date-only and garbage fail', () {
      expect(validatePromoEndDate('2026-12-01'), isNotNull);
      expect(validatePromoEndDate('tomorrow'), isNotNull);
      expect(validatePromoEndDate('2026-13-01T00:00:00'), isNotNull);
    });

    test('promoBannerMap round-trips endDate', () {
      final banner = promoBannerMap(
        imageUrl: '',
        title: 'عرض',
        subtitle: '',
        linkType: 'none',
        linkId: '',
        endDate: '2026-12-01T23:59:00+02:00',
      );
      expect(banner['endDate'], '2026-12-01T23:59:00+02:00');
      final noDate = promoBannerMap(
        imageUrl: '',
        title: 'عرض',
        subtitle: '',
        linkType: 'none',
        linkId: '',
      );
      expect(noDate['endDate'], '');
      final doc = buildHomepageDoc(
        heroProductIds: [],
        promoBanners: [banner],
        featuredProductId: '',
        deliveryBanner: {'title': '', 'subtitle': '', 'imageUrl': ''},
      );
      final parsed = parseHomepageDoc(doc);
      final banners = parsed['promoBanners'] as List;
      expect(
          (banners.first as Map)['endDate'], '2026-12-01T23:59:00+02:00');
    });
  });

  group('shared fixture parity (entries 18 + 22)', () {
    // The single fixture set both gateways run against (rules child's
    // entry 22). The Dart gateway runs each fixture through
    // validateBundleFiles with the fixture's own bundleHash as the
    // expected hash — the real load path. Fixture reasons are
    // gateway-agnostic; [dartChecks] translates each fixture to the
    // EXACT failedChecks this gateway reports (read from the
    // implementation — a disagreement here is a flag, never a reason
    // to edit the fixture).
    //
    // Translation notes (gateway vocabulary quirks, entry 11):
    // - 'motion-backdrop-filter' surfaces as motion.blur: the scanner
    //   lumps backdrop-filter in with blur and has no separate code.
    // - 'css-import-origin' surfaces as BOTH css.url and css.import:
    //   the url() scanner also matches the URL inside an @import.
    // - 'css-hides-confirm' surfaces as css.forbiddenSelector ONLY:
    //   _scanCssDisplayNone lowercases the selector but compares it
    //   against the mixed-case forbidden selectors, so #checkoutBtn
    //   never matches there (flagged to entry 11 — the bundle still
    //   fails, so no safety impact).
    // - 'missing-tokens' also surfaces as bundleHash.unverifiable:
    //   without tokens.json the hash cannot be recomputed.
    // - 'writes-products-grid' surfaces as attributes.id: any id
    //   attribute is rejected, which is exactly the no-by-id rule.
    List<Map<String, dynamic>> loadSharedFixtures() {
      final dir = Directory('test/templates/fixtures');
      final index = jsonDecode(
        File('${dir.path}/index.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      return (index['fixtures'] as List).cast<String>().map((name) {
        return jsonDecode(File('${dir.path}/$name.json').readAsStringSync())
            as Map<String, dynamic>;
      }).toList();
    }

    BundleValidationReport runFixture(Map<String, dynamic> fx) {
      final manifest = (fx['manifest'] as Map).cast<String, dynamic>();
      final sections = ((fx['sections'] as Map?) ?? {})
          .map((k, v) => MapEntry(k.toString(), v.toString()));
      return validateBundleFiles(
        manifest: manifest,
        sections: sections,
        stylesCss: fx['styles'] as String?,
        tokens: (fx['tokens'] as Map?)?.cast<String, dynamic>(),
        expectedBundleHash: manifest['bundleHash'] as String?,
        registryId: fx['templateId'] as String?,
      );
    }

    // Fixture id → the exact failedChecks validateBundleFiles reports.
    const dartChecks = <String, List<String>>{
      'invalid-script-tag': ['noJs.script'],
      'invalid-onclick': ['noJs.eventHandler'],
      'invalid-onerror-img': ['noJs.eventHandler'],
      'invalid-onload-svg': ['noJs.eventHandler', 'tags.svg'],
      'invalid-javascript-url': ['noJs.javascriptUrl'],
      // The iframe's external src fires src.origin too — the JS
      // gateway reports the same extra (img_origin_not_allowed) next
      // to the forbidden tag, so this is parity, not a second defect.
      'invalid-iframe': ['noJs.iframe', 'src.origin'],
      'invalid-form': ['noJs.form'],
      // The <meta charset> also fires attributes.charset — the JS
      // gateway reports the same extra (attribute_not_allowed:
      // charset) next to the forbidden tag.
      'invalid-meta': ['noJs.meta', 'attributes.charset'],
      // The <link> tag's rel + external href fire too — JS reports
      // the same extras (attribute_not_allowed:rel, href_external).
      'invalid-link': ['noJs.link', 'attributes.rel', 'href.external'],
      'invalid-svg-scriptable': ['noJs.script', 'tags.svg'],
      'invalid-missing-tokens': [
        'tokens.json.missing',
        'bundleHash.unverifiable'
      ],
      'invalid-missing-delivery': [
        'manifest.sections.missing.delivery',
        'sections.missing.delivery'
      ],
      'invalid-missing-brand-slot': ['brandSlot'],
      // `filter` is not in the CSS property allow-list either — JS
      // reports the same extra (css_property_not_allowed:filter).
      'invalid-motion-blur': [
        'css.property.filter',
        'motion.blur',
        'motion.keyframes'
      ],
      // `backdrop-filter` is not in the CSS property allow-list —
      // JS reports the same extra (css_property_not_allowed).
      'invalid-motion-backdrop-filter': [
        'css.property.backdrop-filter',
        'motion.blur'
      ],
      'invalid-motion-width': ['motion.property'],
      'invalid-motion-height': ['motion.keyframes'],
      // `background-image` is not in the CSS property allow-list —
      // JS reports the same extra (css_property_not_allowed).
      'invalid-css-url-origin': ['css.url', 'css.property.background-image'],
      'invalid-css-import-origin': ['css.url', 'css.import'],
      'invalid-data-needs-unknown-field': ['manifest.dataNeeds.stockCount'],
      'invalid-font-origin': ['manifest.fonts.origin'],
      'invalid-behaviour-unknown': ['manifest.behaviours.teleport'],
      'invalid-shell-version': ['manifest.shellMinVersion.newerThanShell'],
      'invalid-hash-mismatch': ['bundleHash.mismatch'],
      'invalid-unknown-slot': ['slots.product-rating'],
      'invalid-unknown-action': ['actions.buy-now'],
      'invalid-unknown-section': [
        'manifest.sections.checkout',
        'sections.unknown.checkout'
      ],
      // The id="productsGrid" names the violation (the shell owns
      // the grid) on top of the bare id-attribute failure; JS names
      // only the attribute, verdict agrees.
      'invalid-writes-products-grid': [
        'noJs.writesProductsGrid',
        'attributes.id'
      ],
      // `#checkoutBtn { display: none; }` hides a transactional
      // surface — a second genuine violation JS does not name.
      'invalid-css-hides-confirm': [
        'css.forbiddenSelector',
        'css.hiddenTransactional'
      ],
    };

    test('every shared fixture gets the verdict it declares', () {
      final fixtures = loadSharedFixtures();
      expect(fixtures.length, 36);
      for (final fx in fixtures) {
        if (fx['kind'] == 'old-shell') continue;
        final expected = fx['expected'] as Map<String, dynamic>;
        final report = runFixture(fx);
        expect(report.passed, expected['verdict'] == 'pass',
            reason: '${fx['id']}: gateway verdict');
        expect(report.failedChecks.toSet(),
            (dartChecks[fx['id']] ?? const <String>[]).toSet(),
            reason: '${fx['id']}: gateway checks');
      }
    });

    test('the five valid direction bundles + the slot-contract bundle pass, hash included', () {
      final fixtures = loadSharedFixtures();
      for (final id in [
        'valid-bazaar',
        'valid-gallery',
        'valid-scroll',
        'valid-speclab',
        'valid-boutique',
        'slot-contract-valid',
      ]) {
        final fx = fixtures.firstWhere((f) => f['id'] == id);
        final report = runFixture(fx);
        expect(report.passed, isTrue, reason: '$id: ${report.failedChecks}');
        expect(report.failedChecks, isEmpty);
      }
    });

    test('fixture hashes agree with the gateway canonicalisation', () {
      // The generator (entry 22) and the gateway (entry 11) must hash
      // the same canonical file set: recompute from the fixture files
      // and compare with the manifest's bundleHash.
      final fixtures = loadSharedFixtures();
      for (final fx in fixtures) {
        if (fx['kind'] == 'old-shell') continue;
        if (fx['tokens'] == null) continue; // missing-tokens: no hash
        final manifest = (fx['manifest'] as Map).cast<String, dynamic>();
        final sections = ((fx['sections'] as Map?) ?? {})
            .map((k, v) => MapEntry(k.toString(), v.toString()));
        final files = canonicalBundleFiles(
          manifest: manifest,
          sections: sections,
          stylesCss: fx['styles'] as String,
          tokens: (fx['tokens'] as Map).cast<String, dynamic>(),
        );
        final recomputed = computeBundleHash(files);
        if (fx['id'] == 'invalid-hash-mismatch') {
          expect(manifest['bundleHash'], 'f' * 64);
          expect(recomputed, isNot(manifest['bundleHash']));
        } else {
          expect(recomputed, manifest['bundleHash'],
              reason: '${fx['id']}: bundleHash');
        }
      }
    });

    test('the CSS-scoping fixture fails on the forbidden selector', () {
      final fx = loadSharedFixtures()
          .firstWhere((f) => f['id'] == 'invalid-css-hides-confirm');
      final report = runFixture(fx);
      expect(report.passed, isFalse);
      expect(report.failedChecks, contains('css.forbiddenSelector'));
    });
  });
}
