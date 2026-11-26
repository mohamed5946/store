// In-app diagnostics log — a standing rule: every app ships with a viewer
// that shows REAL failure reasons, never swallows them.
//
// Phase 1: entries PERSIST across restarts (SharedPreferences, JSON,
// cap 300), the viewer paginates (30 at a time) and can EXPORT the log
// as a redacted text file, and secrets are REDACTED on write AND on
// read — a value that slipped in raw is never shown or exported raw.
// Redaction mirrors LONA's log redaction: API keys, tokens, secrets,
// passwords, bearer tokens, private keys, emails, long hex strings.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key for the persisted log (JSON list, newest
/// first, at most [Diagnostics.maxEntries] entries).
const String diagnosticsPrefsKey = 'diagnostics_log_v1';

/// Redacts secrets from a log line: key=value pairs for known secret
/// keys, bearer tokens, long hex strings, and emails (PII). Applied
/// on write AND on read/export, so a raw value that slipped in before
/// redaction existed is never shown or exported.
String redactSecrets(String line) {
  var out = line;
  // key=value / key: value for known secret keys.
  out = out.replaceAllMapped(
    RegExp(
      r'''(api[_-]?key|access[_-]?token|secret|password|passwd|bearer|client[_-]?secret|private[_-]?key|auth[_-]?token)\s*[=:]\s*[^\s,;]+''',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}=[redacted]',
  );
  // Bearer <token> without the key=value shape.
  out = out.replaceAllMapped(
    RegExp(r'Bearer\s+[A-Za-z0-9._\-~+/=]{8,}', caseSensitive: false),
    (_) => 'Bearer [redacted]',
  );
  // Long hex strings (32+ chars) — tokens, hashes, keys.
  out = out.replaceAllMapped(
    RegExp(r'\b[0-9a-fA-F]{32,}\b'),
    (_) => '[redacted]',
  );
  // Emails — a customer's or admin's address is PII, not a log fact.
  out = out.replaceAllMapped(
    RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
    (_) => '[email]',
  );
  return out;
}

class DiagnosticsEntry {
  DiagnosticsEntry(this.message, {DateTime? at}) : at = at ?? DateTime.now();
  final DateTime at;
  final String message;

  Map<String, dynamic> toJson() => {
        'message': message,
        'at': at.toIso8601String(),
      };

  factory DiagnosticsEntry.fromJson(Map<String, dynamic> json) {
    final raw = (json['message'] ?? '') as String;
    final parsed = DateTime.tryParse((json['at'] ?? '') as String);
    return DiagnosticsEntry(
      redactSecrets(raw),
      at: parsed ?? DateTime.now(),
    );
  }

  @override
  String toString() {
    final h = at.hour.toString().padLeft(2, '0');
    final m = at.minute.toString().padLeft(2, '0');
    return '$h:$m $message';
  }
}

class Diagnostics {
  Diagnostics._();
  static final Diagnostics instance = Diagnostics._();

  static const int maxEntries = 300;

  final ValueNotifier<List<DiagnosticsEntry>> entries =
      ValueNotifier<List<DiagnosticsEntry>>(<DiagnosticsEntry>[]);

  bool _ready = false;

  /// Loads the persisted log. Called once from main() before the app
  /// runs. Entries logged before init (e.g. during Backend.init)
  /// are kept in front of the loaded ones.
  Future<void> init() async {
    if (_ready) return;
    final current = List<DiagnosticsEntry>.from(entries.value);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(diagnosticsPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final loaded = decoded
              .whereType<Map<String, dynamic>>()
              .map(DiagnosticsEntry.fromJson)
              .toList();
          entries.value = [...current, ...loaded].take(maxEntries).toList();
        }
      }
    } catch (_) {
      // A corrupt stored log must never block startup — start with
      // whatever was logged in memory so far.
      entries.value = current;
    }
    _ready = true;
  }

  void log(String message) {
    final next = List<DiagnosticsEntry>.from(entries.value)
      ..insert(0, DiagnosticsEntry(redactSecrets(message)));
    entries.value = next.take(maxEntries).toList();
    unawaited(_persist());
  }

  void clear() {
    entries.value = <DiagnosticsEntry>[];
    unawaited(_persist());
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        diagnosticsPrefsKey,
        jsonEncode(entries.value.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      // Persistence is best-effort: the in-memory log still works.
    }
  }

  /// The whole log as redacted plain text (newest first), for the
  /// in-app Export button. Every line is re-redacted here, so even
  /// an entry stored before redaction existed exports clean.
  String exportText() {
    final buffer = StringBuffer()
      ..writeln('Store Admin — diagnostics log')
      ..writeln('Exported ${DateTime.now().toIso8601String()}')
      ..writeln('Entries: ${entries.value.length}');
    for (final e in entries.value) {
      buffer.writeln(redactSecrets(e.toString()));
    }
    return buffer.toString();
  }
}
