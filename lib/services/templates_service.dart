// Templates registry service (design doc file 19, Technical Plan v1.4 §7).
//
// Owns the registry reads/writes, the validation gateway, and the
// activation pointer. Templates are declarative JSON data only — no
// template code ever runs on the store origin (Alternative A was
// rejected for exactly that reason), so a template can never read
// customer contact data, alter an order, or send data out.
//
// Registry shape (Firestore):
//   templates/{id}: the registry record — name, version, schemaVersion,
//     status ('draft' | 'active' | 'archived'), thumbnailUrl, bodyPath,
//     grid {columns, rows, minColumnWidthPx}, tokens (CSS values),
//     sections {hero, promos, featured, delivery, contact}, validation
//     report, minAppVersion, createdAt/updatedAt/operationId.
//   storeSettings/activeTemplate: the activation pointer —
//     {templateId, previousTemplateId}. The storefront reads it at
//     boot; the rules only let a pointer reference a template whose
//     status is 'active'.
// Launch ships ONE template — 'classic', the current live site
// preserved as-is. The built-in classic definition below is the
// fallback the storefront and the admin screen use until the
// registry document is seeded (the deploy step); the first
// activation seeds it automatically so rollback always has a
// document to return to.

import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/diagnostics.dart';
import 'backend.dart';

/// The CSS token keys a template may carry (styles.css :root).
const Set<String> templateTokenKeys = {
  'bg',
  'bg2',
  'surface',
  'surfaceStrong',
  'border',
  'text',
  'textSoft',
  'accent',
  'accent2',
  'warm',
  'radius',
};

/// The storefront sections a template may toggle.
const Set<String> templateSectionKeys = {
  'hero',
  'promos',
  'featured',
  'delivery',
  'contact',
};

/// Template statuses. 'active' means validated and eligible to go
/// live; the LIVE template is whichever id the pointer references.
/// A previous template keeps 'active' so one-tap rollback is a
/// single pointer write.
const Set<String> templateStatuses = {'draft', 'active', 'archived'};

/// Result of the validation gateway: a template that fails any check
/// never becomes a card and never goes live.
class TemplateValidationReport {
  const TemplateValidationReport({
    required this.passed,
    required this.failedChecks,
  });

  final bool passed;

  /// Human-readable names of the failed checks (empty when passed).
  final List<String> failedChecks;
}

/// A parsed template record. Unknown or missing fields degrade to the
/// classic defaults, never a crash — a document may predate this
/// editor or come from a newer schema version.
class TemplateRecord {
  const TemplateRecord({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required this.schemaVersion,
    required this.status,
    required this.thumbnailUrl,
    required this.bodyPath,
    required this.gridColumns,
    required this.gridRows,
    required this.minColumnWidthPx,
    required this.tokens,
    required this.sections,
    required this.minAppVersion,
    required this.validationPassed,
    required this.validationFailedChecks,
    required this.fromRegistry,
  });

  final String id;
  final String name;
  final String description;
  final int version;
  final int schemaVersion;
  final String status;
  final String thumbnailUrl;
  final String bodyPath;

  /// Products per row (null = the current auto-fill behaviour).
  final int? gridColumns;

  /// Rows shown before "show more" (null = show all, current behaviour).
  final int? gridRows;
  final int minColumnWidthPx;
  final Map<String, String> tokens;
  final Map<String, bool> sections;
  final int minAppVersion;
  final bool validationPassed;
  final List<String> validationFailedChecks;

  /// False for the built-in launch template (no registry document yet).
  final bool fromRegistry;

  /// "3 × 2" / "تلقائي" — the grid summary shown on the card.
  String get gridSummary {
    final cols = gridColumns == null ? 'تلقائي' : '$gridColumns';
    final rows = gridRows == null ? 'الكل' : '$gridRows صفوف';
    return '$cols × $rows';
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'name': name,
      'description': description,
      'version': version,
      'schemaVersion': schemaVersion,
      'status': status,
      'thumbnailUrl': thumbnailUrl,
      'bodyPath': bodyPath,
      'grid': <String, dynamic>{
        'columns': gridColumns,
        'rows': gridRows,
        'minColumnWidthPx': minColumnWidthPx,
      },
      'tokens': Map<String, dynamic>.from(tokens),
      'sections': Map<String, dynamic>.from(sections),
      'minAppVersion': minAppVersion,
      'validation': <String, dynamic>{
        'passed': validationPassed,
        'checks': validationFailedChecks,
      },
    };
  }
}

