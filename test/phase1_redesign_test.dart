// Phase 1 redesign tests: the LONA token contract, the stored-theme
// migration rule, the visibility-driven stagger replay, CountUpText,
// and GrowBar.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/theme/flow_theme.dart';
import 'package:storeadmin/theme/store_design.dart';

void main() {
  test('per-variant token lookup is explicit and distinct', () {
    final gloss = StoreGlassTokens.forVariant(FlowThemeVariant.liquidGloss);
    final calm = StoreGlassTokens.forVariant(FlowThemeVariant.glossMorphism);
    expect(gloss.blurShell, LonaTokens.glassBlur);
    expect(calm.blurShell, 12);
    expect(gloss.showBlobs, isTrue);
    expect(calm.showBlobs, isFalse);
    expect(gloss.accent, LonaTokens.gold);
    expect(calm.accent, LonaTokens.gold);
    expect(gloss.cardTop, isNot(calm.cardTop));
    expect(gloss.buttonGradient.colors, contains(LonaTokens.gold));
  });

  test('stored theme migration maps 1:1 and defaults unknown values', () {
    expect(migrateStoredTheme('liquidGloss'), FlowThemeVariant.liquidGloss);
    expect(
        migrateStoredTheme('glossMorphism'), FlowThemeVariant.glossMorphism);
    expect(migrateStoredTheme('nonsense'), FlowThemeVariant.liquidGloss);
    expect(migrateStoredTheme(null), FlowThemeVariant.liquidGloss);
  });

  testWidgets('stagger replays when an item leaves and re-enters',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: StaggeredScope(
            // Big scrollCacheExtent: without it the sliver unmounts an
            // item scrolled 500px away, and the test would measure
            // the remount path instead of the visibility reset.
            child: ListView(
              scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
              children: [
                for (var i = 0; i < 10; i++)
                  StaggeredItem(
                    index: i,
                    child: SizedBox(height: 200, child: Text('item $i')),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    // Item 0 plays on mount.
    await tester.pumpAndSettle();
    expect(_opacityOf(tester, 'item 0'), 1.0);

    // Scroll item 0 out of view: leaving resets it to transparent.
    // (The item stays mounted — a plain ListView keeps all children —
    // so its Opacity is still readable while off-screen.)
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(_opacityOf(tester, 'item 0'), 0.0);

    // Scroll back: re-entering replays the entrance from zero.
    // If the replay never ran, the item would stay transparent.
    await tester.drag(find.byType(ListView), const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(_opacityOf(tester, 'item 0'), 1.0);
  });

  testWidgets('CountUpText counts up to its target', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: CountUpText(target: 42),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-animation it shows a smaller number, not the target yet.
    expect(find.text('42'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('42'), findsOneWidget);
  });

  testWidgets('GrowBar grows to its fraction', (tester) async {
    // Center loosens the constraints: a bare SizedBox under a
    // tight full-screen parent cannot shrink its child (the
    // parent's tight constraints win), so the bar would measure
    // against the screen width instead of 200.
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Center(
            child: SizedBox(
              width: 200,
              child: GrowBar(fraction: 0.5),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-animation the bar is narrower than its final 100px.
    expect(
      tester.getSize(find.byType(FractionallySizedBox)).width,
      lessThan(100),
    );
    await tester.pump(const Duration(milliseconds: 1200));
    expect(
      tester.getSize(find.byType(FractionallySizedBox)).width,
      closeTo(100, 0.5),
    );
  });
}

double _opacityOf(WidgetTester tester, String text) {
  // skipOffstage: false — an item scrolled out of the viewport is
  // still mounted (cacheExtent keeps it) but the default finder
  // skips off-screen sliver children.
  final opacityWidget = tester.widget<Opacity>(
    find
        .ancestor(
          of: find.text(text, skipOffstage: false),
          matching: find.byType(Opacity, skipOffstage: false),
        )
        .first,
  );
  return opacityWidget.opacity;
}
