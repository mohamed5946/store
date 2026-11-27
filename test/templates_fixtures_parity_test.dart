// Shared-fixture parity tests (spec entries 18, 22): the Dart
// gateway runs against every fixture in test/templates/fixtures/
// and must reach the SAME verdict as the fixture's expected verdict
// (and as the JS gateway). A fixture added there must pass or fail
// identically in both.
//
// FIXTURE HISTORY: `invalid-hash-mismatch` was originally
// byte-identical to `valid-bazaar` including its bundleHash (a
// generator defect — no correct implementation could fail it). The
// rules child regenerated it 2026-11-27 with a deliberately wrong
// hash (`f` * 64); content is still identical to valid-bazaar, but
// the hash is now a real tamper, so both gateways fail it on
// bundleHash.mismatch. The test below pins that.
// The JS gateway used to PASS `invalid-motion-height` (its checkCss
// did not scan @keyframes bodies); the integration fix (decision 5)
// added the @keyframes-body inspection, so the shell now fails it
// as motion.keyframes, matching Dart (motion.keyframes) and the PC
// (keyframe-property.height) on the verdict.
//
// Pure logic — reads fixture JSON from disk, no Firestore, no
// emulator.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/services/templates_service.dart';

void main() {
  group('shared fixtures parity (entry 22)', () {
    late List<String> fixtureNames;
    late Map<String, dynamic> fixtures;

    setUpAll(() {
      final index = jsonDecode(
        File('test/templates/fixtures/index.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      fixtureNames =
          (index['fixtures'] as List).map((e) => e.toString()).toList();
      fixtures = {
        for (final name in fixtureNames)
          name: jsonDecode(
            File('test/templates/fixtures/$name.json').readAsStringSync(),
          ) as Map<String, dynamic>,
      };
    });

    test('index lists 36 fixtures', () {
      expect(fixtureNames.length, 36);
    });

    test('every bundle fixture reaches its expected verdict', () {
      final mismatches = <String>[];
      for (final name in fixtureNames) {
        if (name == 'old-shell-shape') continue;
        final fx = fixtures[name]!;
        final manifest =
            Map<String, dynamic>.from(fx['manifest'] as Map);
        final sections = (fx['sections'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            ) ??
            <String, String>{};
        final styles = fx['styles'] as String?;
        final tokens = fx['tokens'] == null
            ? null
            : Map<String, dynamic>.from(fx['tokens'] as Map);
        final report = validateBundleFiles(
          manifest: manifest,
          sections: sections,
          stylesCss: styles,
          tokens: tokens,
          expectedBundleHash: manifest['bundleHash'] as String?,
          registryId: fx['templateId'] as String?,
        );
        final expectedPass =
            (fx['expected'] as Map)['verdict'] == 'pass';
        if (report.passed != expectedPass) {
          mismatches.add(
              '$name: dart=${report.passed ? 'pass' : 'fail'} '
              'expected=${expectedPass ? 'pass' : 'fail'} '
              'checks=${report.failedChecks}');
        }
      }
      expect(mismatches, isEmpty, reason: mismatches.join('\n'));
    });

    test(
        'invalid-hash-mismatch is valid-bazaar content with a '
        'deliberately wrong hash (fixture regenerated 2026-11-27)', () {
      final bad = fixtures['invalid-hash-mismatch']!;
      final good = fixtures['valid-bazaar']!;
      // Content still identical; only id + the hash differ.
      expect(bad['sections'], good['sections']);
      expect(bad['styles'], good['styles']);
      expect(bad['tokens'], good['tokens']);
      final badManifest =
          Map<String, dynamic>.from(bad['manifest'] as Map);
      final goodManifest =
          Map<String, dynamic>.from(good['manifest'] as Map);
      expect(badManifest['bundleHash'], 'f' * 64);
      badManifest.remove('bundleHash');
      badManifest.remove('id');
      goodManifest.remove('bundleHash');
      goodManifest.remove('id');
      expect(badManifest, goodManifest);
      // …so a correct gateway fails it on the hash alone — and the
      // JS gateway agrees (hash:hash_mismatch, verified by probe).
      final report = validateBundleFiles(
        manifest: Map<String, dynamic>.from(bad['manifest'] as Map),
        sections: (bad['sections'] as Map).map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ),
        stylesCss: bad['styles'] as String?,
        tokens: Map<String, dynamic>.from(bad['tokens'] as Map),
        expectedBundleHash:
            (bad['manifest'] as Map)['bundleHash'] as String?,
        registryId: bad['templateId'] as String?,
      );
      expect(report.passed, isFalse);
      expect(report.failedChecks, ['bundleHash.mismatch']);
    });

    test('old-shell-shape: the entry-11 gateway validates the new registry doc (the old v1 gateway could not)',
        () {
      final fx = fixtures['old-shell-shape']!;
      final doc =
          Map<String, dynamic>.from(fx['registryDoc'] as Map);
      // The fixture records what the OLD v1 gateway did: it could
      // not validate a bundle registry document (string version, no
      // schemaVersion, Hosting bodyPath), so it fell back to classic
      // (oldGatewayPasses: false, fallback: classic). Entry 11
      // branches validateTemplateDoc to the bundle rules for bundle
      // docs, so the current gateway PASSES this doc — the fallback
      // is history, kept here as the fixture's record.
      expect(fx['expected']['oldGatewayPasses'], isFalse);
      expect(fx['expected']['fallback'], 'classic');
      expect(validateTemplateDoc(doc).passed, isTrue);
    });

    test('the real classic wrap on disk verifies its registry hash', () {
      // The shell child's classic bundle (entry 7): manifest +
      // index.html + classic.json + styles.css + tokens.json.
      // The Dart hash must equal the bundleHash the shell child
      // recorded in the manifest — otherwise the admin "validate
      // live files" action would fail a good classic bundle.
      // NOTE 2026-11-27 ~02:45 — HASH-RULE CONFLICT, coordinator
      // decision pending: the shell child changed the JS gateway
      // (00:48) to hash the RAW manifest bytes minus the bundleHash
      // line, and re-recorded this manifest's hash under that rule
      // (31872ecb…); the Dart gateway still hashes the sorted-keys
      // canonical manifest per the contract + fixture README
      // (fad8ae62… — the hash recorded before the rewrite). Same
      // content, two hashes. This test stays red until the
      // coordinator picks ONE rule (see the final report).
      final manifest = jsonDecode(
        File('storefront/templates/classic/1.0.0/manifest.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final files = canonicalClassicWrapFiles(
        manifest: Map<String, dynamic>.from(manifest),
        indexHtml:
            File('storefront/templates/classic/1.0.0/index.html')
                .readAsStringSync(),
        classicJson:
            File('storefront/templates/classic/1.0.0/classic.json')
                .readAsStringSync(),
        stylesCss:
            File('storefront/templates/classic/1.0.0/styles.css')
                .readAsStringSync(),
        tokens: jsonDecode(
          File('storefront/templates/classic/1.0.0/tokens.json')
              .readAsStringSync(),
        ) as Map<String, dynamic>,
      );
      expect(computeBundleHash(files), manifest['bundleHash']);
      final report = validateBundleFiles(
        manifest: Map<String, dynamic>.from(manifest),
        stylesCss:
            File('storefront/templates/classic/1.0.0/styles.css')
                .readAsStringSync(),
        tokens: jsonDecode(
          File('storefront/templates/classic/1.0.0/tokens.json')
              .readAsStringSync(),
        ) as Map<String, dynamic>,
        expectedBundleHash: manifest['bundleHash'] as String,
        registryId: 'classic',
        indexHtml:
            File('storefront/templates/classic/1.0.0/index.html')
                .readAsStringSync(),
        classicJson:
            File('storefront/templates/classic/1.0.0/classic.json')
                .readAsStringSync(),
      );
      expect(report.passed, isTrue, reason: '${report.failedChecks}');
    });

    test('the five real bundles on disk validate against their hashes',
        () {
      // The bundle children's authored bundles (entry 6): each must
      // pass the Dart gateway with its own recorded hash — otherwise
      // the admin could never approve it. NOTE 2026-11-27: the
      // scroll bundle is not authored yet (no directory on disk),
      // so it is skipped here — its absence is reported to the
      // coordinator, not hidden by this test.
      // NOTE 2026-11-27 (integration fix, decision 1 + 3 + 9): the
      // hash rule is CANONICAL everywhere now (gateway-rules.json
      // bundleHash.serialisation) and the manifests on disk carry
      // canonical hashes; wa.me is an allow-listed link origin and
      // speclab's tokens.light.warm is a real colour. Any failure
      // this test reports now is a real bundle defect, not a
      // cross-gateway disagreement.
      final failures = <String>[];
      for (final id in [
        'bazaar',
        'gallery',
        'scroll',
        'speclab',
        'boutique',
      ]) {
        final base = 'storefront/templates/$id/1.0.0';
        if (!File('$base/manifest.json').existsSync()) {
          // ignore: avoid_print
          print('SKIP: $id bundle not authored yet (no $base)');
          continue;
        }
        final manifest = jsonDecode(
          File('$base/manifest.json').readAsStringSync(),
        ) as Map<String, dynamic>;
        final sectionsDir = Directory('$base/sections');
        final sections = <String, String>{
          for (final f in sectionsDir.listSync().whereType<File>())
            f.uri.pathSegments.last: f.readAsStringSync(),
        };
        final report = validateBundleFiles(
          manifest: Map<String, dynamic>.from(manifest),
          sections: sections,
          stylesCss: File('$base/styles.css').readAsStringSync(),
          tokens: jsonDecode(
            File('$base/tokens.json').readAsStringSync(),
          ) as Map<String, dynamic>,
          expectedBundleHash: manifest['bundleHash'] as String,
          registryId: id,
        );
        if (!report.passed) {
          failures.add('$id: ${report.failedChecks}');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });

    test('the six valid bundles verify their registry hash', () {
      for (final name in [
        'valid-bazaar',
        'valid-gallery',
        'valid-scroll',
        'valid-speclab',
        'valid-boutique',
        'slot-contract-valid',
      ]) {
        final fx = fixtures[name]!;
        final manifest =
            Map<String, dynamic>.from(fx['manifest'] as Map);
        final files = canonicalBundleFiles(
          manifest: manifest,
          sections: (fx['sections'] as Map).map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ),
          stylesCss: fx['styles'] as String,
          tokens: Map<String, dynamic>.from(fx['tokens'] as Map),
        );
        expect(
          computeBundleHash(files),
          manifest['bundleHash'],
          reason: '$name: Dart canonical hash must match the registry hash',
        );
      }
    });
  });
}
