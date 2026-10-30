// Store Admin v1.1.3: invite-code gate uses Pinput-style boxes.
// All assertions reference the gate const — its literal value is never
// hardcoded here, in a test name, or anywhere else outside the gate file.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinput/pinput.dart';
import 'package:storeadmin/screens/gate_screen.dart';
import 'package:storeadmin/theme/flow_theme.dart';

Widget _gate({FlowThemeVariant? variant, void Function()? onPassed}) {
  final screen = GateScreen(onPassed: onPassed ?? () {});
  final framed = Directionality(
    textDirection: TextDirection.rtl,
    child: screen,
  );
  if (variant == null) return MaterialApp(home: framed);
  return MaterialApp(
    home: FlowThemeControllerScope(
      controller: FlowThemeController(variant),
      child: framed,
    ),
  );
}

void main() {
  testWidgets('pinput length tracks the gate const, digits obscured',
      (tester) async {
    await tester.pumpWidget(_gate());
    final pinput =
        tester.widget<Pinput>(find.byKey(const Key('invite-code-field')));
    expect(pinput.length, kInviteCode.length);
    expect(pinput.obscureText, isTrue);
    expect(pinput.keyboardType, TextInputType.number);
  });

  testWidgets('boxes render under both Flow themes', (tester) async {
    await tester.pumpWidget(
        _gate(variant: FlowThemeVariant.liquidGloss));
    expect(find.byKey(const Key('invite-code-field')), findsOneWidget);
    await tester.pumpWidget(
        _gate(variant: FlowThemeVariant.glossMorphism));
    await tester.pump();
    expect(find.byKey(const Key('invite-code-field')), findsOneWidget);
  });

  testWidgets('error shows on wrong code and clears on next input',
      (tester) async {
    var passed = false;
    await tester.pumpWidget(_gate(onPassed: () => passed = true));
    await tester.enterText(find.byType(EditableText), '000000');
    await tester.tap(find.byKey(const Key('invite-submit')));
    await tester.pump();
    expect(passed, isFalse);
    expect(find.text('كود الدعوة مش صحيح'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), '1');
    await tester.pump();
    expect(find.text('كود الدعوة مش صحيح'), findsNothing);
  });

  testWidgets('over-length input is truncated to the box count',
      (tester) async {
    await tester.pumpWidget(_gate());
    await tester.enterText(
        find.byType(EditableText), '1234567890');
    await tester.pump();
    final pinput =
        tester.widget<Pinput>(find.byKey(const Key('invite-code-field')));
    expect(pinput.controller?.text.length, kInviteCode.length);
  });

  testWidgets('full code entry fills the boxes and gates correctly',
      (tester) async {
    var passed = false;
    await tester.pumpWidget(_gate(onPassed: () => passed = true));
    await tester.enterText(find.byType(EditableText), kInviteCode);
    await tester.pump();
    final pinput =
        tester.widget<Pinput>(find.byKey(const Key('invite-code-field')));
    expect(pinput.controller?.text, kInviteCode);
    await tester.tap(find.byKey(const Key('invite-submit')));
    await tester.pump();
    expect(passed, isTrue);
  });
}
