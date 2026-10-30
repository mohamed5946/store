// In-app diagnostics log — a standing rule: every app ships with a viewer
// that shows REAL failure reasons, never swallows them.
import 'package:flutter/foundation.dart';

class DiagnosticsEntry {
  DiagnosticsEntry(this.message) : at = DateTime.now();
  final DateTime at;
  final String message;

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

  final ValueNotifier<List<DiagnosticsEntry>> entries =
      ValueNotifier<List<DiagnosticsEntry>>(<DiagnosticsEntry>[]);

  void log(String message) {
    final next = List<DiagnosticsEntry>.from(entries.value)
      ..insert(0, DiagnosticsEntry(message));
    entries.value = next.take(300).toList();
  }

  void clear() => entries.value = <DiagnosticsEntry>[];
}
