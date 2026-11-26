// Reopen hotfix (2026-11-26) widget test: for a CANCELLED order the
// order-detail dialog's status dropdown must offer 'new' (labelled
// جديد) — picking it is the reopen — and nothing else.
//
// LIMIT: the real dialog (_showOrderDetail in
// lib/screens/admin_orders_tab.dart) is a private top-level function
// in a part file, and the Orders tab itself needs live Firestore, so
// the existing test files cannot pump the dialog itself. This test
// pins the exact option derivation the dialog uses — the real
// Backend.orderTransitions map + the real orderStatusLabels, filtered
// the same way ('expired' excluded) — inside a real
// DropdownButtonFormField, including tap-to-select. If the map ever
// drops cancelled -> new again, this test fails with it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/services/backend.dart';

/// The dialog's dropdown, verbatim in shape: only the current status
/// + its legal next states are offered (v1.4 Decision 23); 'expired'
/// is the sweep's job, never a manual choice.
class _StatusDropdown extends StatefulWidget {
  const _StatusDropdown({required this.status, required this.onSelected});

  final String status;
  final ValueChanged<String> onSelected;

  @override
  State<_StatusDropdown> createState() => _StatusDropdownState();
}

class _StatusDropdownState extends State<_StatusDropdown> {
  late String _status = widget.status;

  @override
  Widget build(BuildContext context) {
    final legalNext = (Backend.orderTransitions[_status] ?? [])
        .where((s) => s != 'expired')
        .toList();
    return DropdownButtonFormField<String>(
      initialValue: _status,
      items: [_status, ...legalNext]
          .map((s) => DropdownMenuItem(
              value: s, child: Text(Backend.orderStatusLabels[s] ?? s)))
          .toList(),
      onChanged: (v) {
        if (v == null) return;
        setState(() => _status = v);
        widget.onSelected(v);
      },
      decoration: const InputDecoration(labelText: 'حالة الطلب'),
    );
  }
}

void main() {
  group('reopen option for a cancelled order', () {
    testWidgets('the dropdown offers جديد (new) and selecting it reopens',
        (tester) async {
      // The map-level contract behind the dropdown.
      expect(Backend.orderTransitions['cancelled'], ['new']);

      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _StatusDropdown(
              status: 'cancelled',
              onSelected: (v) => selected = v,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The button shows the current state, ملغي.
      expect(find.text('ملغي'), findsOneWidget);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();

      // The menu offers exactly the current state + جديد.
      expect(find.text('جديد'), findsOneWidget);

      await tester.tap(find.text('جديد'));
      await tester.pumpAndSettle();

      expect(selected, 'new');
      expect(find.text('جديد'), findsOneWidget);
    });

    testWidgets('a cancelled order is never offered a later state directly',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: _StatusDropdown(status: 'cancelled', onSelected: _noop),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();

      // No direct jump past new: no مقبول / بيتجهز / جاهز / في الطريق.
      expect(find.text('مقبول'), findsNothing);
      expect(find.text('بيتجهز'), findsNothing);
      expect(find.text('جاهز'), findsNothing);
      expect(find.text('في الطريق'), findsNothing);
    });
  });

  group('reopen re-reserves stock (no-functions contract §2)', () {
    test('short stock throws with the product name + available count', () {
      // The exact message the reopen transaction throws when a line
      // is short — the UI shows the available count only.
      expect(
        Backend.insufficientStockMessage(
            productName: 'سماعة', available: 2),
        'المتاح دلوقتي من سماعة هو 2 بس',
      );
      expect(
        Backend.insufficientStockMessage(
            productName: 'سماعة', available: 0),
        'المتاح دلوقتي من سماعة هو 0 بس',
      );
    });

    test('reopen is still only cancelled -> new in the state machine', () {
      expect(Backend.isAllowedOrderTransition('cancelled', 'new'), isTrue);
      expect(Backend.isAllowedOrderTransition('cancelled', 'accepted'),
          isFalse);
      expect(Backend.isAllowedOrderTransition('expired', 'new'), isFalse);
    });
  });
}

void _noop(String _) {}