/// The launch template: the current live site, preserved as-is.
/// Tokens are styles.css :root verbatim; grid nulls reproduce the
/// current auto-fill behaviour exactly. This definition is the
/// single source of truth — storefront/templates/classic.json carries
/// the same values as the Hosting asset, and the storefront's
/// built-in fallback carries them too.
class Templates {
  Templates._();

  static const Map<String, String> classicTokens = {
    'bg': '#f4f6f8',
    'bg2': '#eaeff3',
    'surface': 'rgba(255, 255, 255, 0.55)',
    'surfaceStrong': 'rgba(255, 255, 255, 0.82)',
    'border': 'rgba(20, 30, 45, 0.08)',
    'text': '#1b2430',
    'textSoft': '#5b6878',
    'accent': '#3f7f8c',
    'accent2': '#8fb8b0',
    'warm': '#c9a57a',
    'radius': '24px',
  };

  static const Map<String, bool> classicSections = {
    'hero': true,
    'promos': true,
    'featured': true,
    'delivery': true,
    'contact': true,
  };

  static const TemplateRecord classic = TemplateRecord(
    id: 'classic',
    name: 'التصميم الحالي',
    description: 'تصميم المتجر الحالي كما هو — القالب الافتراضي عند الإطلاق.',
    version: 1,
    schemaVersion: 1,
    status: 'active',
    thumbnailUrl: '',
    bodyPath: 'templates/classic.json',
    gridColumns: null,
    gridRows: null,
    minColumnWidthPx: 250,
    tokens: classicTokens,
    sections: classicSections,
    minAppVersion: 0,
    validationPassed: true,
    validationFailedChecks: [],
    fromRegistry: false,
  );
}

/// The validation gateway (pure — no Firestore, so it is unit-tested
/// and shared by the admin app and the storefront's own check).
/// A template is a card only when every check passes.
TemplateValidationReport validateTemplateDoc(Map<String, dynamic>? doc) {
  final failed = <String>[];
  final d = doc ?? {};
  final name = d['name'];
  if (name is! String || name.trim().isEmpty) failed.add('name');
  if (d['schemaVersion'] != 1) failed.add('schemaVersion');
  final status = d['status'];
  if (status is! String || !templateStatuses.contains(status)) {
    failed.add('status');
  }
  final version = d['version'];
  if (version is! int || version < 1) failed.add('version');
  final grid = d['grid'];
  if (grid != null) {
    if (grid is! Map) {
      failed.add('grid');
    } else {
      final columns = grid['columns'];
      if (columns != null && (columns is! int || columns < 1 || columns > 12)) {
        failed.add('grid.columns');
      }
      final rows = grid['rows'];
      if (rows != null && (rows is! int || rows < 1 || rows > 20)) {
        failed.add('grid.rows');
      }
      final minW = grid['minColumnWidthPx'];
      if (minW != null && (minW is! int || minW < 120 || minW > 600)) {
        failed.add('grid.minColumnWidthPx');
      }
    }
  }
  final tokens = d['tokens'];
  if (tokens != null) {
    if (tokens is! Map) {
      failed.add('tokens');
    } else {
      for (final entry in tokens.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (!templateTokenKeys.contains(key)) {
          failed.add('tokens.$key');
          continue;
        }
        if (value is! String || !_isSafeCssValue(key, value)) {
          failed.add('tokens.$key');
        }
      }
    }
  }
  final sections = d['sections'];
  if (sections != null) {
    if (sections is! Map) {
      failed.add('sections');
    } else {
      for (final entry in sections.entries) {
        final key = entry.key.toString();
        if (!templateSectionKeys.contains(key)) {
          failed.add('sections.$key');
          continue;
        }
        if (entry.value is! bool) failed.add('sections.$key');
      }
    }
  }
  final bodyPath = d['bodyPath'];
  if (bodyPath != null) {
    if (bodyPath is! String ||
        !bodyPath.startsWith('templates/') ||
        !bodyPath.endsWith('.json')) {
      failed.add('bodyPath');
    }
  }
  final thumbnail = d['thumbnailUrl'];
  if (thumbnail != null &&
      thumbnail is String &&
      thumbnail.isNotEmpty &&
      !thumbnail.startsWith('http')) {
    failed.add('thumbnailUrl');
  }
  return TemplateValidationReport(
    passed: failed.isEmpty,
    failedChecks: failed,
  );
}

