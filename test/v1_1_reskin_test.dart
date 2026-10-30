// Store Admin v1.1 reskin tests: Flow theme system (Liquid Gloss +
// Gloss Morphism, persisted, instant, login fixed), splash sequence,
// ST launcher icons, DF interaction ports, and the no-blue rule.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:storeadmin/screens/flow_signin_screen.dart';
import 'package:storeadmin/screens/splash_screen.dart';
import 'package:storeadmin/theme/flow_theme.dart';
import 'package:storeadmin/theme/store_design.dart';

void main() {
  test('both Flow themes are dark and share the Flow palette', () {
    for (final v in FlowThemeVariant.values) {
      final theme = flowThemeData(v);
      expect(theme.brightness, Brightness.dark);
      expect(theme.colorScheme.primary, FlowPalette.cyan);
    }
    expect(flowThemeData(FlowThemeVariant.liquidGloss).cardTheme.color,
        isNot(flowThemeData(FlowThemeVariant.glossMorphism).cardTheme.color));
  });

  test('theme switch persists and reloads the saved variant', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await FlowThemeController.load();
    expect(controller.variant, FlowThemeVariant.liquidGloss);
    await controller.setVariant(FlowThemeVariant.glossMorphism);
    final reloaded = await FlowThemeController.load();
    expect(reloaded.variant, FlowThemeVariant.glossMorphism);
  });

  testWidgets('theme switch applies without restart', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = FlowThemeController();
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Text(
            controller.variant.label,
            textDirection: TextDirection.rtl,
          ),
        ),
      ),
    );
    expect(find.text('Liquid Gloss'), findsOneWidget);
    await controller.setVariant(FlowThemeVariant.glossMorphism);
    await tester.pump();
    expect(find.text('Gloss Morphism'), findsOneWidget);
  });

  testWidgets('both themes render on a sample tab', (tester) async {
    for (final v in FlowThemeVariant.values) {
      final controller = FlowThemeController(v);
      await tester.pumpWidget(
        MaterialApp(
          theme: flowThemeData(v),
          home: FlowThemeControllerScope(
            controller: controller,
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: FlowScaffold(
                variant: v,
                body: const FlowCard(child: Text('عينة')),
              ),
            ),
          ),
        ),
      );
      expect(find.text('عينة'), findsOneWidget);
      expect(find.byType(FlowCard), findsOneWidget);
    }
  });

  testWidgets('login screen is unaffected by the theme switch',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    for (final v in FlowThemeVariant.values) {
      final controller = FlowThemeController(v);
      await tester.pumpWidget(
        MaterialApp(
          theme: flowThemeData(v),
          home: FlowThemeControllerScope(
            controller: controller,
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: FlowSignInScreen(onDone: () {}),
            ),
          ),
        ),
      );
      // Peek state (Beat 1) + fallback brand title, either theme.
      expect(find.byKey(const Key('signin-peek')), findsOneWidget);
      expect(find.byKey(const Key('signin-brand-title')), findsOneWidget);
      expect(find.text('Store'), findsOneWidget);
      // No Apple button anywhere.
      expect(find.text('Apple'), findsNothing);
    }
  });

  testWidgets('login peek opens the form rows', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: FlowSignInScreen(onDone: () {}),
        ),
      ),
    );
    expect(find.byKey(const Key('signin-identifier')), findsNothing);
    await tester.tap(find.byKey(const Key('signin-peek')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.byKey(const Key('signin-identifier')), findsOneWidget);
    expect(find.byKey(const Key('signin-password')), findsOneWidget);
    expect(find.byKey(const Key('signin-submit')), findsOneWidget);
    expect(find.byKey(const Key('signin-google')), findsOneWidget);
  });

  test('splash sequence runs draw, then sweep, then name', () {
    expect(stSplashStageFor(0.0), StSplashStage.drawing);
    expect(stSplashStageFor(0.39), StSplashStage.drawing);
    expect(stSplashStageFor(0.40), StSplashStage.sweeping);
    expect(stSplashStageFor(0.79), StSplashStage.sweeping);
    expect(stSplashStageFor(0.80), StSplashStage.name);
    expect(stSplashStageFor(0.99), StSplashStage.name);
    expect(stSplashStageFor(1.0), StSplashStage.exiting);
    expect(StSplashScreen.totalDuration.inMilliseconds, 2500);
  });

  test('ST launcher icon exists at every mipmap density', () {
    for (final d in [
      'mipmap-mdpi',
      'mipmap-hdpi',
      'mipmap-xhdpi',
      'mipmap-xxhdpi',
      'mipmap-xxxhdpi',
    ]) {
      final file = File('android/app/src/main/res/$d/ic_launcher.png');
      expect(file.existsSync(), isTrue, reason: d);
      expect(file.lengthSync(), greaterThan(0), reason: d);
    }
  });

  test('stagger delay math: 80ms steps, capped at index 7', () {
    expect(StaggeredItem.delayFor(0), Duration.zero);
    expect(StaggeredItem.delayFor(3), const Duration(milliseconds: 240));
    expect(StaggeredItem.delayFor(7), const Duration(milliseconds: 560));
    expect(StaggeredItem.delayFor(9), const Duration(milliseconds: 560));
  });

  testWidgets('bin-eats-label still confirms under reduce-motion',
      (tester) async {
    var confirmed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: BinEatingDeleteButton(
              label: 'امسح',
              onConfirmed: () => confirmed++,
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('binIcon')), findsOneWidget);
    await tester.tap(find.byType(BinEatingDeleteButton));
    await tester.pump();
    expect(confirmed, 1);
  });

  test('no Material blue or v1.0 blue seed left in lib', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      if (src.contains('Colors.blue') || src.contains('0xFF0A84FF')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });
}
