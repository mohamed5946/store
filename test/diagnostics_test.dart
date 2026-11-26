// Phase 1 diagnostics tests: redaction on write AND read, persistence
// round-trip, export redaction, and the 300-entry cap.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:storeadmin/core/diagnostics.dart';

void main() {
  test('init loads persisted entries and re-redacts them', () async {
    SharedPreferences.setMockInitialValues({
      diagnosticsPrefsKey: jsonEncode([
        {
          'message': 'api_key=leaked123',
          'at': DateTime.now().toIso8601String(),
        },
        {
          'message': 'plain line',
          'at': DateTime.now().toIso8601String(),
        },
      ]),
    });
    await Diagnostics.instance.init();
    final messages =
        Diagnostics.instance.entries.value.map((e) => e.message).toList();
    expect(messages, contains('api_key=[redacted]'));
    expect(messages, contains('plain line'));
  });

  test('redaction masks keys, tokens, passwords, emails, long hex', () {
    expect(redactSecrets('api_key=abc123'), 'api_key=[redacted]');
    expect(redactSecrets('password=hunter2'), 'password=[redacted]');
    expect(
      redactSecrets('Authorization: Bearer abcdefgh12345678'),
      contains('Bearer [redacted]'),
    );
    expect(redactSecrets('signed in as a@b.com'), 'signed in as [email]');
    expect(redactSecrets('token ${'a' * 40}'), contains('[redacted]'));
    // Ordinary words survive untouched.
    expect(redactSecrets('Firebase initialized (store-3384c)'),
        'Firebase initialized (store-3384c)');
    expect(redactSecrets('Signed out'), 'Signed out');
  });

  test('log redacts on write and caps at 300', () {
    Diagnostics.instance.clear();
    Diagnostics.instance.log('api_key=secret123');
    expect(Diagnostics.instance.entries.value.first.message,
        'api_key=[redacted]');
    for (var i = 0; i < 310; i++) {
      Diagnostics.instance.log('line $i');
    }
    expect(Diagnostics.instance.entries.value.length, 300);
    expect(Diagnostics.instance.entries.value.first.message, 'line 309');
  });

  test('log persists the redacted JSON to SharedPreferences', () async {
    Diagnostics.instance.clear();
    Diagnostics.instance.log('persist me');
    // The persist is fire-and-forget; let the microtasks run.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(diagnosticsPrefsKey);
    expect(raw, isNotNull);
    final decoded = jsonDecode(raw!) as List;
    expect(decoded.length, 1);
    expect((decoded.first as Map)['message'], 'persist me');
  });

  test('exportText is redacted and lists every entry', () {
    Diagnostics.instance.clear();
    Diagnostics.instance.log('api_key=xyz');
    Diagnostics.instance.log('plain');
    final text = Diagnostics.instance.exportText();
    expect(text, contains('api_key=[redacted]'));
    expect(text, contains('plain'));
    expect(text, isNot(contains('xyz')));
    expect(text, contains('Entries: 2'));
  });
}