/// Grid edit validation (pure — unit-tested): columns is the
/// products per row (1–12), rows is the rows shown before
/// "show more" (1–20). Null on either side keeps the current
/// behaviour — auto-fill columns / show all rows. The ranges match
/// the gateway's grid checks above, so a validated edit can never
/// push a good template through the gateway as invalid. Returns an
/// Arabic error message, or null when the values are valid.
String? validateTemplateGrid({int? columns, int? rows}) {
  if (columns != null && (columns < 1 || columns > 12)) {
    return 'عدد المنتجات في الصف لازم يكون بين 1 و 12';
  }
  if (rows != null && (rows < 1 || rows > 20)) {
    return 'عدد الصفوف لازم يكون بين 1 و 20';
  }
  return null;
}

/// A token value is safe only as a plain color or a pixel radius:
/// hex (#RGB / #RRGGBB / #RRGGBBAA) or rgba() with bounded numbers,
/// or `<n>px` for radius. Anything with url(, expression, quotes,
/// semicolons or javascript: is rejected — a template must never
/// inject code through a token.
bool _isSafeCssValue(String key, String value) {
  final v = value.trim();
  if (v.isEmpty) return false;
  if (v.contains('url(') ||
      v.contains('expression') ||
      v.contains('javascript:') ||
      v.contains(';') ||
      v.contains('"') ||
      v.contains("'") ||
      v.contains('<') ||
      v.contains('>')) {
    return false;
  }
  if (key == 'radius') {
    final m = RegExp(r'^(\d+)px$').firstMatch(v);
    if (m == null) return false;
    final n = int.tryParse(m.group(1)!);
    return n != null && n >= 0 && n <= 64;
  }
  if (RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(v)) {
    return true;
  }
  final rgba = RegExp(r'^rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([0-9.]+)\s*\)$')
      .firstMatch(v);
  if (rgba != null) {
    final r = int.tryParse(rgba.group(1)!);
    final g = int.tryParse(rgba.group(2)!);
    final b = int.tryParse(rgba.group(3)!);
    final a = double.tryParse(rgba.group(4)!);
    return r != null && r <= 255 && g != null && g <= 255 && b != null && b <= 255 &&
        a != null && a >= 0 && a <= 1;
  }
  return false;
}

/// Parses a registry document (or null) into a record. Unknown or
/// missing fields degrade to the classic defaults, never a crash.
TemplateRecord parseTemplateDoc(String id, Map<String, dynamic>? doc) {
  final d = doc ?? {};
  final report = validateTemplateDoc(d);
  final grid = (d['grid'] as Map<String, dynamic>?) ?? {};
  final rawTokens = (d['tokens'] as Map<String, dynamic>?) ?? {};
  final tokens = <String, String>{...Templates.classicTokens};
  for (final entry in rawTokens.entries) {
    final key = entry.key.toString();
    final value = entry.value;
    if (templateTokenKeys.contains(key) &&
        value is String &&
        _isSafeCssValue(key, value)) {
      tokens[key] = value;
    }
  }
  final rawSections = (d['sections'] as Map<String, dynamic>?) ?? {};
  final sections = <String, bool>{...Templates.classicSections};
  for (final entry in rawSections.entries) {
    final key = entry.key.toString();
    if (templateSectionKeys.contains(key) && entry.value is bool) {
      sections[key] = entry.value as bool;
    }
  }
  int asInt(dynamic v, int fallback) => v is int ? v : fallback;
  int? asGridInt(dynamic v, int min, int max) =>
      v is int && v >= min && v <= max ? v : null;
  return TemplateRecord(
    id: id,
    name: (d['name'] as String?)?.trim().isNotEmpty == true
        ? (d['name'] as String).trim()
        : Templates.classic.name,
    description: (d['description'] as String?) ?? '',
    version: asInt(d['version'], 1),
    schemaVersion: asInt(d['schemaVersion'], 1),
    status: (d['status'] as String?) ?? 'draft',
    thumbnailUrl: (d['thumbnailUrl'] as String?) ?? '',
    bodyPath: (d['bodyPath'] as String?) ?? 'templates/$id.json',
    gridColumns: asGridInt(grid['columns'], 1, 12),
    gridRows: asGridInt(grid['rows'], 1, 20),
    minColumnWidthPx: asInt(grid['minColumnWidthPx'], 250) >= 120 &&
            asInt(grid['minColumnWidthPx'], 250) <= 600
        ? asInt(grid['minColumnWidthPx'], 250)
        : 250,
    tokens: tokens,
    sections: sections,
    minAppVersion: asInt(d['minAppVersion'], 0),
    validationPassed: report.passed,
    validationFailedChecks: report.failedChecks,
    fromRegistry: doc != null,
  );
}

