// Modifications batch (2026-11-26) tests:
// - A1: the bottom nav pill scrolls horizontally — all 8 tabs are
//   reachable on a narrow phone screen (the products tab was cut off
//   on the owner's Infinix), and the spread look is kept when they fit.
// - A2: the template grid edit validation (pure logic).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/services/templates_service.dart';
import 'package:storeadmin/theme/flow_theme.dart';

const _icons = [
  Icons.analytics_outlined,
  Icons.inventory_2_outlined,
  Icons.category_outlined,
  Icons.receipt_long_outlined,
  Icons.style_outlined,
  Icons.feedback_outlined,
  Icons.group_outlined,
  Icons.settings_outlined,
];

const _labels = [
  'الرئيسية',
  'المنتجات',
  'الأقسام',
  'الطلبات',
  'القوالب',
  'الشكاوى',
  'الفريق',
  'الإعدادات',
];

void main() {
  group('FlowNavPill horizontal scroll (A1)', () {
    testWidgets('all 8 tabs are reachable on a 360px phone screen',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: const SizedBox.shrink(),
              bottomNavigationBar: FlowNavPill(
                selectedIndex: selected,
                onDestinationSelected: (i) => selected = i,
                icons: _icons,
                labels: _labels,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The last tab starts off-screen on a narrow phone: it must
      // become reachable by scrolling, then tappable.
      await tester.scrollUntilVisible(
        find.text('الإعدادات'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('الإعدادات'));
      await tester.pumpAndSettle();
      expect(selected, 7);

      // And the first tab is reachable again by scrolling back.
      await tester.scrollUntilVisible(
        find.text('الرئيسية'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('الرئيسية'));
      await tester.pumpAndSettle();
      expect(selected, 0);
    });

    testWidgets('tabs spread across the full width when they fit',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: SizedBox.shrink(),
              bottomNavigationBar: FlowNavPill(
                selectedIndex: 0,
                onDestinationSelected: _noop,
                icons: _icons,
                labels: _labels,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No scrolling needed on a wide screen: every tab is
      // hit-testable where it stands, and the last tab sits near
      // the far edge (spread, not clustered at one side).
      expect(find.text('الإعدادات').hitTestable(), findsOneWidget);
      expect(find.text('الرئيسية').hitTestable(), findsOneWidget);
      final lastCenter = tester.getCenter(find.text('الإعدادات'));
      final firstCenter = tester.getCenter(find.text('الرئيسية'));
      expect((lastCenter.dx - firstCenter.dx).abs(), greaterThan(600));
    });
  });

  group('validateTemplateGrid (A2)', () {
    test('nulls (auto-fill / show all) are valid', () {
      expect(validateTemplateGrid(), isNull);
      expect(validateTemplateGrid(columns: null, rows: null), isNull);
    });

    test('in-range values are valid', () {
      expect(validateTemplateGrid(columns: 1, rows: 1), isNull);
      expect(validateTemplateGrid(columns: 3, rows: 2), isNull);
      expect(validateTemplateGrid(columns: 12, rows: 20), isNull);
    });

    test('out-of-range values are rejected', () {
      expect(validateTemplateGrid(columns: 0), isNotNull);
      expect(validateTemplateGrid(columns: 13), isNotNull);
      expect(validateTemplateGrid(rows: 0), isNotNull);
      expect(validateTemplateGrid(rows: 21), isNotNull);
    });
  });
}

void _noop(int _) {}
