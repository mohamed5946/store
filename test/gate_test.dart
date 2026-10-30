// Gate tests reference the gate const — the literal value is never
// hardcoded here, in a test name, or anywhere else outside the gate file.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/screens/gate_screen.dart';

void main() {
  testWidgets('correct code passes, wrong code rejects', (tester) async {
    var passed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: GateScreen(onPassed: () => passed = true),
        ),
      ),
    );

    // Pinput renders a single hidden EditableText; typing into it fills
    // the boxes (auto-advance, paste, backspace are pinput-native).
    await tester.enterText(find.byType(EditableText), '000000');
    await tester.tap(find.byKey(const Key('invite-submit')));
    await tester.pump();
    expect(passed, isFalse);
    expect(find.text('كود الدعوة مش صحيح'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), kInviteCode);
    await tester.tap(find.byKey(const Key('invite-submit')));
    await tester.pump();
    expect(passed, isTrue);
  });
}