class TemplatesService {
  TemplatesService._();
  static final TemplatesService instance = TemplatesService._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  /// The registry, newest first. Rules: list is admin/manager only.
  Stream<QuerySnapshot<Map<String, dynamic>>> templatesStream() => _db
      .collection('templates')
      .orderBy('createdAt', descending: true)
      .snapshots();

  /// The activation pointer (storeSettings/activeTemplate). Public
  /// read — the storefront reads the same document at boot.
  Stream<DocumentSnapshot<Map<String, dynamic>>> activeTemplatePointerStream() =>
      _db.collection('storeSettings').doc('activeTemplate').snapshots();

  Future<Map<String, dynamic>?> _pointerData() async {
    final snap =
        await _db.collection('storeSettings').doc('activeTemplate').get();
    return snap.data();
  }

  /// Resolves the live template: the pointer's template document when
  /// it exists and passes the gateway, otherwise the built-in
  /// classic (the launch site, unchanged).
  Future<TemplateRecord> resolveActiveTemplate() async {
    try {
      final pointer = await _pointerData();
      final templateId = pointer?['templateId'] as String?;
      if (templateId != null && templateId.isNotEmpty) {
        final snap = await _db.collection('templates').doc(templateId).get();
        if (snap.data() != null) {
          final record = parseTemplateDoc(snap.id, snap.data());
          if (record.validationPassed) return record;
          Diagnostics.instance.log(
              'Template $templateId failed validation — falling back to classic');
        }
      }
    } catch (e) {
      Diagnostics.instance.log('resolveActiveTemplate failed: $e');
    }
    return Templates.classic;
  }

  /// Seeds the launch template document when it does not exist yet,
  /// so the first activation always has a document to roll back to.
  /// Idempotent: a no-op when templates/classic already exists.
  Future<void> _ensureClassicTemplateDoc() async {
    final ref = _db.collection('templates').doc('classic');
    final snap = await ref.get();
    if (snap.data() != null) return;
    final doc = Templates.classic.toMap();
    doc['createdAt'] = FieldValue.serverTimestamp();
    await Backend.instance.auditedWrite(
      writes: {'templates/classic': doc},
      sensitive: {
        'templates/classic': {'status': 'active'},
      },
      operation: 'template_create',
      topNewValues: {'templateId': 'classic'},
    );
    Diagnostics.instance.log('Seeded templates/classic');
  }

  /// Activates a template: draft → preview → confirm → apply.
  /// Order matters for the rules: the template must be 'active'
  /// BEFORE the pointer references it, and the previous template
  /// keeps 'active' so one-tap rollback is a single pointer write.
  Future<void> activateTemplate({required String templateId}) async {
    final snap = await _db.collection('templates').doc(templateId).get();
    final data = snap.data();
    if (data == null) {
      throw BackendException('القالب مش موجود');
    }
    final report = validateTemplateDoc(data);
    if (!report.passed) {
      throw BackendException(
          'القالب مش صالح للتفعيل: ${report.failedChecks.join('، ')}');
    }
    await _ensureClassicTemplateDoc();
    final pointer = await _pointerData();
    final currentId = (pointer?['templateId'] as String?) ?? 'classic';
    if (currentId == templateId) {
      throw BackendException('القالب ده مفعّل أصلاً');
    }
    if ((data['status'] as String?) != 'active') {
      await Backend.instance.auditedWrite(
        writes: {
          'templates/$templateId': {'status': 'active'},
        },
        sensitive: {
          'templates/$templateId': {'status': 'active'},
        },
        operation: 'template_activate',
        oldValues: {
          'templates/$templateId': {'status': data['status']},
        },
        topNewValues: {'templateId': templateId, 'status': 'active'},
      );
    }
    await Backend.instance.auditedWrite(
      writes: {
        'storeSettings/activeTemplate': {
          'templateId': templateId,
          'previousTemplateId': currentId,
        },
      },
      sensitive: const {},
      operation: 'template_activate',
      oldValues: {
        'storeSettings/activeTemplate': {'templateId': currentId},
      },
      topNewValues: {'templateId': templateId, 'previousTemplateId': currentId},
    );
    Diagnostics.instance.log('Template activated: $templateId');
  }

