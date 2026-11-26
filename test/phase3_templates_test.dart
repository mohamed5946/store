// Phase 3 template tests: the validation gateway, the launch
// template, and the preview-token mapping (Technical Plan v1.4 §7).
// Pure logic — no Firestore, no emulator.
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
}
