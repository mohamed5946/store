// Phase 3 template tests: the validation gateway, the launch
// template, and the preview-token mapping (Technical Plan v1.4 §7).
// Pure logic — no Firestore, no emulator.
//
// The v1 groups below cover the COMPAT path: v1 registry documents
// (11-token schema) still validate through the old checks, and the
// built-in classic template still parses. The bundle model (spec
// store-templates.md entries 10–22) is covered by the bundle groups
// at the end of this file plus test/templates_bundle_test.dart —
// which owns the gateway check list, the fixture parity, the
// stack-walk, the approval freeze, the classic pin, and the slugs.
// This file adds only what that file does not: the status-enum
// oracle, parseTemplateDoc on a TRUE bundle registry doc (entry 19),
// and the pointer document shape.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/screens/storefront_preview.dart';
import 'package:storeadmin/services/templates_service.dart';

void main() {
  group('validation gateway', () {
    test('the classic template passes', () {
      final report = validateTemplateDoc(Templates.classic.toMap());
      expect(report.passed, isTrue);
      expect(report.failedChecks, isEmpty);
    });

    test('missing name / bad status / bad schemaVersion fail', () {
      expect(validateTemplateDoc({}).passed, isFalse);
      expect(validateTemplateDoc({'name': 'x', 'version': 1, 'schemaVersion': 1, 'status': 'live'}).passed,
          isFalse);
      expect(
          validateTemplateDoc(
              {'name': 'x', 'version': 1, 'schemaVersion': 2, 'status': 'draft'}).passed,
          isFalse);
      expect(
          validateTemplateDoc(
              {'name': 'x', 'version': 1, 'schemaVersion': 1, 'status': 'draft'}).passed,
          isTrue);
    });

    test('grid ranges are enforced', () {
      Map<String, dynamic> withGrid(Map<String, dynamic> grid) => {
            'name': 'x',
            'version': 1,
            'schemaVersion': 1,
            'status': 'draft',
            'grid': grid,
          };
      expect(validateTemplateDoc(withGrid({'columns': 0})).passed, isFalse);
      expect(validateTemplateDoc(withGrid({'columns': 13})).passed, isFalse);
      expect(validateTemplateDoc(withGrid({'columns': 3})).passed, isTrue);
      expect(validateTemplateDoc(withGrid({'columns': null})).passed, isTrue);
      expect(validateTemplateDoc(withGrid({'rows': 0})).passed, isFalse);
      expect(validateTemplateDoc(withGrid({'rows': 21})).passed, isFalse);
      expect(validateTemplateDoc(withGrid({'rows': 2})).passed, isTrue);
      expect(validateTemplateDoc(withGrid({'minColumnWidthPx': 100})).passed,
          isFalse);
      expect(validateTemplateDoc(withGrid({'minColumnWidthPx': 250})).passed,
          isTrue);
    });

    test('unsafe token values are rejected', () {
      Map<String, dynamic> withTokens(Map<String, dynamic> tokens) => {
            'name': 'x',
            'version': 1,
            'schemaVersion': 1,
            'status': 'draft',
            'tokens': tokens,
          };
      expect(validateTemplateDoc(withTokens({'accent': 'url(evil)'}))
          .failedChecks, contains('tokens.accent'));
      expect(
          validateTemplateDoc(
              withTokens({'accent': 'javascript:alert(1)'})).failedChecks,
          contains('tokens.accent'));
      expect(validateTemplateDoc(withTokens({'accent': 'red'})).failedChecks,
          contains('tokens.accent'));
      expect(validateTemplateDoc(withTokens({'accent': '#3f7f8c'})).passed,
          isTrue);
      expect(
          validateTemplateDoc(
                  withTokens({'surface': 'rgba(255, 255, 255, 0.55)'}))
              .passed,
          isTrue);
      expect(
          validateTemplateDoc(
                  withTokens({'surface': 'rgba(255, 255, 255, 1.5)'}))
              .failedChecks,
          contains('tokens.surface'));
      expect(validateTemplateDoc(withTokens({'radius': '100px'}))
          .failedChecks, contains('tokens.radius'));
      expect(validateTemplateDoc(withTokens({'radius': '24px'})).passed,
          isTrue);
      expect(
          validateTemplateDoc(withTokens({'unknownKey': '#ffffff'}))
              .failedChecks,
          contains('tokens.unknownKey'));
    });

    test('unknown section keys and non-bool sections fail', () {
      final bad = validateTemplateDoc({
        'name': 'x',
        'version': 1,
        'schemaVersion': 1,
        'status': 'draft',
        'sections': {'hero': true, 'surprise': true},
      });
      expect(bad.failedChecks, contains('sections.surprise'));
      final badBool = validateTemplateDoc({
        'name': 'x',
        'version': 1,
        'schemaVersion': 1,
        'status': 'draft',
        'sections': {'hero': 'yes'},
      });
      expect(badBool.failedChecks, contains('sections.hero'));
    });
  });

  group('parseTemplateDoc', () {
    test('missing fields degrade to classic defaults', () {
      final record = parseTemplateDoc('x', {});
      expect(record.name, Templates.classic.name);
      expect(record.gridColumns, isNull);
      expect(record.gridRows, isNull);
      expect(record.minColumnWidthPx, 250);
      expect(record.tokens['accent'], Templates.classic.tokens['accent']);
      expect(record.sections['hero'], isTrue);
      expect(record.fromRegistry, isTrue);
    });

    test('an unsafe token falls back to the classic value', () {
      final record = parseTemplateDoc('x', {
        'name': 'Test',
        'tokens': {'accent': 'url(evil)', 'bg': '#ffffff'},
        'grid': {'columns': 99},
      });
      expect(record.tokens['accent'], '#3f7f8c');
      expect(record.tokens['bg'], '#ffffff');
      expect(record.gridColumns, isNull);
      expect(record.validationPassed, isFalse);
    });

    test('unknown fields are tolerated', () {
      final record = parseTemplateDoc('x', {
        'name': 'Test',
        'version': 1,
        'schemaVersion': 1,
        'status': 'draft',
        'futureField': {'anything': true},
      });
      expect(record.name, 'Test');
      expect(record.validationPassed, isTrue);
    });
  });

  group('classic template', () {
    test('matches the launch site values', () {
      final classic = Templates.classic;
      expect(classic.id, 'classic');
      expect(classic.tokens['accent'], '#3f7f8c');
      expect(classic.tokens['accent2'], '#8fb8b0');
      expect(classic.tokens['bg'], '#f4f6f8');
      expect(classic.tokens['text'], '#1b2430');
      expect(classic.tokens['radius'], '24px');
      expect(classic.gridColumns, isNull);
      expect(classic.gridRows, isNull);
      expect(classic.minColumnWidthPx, 250);
      expect(classic.sections,
          {'hero': true, 'promos': true, 'featured': true, 'delivery': true, 'contact': true});
      expect(classic.bodyPath, 'templates/classic.json');
      expect(classic.status, 'active');
      expect(classic.fromRegistry, isFalse);
    });

    test('gridSummary reads تلقائي × الكل for classic', () {
      expect(Templates.classic.gridSummary, 'تلقائي × الكل');
      final fixed = parseTemplateDoc('t', {
        'name': 't',
        'grid': {'columns': 3, 'rows': 2},
      });
      expect(fixed.gridSummary, '3 × 2 صفوف');
    });
  });

  group('PreviewTokens.fromTemplate', () {
    test('classic tokens map to the teal live site', () {
      final tokens =
          PreviewTokens.fromTemplate(Templates.classic.tokens);
      expect(tokens.accent, const Color(0xFF3F7F8C));
      expect(tokens.text, const Color(0xFF1B2430));
      expect(tokens.radius, 24);
    });

    test('bad values fall back to defaults', () {
      final tokens = PreviewTokens.fromTemplate({
        'accent': 'url(evil)',
        'radius': '100px',
      });
      expect(tokens.accent, const Color(0xFF0A84FF));
      expect(tokens.radius, 18);
    });
  });

  group('bundle status enum (spec oracle, entry 19)', () {
    // The lifecycle is draft → preview (gateway pass) → approved
    // (Mohamed, D1 checklist) → active (pointer write) → approved
    // again when it stops being live; retire from any non-retired
    // state. The transitions themselves are enforced by the flow
    // methods (markTemplatePreview / approveTemplate /
    // activateTemplate / setTemplateStatus) and by the rules tests
    // (entry 20) — there is no pure transition function to call
    // here, so this group pins the enum the transitions run over.
    test('the canonical enum is exactly six states', () {
      expect(bundleStatuses,
          {'draft', 'preview', 'approved', 'active', 'retired'});
      expect(bundleStatuses, isNot(contains('validating')));
      expect(bundleStatuses, isNot(contains('awaiting-approval')));
      // 'archived' is the legacy v1 spelling, not a bundle state.
      expect(bundleStatuses, isNot(contains('archived')));
    });

    test('the v1 set is the compat path only', () {
      expect(templateStatuses, {'draft', 'active', 'archived'});
    });

    test('retired has two spellings, both recognised', () {
      expect(isRetiredStatus('retired'), isTrue);
      expect(isRetiredStatus('archived'), isTrue);
      for (final s in ['draft', 'preview', 'approved', 'active']) {
        expect(isRetiredStatus(s), isFalse, reason: s);
      }
      expect(isRetiredStatus(null), isFalse);
    });
  });

  group('parseTemplateDoc on a true bundle registry doc (entry 19)', () {
    // A TRUE bundle registry doc: the SPEC shape (spec §2 line 276)
    // — the six-field manifest copy (id, nameAr, nameEn, version,
    // shellMinVersion, bundleHash) + status + approval (+
    // previewImageUrl). It does NOT carry motion / dark / sections /
    // behaviours / dataNeeds / fonts: those live in the manifest on
    // Hosting, not in Firestore. This is the shape the rules
    // (entry 10, templateShapeOk hasOnly) enforce, the shape the
    // old-shell fixture's registryDoc carries, and the shape the
    // rules tests seed. test/templates_bundle_test.dart only ever
    // feeds parseTemplateDoc hybrid docs (v1 fields + bundle
    // fields), so this is the first test of the real shape.
    Map<String, dynamic> bundleRegistryDoc(String status) {
      final manifest = jsonDecode(File(
        'test/templates/fixtures/valid-bazaar.json',
      ).readAsStringSync())['manifest'] as Map<String, dynamic>;
      return {
        'id': manifest['id'],
        'nameAr': manifest['nameAr'],
        'nameEn': manifest['nameEn'],
        'version': manifest['version'],
        'shellMinVersion': manifest['shellMinVersion'],
        'bundleHash': manifest['bundleHash'],
        'status': status,
        'approval': {
          'approver': 'uid-admin',
          'shellVersion': '1.0.0',
          'bundleHash': manifest['bundleHash'],
        },
        'previewImageUrl': manifest['previewImageUrl'],
      };
    }

    test('bundle fields parse from the registry copy', () {
      final record = parseTemplateDoc('bazaar', bundleRegistryDoc('approved'));
      final doc = bundleRegistryDoc('approved');
      expect(record.isBundle, isTrue);
      expect(record.status, 'approved');
      expect(record.displayNameAr, 'بازار');
      expect(record.displayNameEn, 'Deal Bazaar');
      expect(record.shortHash,
          (doc['bundleHash'] as String).substring(0, 12));
      expect(record.shellMinVersion, '1.0.0');
      expect(record.approvalStillValid, isTrue);
      expect(record.approvalApprover, 'uid-admin');
      // A registry doc carries no v1 'name' and its version is the
      // string '1.0.0': both degrade to the classic defaults.
      expect(record.name, Templates.classic.name);
      expect(record.version, 1);
    });

    test('a changed hash voids the approval on the parsed record', () {
      final doc = bundleRegistryDoc('approved');
      (doc['approval'] as Map<String, dynamic>)['bundleHash'] = 'b' * 64;
      final record = parseTemplateDoc('bazaar', doc);
      expect(record.isBundle, isTrue);
      expect(record.approvalStillValid, isFalse);
    });

    test('FIXED (entry 11): bundleVersion reads from string version and validation branches to the bundle rules', () {
      // Was the KNOWN BUG test: the record read the bundle version
      // from d['bundleVersion'] (absent on the spec-shaped registry
      // doc) and parseTemplateDoc always ran the v1 validator, so a
      // true registry doc failed validation and its card was hidden
      // from the Templates tab (which filters on validationPassed).
      // Entry 11 now reads the version from the string `version`
      // and branches validateTemplateDoc to the bundle rules for
      // bundle docs — the six-field registry copy validates clean.
      final record = parseTemplateDoc('bazaar', bundleRegistryDoc('approved'));
      expect(record.bundleVersion, '1.0.0');
      expect(record.bodyPath, '/templates/bazaar/1.0.0/manifest.json');
      expect(record.validationPassed, isTrue);
      expect(record.validationFailedChecks, isEmpty);
    });

    test('a spec-shaped approved registry doc parses clean', () {
      final record = parseTemplateDoc('bazaar', bundleRegistryDoc('approved'));
      expect(record.bundleVersion, '1.0.0');
      expect(record.bodyPath, '/templates/bazaar/1.0.0/manifest.json');
      expect(record.validationPassed, isTrue);
      expect(record.validationFailedChecks, isEmpty);
    });
  });

  group('registry validation (entry 11/16 — coordinator decision A)', () {
    // RESOLVED by the integration fix (decision 2, shape (A)): the
    // registry doc stays the six-field manifest copy (spec §2 line
    // 276, the rules, the old-shell fixture) and the flows validate
    // the HOSTED manifest (validateLiveBundle) at approve/activate
    // time; registry docs get the bundle-rules-only six-field check
    // (validateTemplateDoc's bundle branch). The test below pins
    // the remaining half of that split: validateBundleManifest is
    // the HOSTED-manifest validator — it still requires motion,
    // dark and sections, so a six-field registry copy fails it.
    // That is its contract now, not a bug: the flows must never
    // call it on registry data (validateRegistryTemplate,
    // approveTemplate, activateTemplate and rollbackTemplate all
    // use validateTemplateDoc + validateLiveBundle instead, and
    // the PC mirror uses validateRegistryManifest +
    // validateHostedManifest).
    test('validateBundleManifest rejects a spec-shaped registry doc', () {
      final manifest = jsonDecode(File(
        'test/templates/fixtures/valid-bazaar.json',
      ).readAsStringSync())['manifest'] as Map<String, dynamic>;
      final registryCopy = <String, dynamic>{
        'id': manifest['id'],
        'nameAr': manifest['nameAr'],
        'nameEn': manifest['nameEn'],
        'version': manifest['version'],
        'shellMinVersion': manifest['shellMinVersion'],
        'bundleHash': manifest['bundleHash'],
      };
      final report =
          validateBundleManifest(registryCopy, registryId: 'bazaar');
      expect(report.passed, isFalse);
      expect(report.failedChecks,
          ['manifest.motion', 'manifest.dark', 'manifest.sections']);
    });
  });

  group('pointer document shape (spec §2, entry 19)', () {
    // storeSettings/activeTemplate: templateId + bundleVersion +
    // bundleHash + previousTemplateId (display only) + the append-only
    // history stack; activatedBy / activatedAt optional. The stack
    // WALK is tested in test/templates_bundle_test.dart — this group
    // pins the DOCUMENT shape the rules (entry 10) and the flows
    // rely on, and that history entries keep their full record
    // (templateId + bundleVersion + bundleHash + at + by) through
    // the pure helpers.
    Map<String, dynamic> pointerDoc({bool withActor = true}) {
      final pointer = <String, dynamic>{
        'templateId': 'gallery',
        'bundleVersion': '1.0.0',
        'bundleHash': 'b' * 64,
        'previousTemplateId': 'classic',
        'history': [
          {
            'templateId': 'classic',
            'bundleVersion': '1.0.0',
            'bundleHash': 'c' * 64,
            'at': '2026-11-27T00:00:00.000Z',
            'by': 'uid-admin',
          },
          {
            'templateId': 'gallery',
            'bundleVersion': '1.0.0',
            'bundleHash': 'b' * 64,
            'at': '2026-11-27T01:00:00.000Z',
            'by': 'uid-admin',
          },
        ],
      };
      if (withActor) {
        pointer['activatedBy'] = 'uid-admin';
        pointer['activatedAt'] = '2026-11-27T01:00:00.000Z';
      }
      return pointer;
    }

    test('a pointer document carries the bundle fields + history', () {
      final pointer = pointerDoc();
      expect(
          pointer.keys.toSet(),
          containsAll([
            'templateId',
            'bundleVersion',
            'bundleHash',
            'previousTemplateId',
            'history',
          ]));
      expect(pointer['templateId'], 'gallery');
      expect(pointer['bundleVersion'], '1.0.0');
      expect(pointer['bundleHash'], 'b' * 64);
      expect(pointer['previousTemplateId'], 'classic');
      final history = pointer['history'] as List;
      expect(history.length, 2);
      for (final entry in history) {
        expect((entry as Map).keys.toSet(),
            containsAll(['templateId', 'bundleVersion', 'bundleHash', 'at', 'by']));
      }
      // The rollback target is the second-last entry, with its
      // bundle fields intact — previousTemplateId is display only,
      // never the rollback source.
      final target = rollbackTargetEntry(history)!;
      expect(target['templateId'], 'classic');
      expect(target['bundleHash'], 'c' * 64);
    });

    test('activatedBy / activatedAt are optional keys', () {
      expect(pointerDoc(withActor: true).keys.toSet(),
          containsAll(['activatedBy', 'activatedAt']));
      final bare = pointerDoc(withActor: false);
      expect(bare.keys.toSet(), isNot(contains('activatedBy')));
      expect(bare.keys.toSet(), isNot(contains('activatedAt')));
      // The history helpers do not depend on the actor keys.
      expect(
          rollbackTargetEntry(bare['history'] as List)!['templateId'],
          'classic');
      final grown = appendHistoryEntry(bare['history'] as List, {
        'templateId': 'bazaar',
        'bundleVersion': '1.0.0',
        'bundleHash': 'a' * 64,
        'at': '2026-11-27T02:00:00.000Z',
        'by': 'uid-admin',
      });
      expect(grown.length, 3);
      expect(grown.last['templateId'], 'bazaar');
      expect(grown.last['by'], 'uid-admin');
    });
  });
}