  /// One-tap rollback: the pointer returns to the previous template
  /// (still 'active', so the rules accept the write).
  Future<void> rollbackTemplate() async {
    final pointer = await _pointerData();
    final currentId = (pointer?['templateId'] as String?) ?? 'classic';
    final previousId = (pointer?['previousTemplateId'] as String?) ?? '';
    if (previousId.isEmpty) {
      throw BackendException('مفيش قالب سابق للرجوع ليه');
    }
    if (previousId == currentId) {
      throw BackendException('القالب السابق هو نفسه الحالي');
    }
    final snap = await _db.collection('templates').doc(previousId).get();
    final data = snap.data();
    if (data == null) {
      throw BackendException('القالب السابق مش موجود');
    }
    final report = validateTemplateDoc(data);
    if (!report.passed) {
      throw BackendException(
          'القالب السابق مش صالح: ${report.failedChecks.join('، ')}');
    }
    if ((data['status'] as String?) != 'active') {
      await Backend.instance.auditedWrite(
        writes: {
          'templates/$previousId': {'status': 'active'},
        },
        sensitive: {
          'templates/$previousId': {'status': 'active'},
        },
        operation: 'template_rollback',
        oldValues: {
          'templates/$previousId': {'status': data['status']},
        },
        topNewValues: {'templateId': previousId, 'status': 'active'},
      );
    }
    await Backend.instance.auditedWrite(
      writes: {
        'storeSettings/activeTemplate': {
          'templateId': previousId,
          'previousTemplateId': currentId,
        },
      },
      sensitive: const {},
      operation: 'template_rollback',
      oldValues: {
        'storeSettings/activeTemplate': {'templateId': currentId},
      },
      topNewValues: {'templateId': previousId, 'previousTemplateId': currentId},
    );
    Diagnostics.instance.log('Template rolled back to: $previousId');
  }

  /// Archives a template or returns it to draft. Activation goes
  /// only through activateTemplate (which runs the gateway first).
  Future<void> setTemplateStatus({
    required String id,
    required String status,
  }) async {
    if (status != 'draft' && status != 'archived') {
      throw BackendException('الحالة دي بتتغير من التفعيل بس');
    }
    final snap = await _db.collection('templates').doc(id).get();
    final data = snap.data();
    if (data == null) throw BackendException('القالب مش موجود');
    final pointer = await _pointerData();
    if ((pointer?['templateId'] as String?) == id) {
      throw BackendException('مينفعش تغير حالة القالب المفعّل — رجّع قالب تاني الأول');
    }
    await Backend.instance.auditedWrite(
      writes: {
        'templates/$id': {'status': status},
      },
      sensitive: {
        'templates/$id': {'status': status},
      },
      operation: 'template_status',
      oldValues: {
        'templates/$id': {'status': data['status']},
      },
      topNewValues: {'templateId': id, 'status': status},
    );
  }

  /// Edits a template's product grid (columns = products per row,
  /// rows = rows shown before "show more"; null = auto-fill /
  /// show all). Only the grid sub-map is written — the rest of the
  /// document is untouched — and the write goes through the audited
  /// write like every other admin mutation (grid fields are not
  /// sensitive per the rules, so the sensitive map is empty). The
  /// merged document is re-run through the validation gateway, so
  /// an edit can never silently invalidate a live template; the
  /// minColumnWidthPx is preserved from the stored document.
  Future<void> updateTemplateGrid({
    required String id,
    int? columns,
    int? rows,
  }) async {
    final error = validateTemplateGrid(columns: columns, rows: rows);
    if (error != null) throw BackendException(error);
    final snap = await _db.collection('templates').doc(id).get();
    final data = snap.data();
    if (data == null) throw BackendException('القالب مش موجود');
    final existingGrid = (data['grid'] as Map<String, dynamic>?) ?? {};
    final mergedGrid = <String, dynamic>{
      'columns': columns,
      'rows': rows,
      'minColumnWidthPx': existingGrid['minColumnWidthPx'] ?? 250,
    };
    final mergedDoc = <String, dynamic>{...data, 'grid': mergedGrid};
    final report = validateTemplateDoc(mergedDoc);
    if (!report.passed) {
      throw BackendException(
          'الشبكة دي مش صالحة: ${report.failedChecks.join('، ')}');
    }
    await Backend.instance.auditedWrite(
      writes: {
        'templates/$id': {'grid': mergedGrid},
      },
      sensitive: const {},
      operation: 'template_grid',
      oldValues: {
        'templates/$id': {'grid': data['grid']},
      },
      topNewValues: {'templateId': id, 'grid': mergedGrid},
    );
    Diagnostics.instance.log('Template grid updated: $id ($columns × $rows)');
  }
}
