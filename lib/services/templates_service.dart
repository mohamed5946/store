// Templates registry service (design doc file 19, Technical Plan v1.4 §7).
//
// Owns the registry reads/writes, the validation gateway, and the
// activation pointer. Templates are declarative JSON data only — no
// template code ever runs on the store origin (Alternative A was
// rejected for exactly that reason), so a template can never read
// customer contact data, alter an order, or send data out.
//
// Two models live here side by side until the classic bundle passes
// its screenshot-diff gate (spec entry 7, shell child's work):
//   * v1 — the 11-token registry template (Templates.classic). The
//     built-in classic definition below is the fallback the
//     storefront and the admin screen use until the registry
//     document is seeded; the first activation seeds it
//     automatically so rollback always has a document to return to.
//   * bundles — the full file-bundle model (spec store-templates.md
//     §2): a versioned Hosting directory
//     /templates/{id}/{version}/ (manifest.json + sections/*.html +
//     styles.css + tokens.json, preview.png EXCLUDED from the hash)
//     with a Firestore registry document carrying the manifest copy,
//     status, approval record, and activation history.
// The gateway below interprets the single source of truth,
// storefront/templates/gateway-rules.json — it does NOT invent its
// own check list. A bundle that fails any check never becomes a
// card and never goes live.
//
// Registry shape (Firestore):
//   templates/{id}: manifest copy (id, nameAr, nameEn, version,
//     shellMinVersion, bundleHash), status ('draft' | 'preview' |
//     'approved' | 'active' | 'retired'), approval record
//     (approver + timestamp + shell version + bundle hash),
//     previewImageUrl (Hosting URL of preview.png — outside the
//     hash), plus the v1 fields (tokens/grid/sections) while v1
//     templates still exist.
//   templates/{id}/activations/{operationId}: one document per
//     activation/rollback (templateId + bundleVersion + bundleHash
//     + shellVersion + approver + at + action). Append-only audit
//     data — never a growing list inside the registry document.
//   storeSettings/activeTemplate: the activation pointer —
//     {templateId, bundleVersion, bundleHash, previousTemplateId
//     (display convenience ONLY — never the rollback source),
//     history: ordered stack of {templateId, bundleVersion,
//     bundleHash, at, by, action}}.
//   previews/{slug}: {templateId, version, issuedAt, issuedBy,
//     status: open | revoked} — one document per preview slug.
//     Rules: anonymous get only, never list; admin-only create.
//     NOTE: the rules for previews/{slug} and for the activations
//     subcollection land with the rules child's entry 10 — until
//     then those two writes fail at runtime and are logged (the
//     activation itself still commits; the slug issue surfaces its
//     error to the admin).

import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../core/diagnostics.dart';
import 'backend.dart';

/// The live shell version (spec §2 "Shell versioning" — defined
/// once in storefront/app.js as SHELL_VERSION, mirrored here).
/// A bundle whose shellMinVersion is newer than this fails the
/// gateway and can never be activated.
const String liveShellVersion = '1.0.0';

/// The live storefront origin — the base of every ?preview= link.
const String storefrontBaseUrl = 'https://store-3384c.web.app';

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

/// Canonical bundle status enum (spec entry 10 + gateway-rules.json
/// statusEnum). 'archived' is the legacy v1 spelling of 'retired'
/// and is accepted wherever a retired state is checked — see
/// [isRetiredStatus]. The lifecycle is: draft → preview (gateway
/// pass) → approved (Mohamed, D1 checklist) → active (admin confirm
/// = the pointer write) → approved again when it stops being live.
/// There is NO 'validating' or 'awaiting-approval' state.
const Set<String> bundleStatuses = {
  'draft',
  'preview',
  'approved',
  'active',
  'retired',
};

/// Locked template ids (Phase 4, M40).
const Set<String> bundleTemplateIds = {
  'bazaar',
  'gallery',
  'scroll',
  'speclab',
  'boutique',
  'classic',
};

/// Canonical bundle hash of the classic wrap
/// (storefront/templates/classic/1.0.0/manifest.json, decision 1).
/// The classic seed below carries it so the seeded registry doc is a
/// valid six-field bundle doc; if the frozen classic bundle ever
/// changes, its manifest hash changes and this constant must follow.
const String classicBundleHash =
    '3dd0030c445a80099425b4ad4493210c61e653fff0922001b78c826afd5cb703';

/// Locked display glossary (spec §1 "Per-template identity"):
/// Arabic name, English gloss, one-sentence identity.
const Map<String, List<String>> bundleGlossary = {
  'bazaar': ['بازار', 'Deal Bazaar', 'سوق العروض — الأسعار والخصومات أولاً.'],
  'gallery': ['معرض', 'White Gallery', 'معرض أبيض هادي — الصور الكبيرة أولاً.'],
  'scroll': ['اسكرول', 'Scroll', 'فيد منتجات — منتج واحد يملأ الشاشة.'],
  'speclab': ['قارن', 'Spec Lab', 'مقارنة المواصفات — معلومات كثيفة ودقيقة.'],
  'boutique': ['الدكان', 'Warm Boutique', 'دكان دافي — اختيارات قليلة ومرتبة.'],
  'classic': ['الكلاسيكي', 'Classic', 'تصميم المتجر الحالي كما هو.'],
};

/// True for either spelling of the retired state.
bool isRetiredStatus(String? status) =>
    status == 'retired' || status == 'archived';

/// Result of the validation gateway: a template that fails any check
/// never becomes a card and never goes live. Same readable shape as
/// the JS gateway (entry 3): pass/fail + every failure named.
/// Warnings (e.g. physical left/right positioning, RTL) never fail.
class TemplateValidationReport {
  const TemplateValidationReport({
    required this.passed,
    required this.failedChecks,
    this.warnings = const [],
  });

  final bool passed;

  /// Human-readable names of the failed checks (empty when passed).
  final List<String> failedChecks;

  /// Non-failing warnings (empty when none).
  final List<String> warnings;
}

/// The bundle gateway's report — same shape as
/// [TemplateValidationReport]; a distinct type so callers cannot
/// mistake a v1 token report for a full bundle report.
class BundleValidationReport {
  const BundleValidationReport({
    required this.passed,
    required this.failedChecks,
    this.warnings = const [],
  });

  final bool passed;
  final List<String> failedChecks;
  final List<String> warnings;
}

// ------------------------------------------------------------------
// Gateway allow-lists — copied verbatim from
// storefront/templates/gateway-rules.json (the single source of
// truth). If it is not on an allow-list here, it is rejected.
// ------------------------------------------------------------------

const Set<String> _allowedTags = {
  'section',
  'div',
  'span',
  'h1',
  'h2',
  'h3',
  'p',
  'a',
  'img',
  'button',
  'ul',
  'li',
};

const Set<String> _allowedAttributes = {
  'data-slot',
  'data-action',
  'data-section',
  'href',
  'src',
  'alt',
  'class',
};

const Set<String> _allowedSlots = {
  'product-name',
  'product-price',
  'product-old-price',
  'product-image',
  'product-card',
  'category-name',
  'category-image',
  'featured-spot',
  'promo-banner',
  'delivery-fee',
  'brand-name',
  'brand-logo',
  'brand-tagline',
  'whatsapp-number',
  'cod-message',
  'max-discount-pct',
};

const Set<String> _allowedActions = {
  'add-to-cart',
  'open-cart',
  'open-product',
  'select-category',
  'search',
  'toggle-grid-list',
  'toggle-compare',
  'filter-chip',
};

const Set<String> _allowedBehaviours = {
  'countdown-strip',
  'feed',
  'grid-list-toggle',
  'filter-chips',
  'comparison-strip',
  'hero-crossfade',
};

const Set<String> _sectionFiles = {
  'hero',
  'marquee',
  'categories',
  'featured',
  'offers',
  'products',
  'delivery',
  'contact',
  'about',
};

const Set<String> _requiredSections = {'products', 'delivery', 'contact'};

const Set<String> _allowedDataNeeds = {'oldPrice', 'specs', 'deliveryFee'};

const Set<String> _allowedFontOrigins = {
  'self',
  'https://fonts.googleapis.com',
  'https://fonts.gstatic.com',
};

const Set<String> _allowedImageOrigins = {
  'self',
  'https://res.cloudinary.com',
};

const Set<String> _forbiddenTags = {
  'script',
  'form',
  'meta',
  'link',
  'iframe',
  'object',
  'embed',
  'style',
  'input',
  'select',
  'textarea',
};

const Set<String> _forbiddenSelectors = {
  '#cartDrawer',
  '#modal',
  '#journey',
  '#checkoutBtn',
  '#cartBtn',
  '.toast',
};

/// CSS properties a bundle stylesheet may use
/// (gateway-rules.json allowedCssProperties, verbatim).
const Set<String> _allowedCssProperties = {
  'display',
  'flex',
  'flex-direction',
  'flex-wrap',
  'flex-grow',
  'flex-shrink',
  'gap',
  'align-items',
  'justify-content',
  'grid-template-columns',
  'grid-auto-flow',
  'padding',
  'padding-inline-start',
  'padding-inline-end',
  'padding-top',
  'padding-bottom',
  'margin',
  'margin-inline-start',
  'margin-inline-end',
  'margin-top',
  'margin-bottom',
  'border',
  'border-radius',
  'border-start-start-radius',
  'border-start-end-radius',
  'border-end-start-radius',
  'border-end-end-radius',
  'background',
  'background-color',
  'color',
  'font-family',
  'font-size',
  'font-weight',
  'line-height',
  'letter-spacing',
  'text-align',
  'text-decoration',
  'opacity',
  'transform',
  'transition',
  'animation',
  'overflow',
  'overflow-x',
  'overflow-y',
  'position',
  'inset-inline-start',
  'inset-inline-end',
  'top',
  'bottom',
  'width',
  'height',
  'min-height',
  'max-width',
  'max-height',
  'box-shadow',
  'cursor',
  'white-space',
  'text-overflow',
  'object-fit',
  'aspect-ratio',
  'z-index',
  'direction',
  'scroll-snap-type',
  'scroll-snap-align',
  'scroll-behavior',
};

/// The 12 keys tokens.json must carry in each of light/dark
/// (build contract — tokens.json shape).
const Set<String> _tokenJsonKeys = {
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
  'font',
};

/// Motion budget (gateway-rules.json): transform/opacity only,
/// max 1500ms.
const int _maxMotionDurationMs = 1500;

/// Compares two semver strings ('1.0.0'). Returns <0, 0, >0.
/// Non-semver input sorts below any valid version.
int compareSemver(String a, String b) {
  List<int> parts(String v) {
    final pieces = v.trim().split('.');
    if (pieces.length != 3) return [-1];
    final nums = pieces.map(int.tryParse).toList();
    if (nums.any((n) => n == null)) return [-1];
    return nums.cast<int>();
  }

  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
  }
  return 0;
}

bool _isSemver(String? v) {
  if (v == null) return false;
  final pieces = v.trim().split('.');
  return pieces.length == 3 &&
      pieces.every((p) => int.tryParse(p) != null && int.parse(p) >= 0);
}

/// Canonical JSON: object keys sorted recursively, so the same
/// manifest always hashes the same way on every runtime. The JS
/// gateway must use the same canonicalization — the shared fixtures
/// (entry 22) pin it; a mismatch shows up as a hash failure, never
/// as a silent pass.
String canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    final parts = <String>[];
    for (final k in keys) {
      parts.add('${jsonEncode(k)}:${canonicalJson(value[k])}');
    }
    return '{${parts.join(',')}}';
  }
  if (value is List) {
    return '[${value.map(canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

/// The canonical file set a bundle hash covers (gateway-rules.json
/// bundleHash): manifest.json EXCLUDING its own bundleHash field,
/// every file in sections/, styles.css, tokens.json — lexicographic
/// path order, bytes concatenated. preview.png is NEVER in the set.
Map<String, List<int>> canonicalBundleFiles({
  required Map<String, dynamic> manifest,
  required Map<String, String> sections,
  required String stylesCss,
  required Map<String, dynamic> tokens,
}) {
  final files = <String, List<int>>{};
  final manifestMinusHash = Map<String, dynamic>.from(manifest)
    ..remove('bundleHash');
  files['manifest.json'] =
      utf8.encode(canonicalJson(manifestMinusHash));
  final sectionNames = sections.keys.toList()..sort();
  for (final name in sectionNames) {
    files['sections/$name'] = utf8.encode(sections[name]!);
  }
  files['styles.css'] = utf8.encode(stylesCss);
  files['tokens.json'] = utf8.encode(canonicalJson(tokens));
  return files;
}

/// The classic wrap's canonical file set (entry 7 — the live files
/// verbatim: index.html + classic.json, not authored section
/// templates). Same hash rule: manifest.json excluding bundleHash +
/// the wrap's files, lexicographic path order. The shell's own
/// stylesheet is trusted shell code, and the brand renders from the
/// shell topbar — so the wrap is validated by byte-identity + hash,
/// not by the section-file / JS-scan / CSS-budget checks (mirrors
/// the JS gateway's isClassicWrap carve-out).
Map<String, List<int>> canonicalClassicWrapFiles({
  required Map<String, dynamic> manifest,
  required String indexHtml,
  required String classicJson,
  required String stylesCss,
  required Map<String, dynamic> tokens,
}) {
  final files = <String, List<int>>{};
  final manifestMinusHash = Map<String, dynamic>.from(manifest)
    ..remove('bundleHash');
  files['manifest.json'] =
      utf8.encode(canonicalJson(manifestMinusHash));
  files['index.html'] = utf8.encode(indexHtml);
  files['classic.json'] = utf8.encode(classicJson);
  files['styles.css'] = utf8.encode(stylesCss);
  files['tokens.json'] = utf8.encode(canonicalJson(tokens));
  return files;
}

/// SHA-256 hex over the canonical file set, paths in lexicographic
/// order, bytes concatenated.
String computeBundleHash(Map<String, List<int>> files) {
  final paths = files.keys.toList()..sort();
  final bytes = <int>[];
  for (final p in paths) {
    bytes.addAll(files[p]!);
  }
  return sha256.convert(bytes).toString();
}

/// Validates a bundle manifest (the registry manifest copy). Pure —
/// no Firestore, so it is unit-tested and shared with the parity
/// fixtures. [registryId] must match the manifest id when given.
BundleValidationReport validateBundleManifest(
  Map<String, dynamic> manifest, {
  String? registryId,
}) {
  final failed = <String>[];
  final warnings = <String>[];
  final id = manifest['id'];
  if (id is! String || !bundleTemplateIds.contains(id)) {
    failed.add('manifest.id');
  } else if (registryId != null && id != registryId) {
    failed.add('manifest.id.mismatch');
  }
  final nameAr = manifest['nameAr'];
  if (nameAr is! String || nameAr.trim().isEmpty) {
    failed.add('manifest.nameAr');
  }
  final nameEn = manifest['nameEn'];
  if (nameEn is! String || nameEn.trim().isEmpty) {
    failed.add('manifest.nameEn');
  }
  final version = manifest['version'];
  if (version is! String || !_isSemver(version)) {
    failed.add('manifest.version');
  }
  final shellMin = manifest['shellMinVersion'];
  if (shellMin is! String || !_isSemver(shellMin)) {
    failed.add('manifest.shellMinVersion');
  } else if (compareSemver(shellMin, liveShellVersion) > 0) {
    failed.add('manifest.shellMinVersion.newerThanShell');
  }
  final hash = manifest['bundleHash'];
  if (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
    failed.add('manifest.bundleHash');
  }
  final motion = manifest['motion'];
  if (motion is! String || (motion != 'calm' && motion != 'lively')) {
    failed.add('manifest.motion');
  }
  final dark = manifest['dark'];
  if (dark is! String || (dark != 'variant' && dark != 'light-only')) {
    failed.add('manifest.dark');
  }
  final behaviours = manifest['behaviours'];
  if (behaviours != null) {
    if (behaviours is! List) {
      failed.add('manifest.behaviours');
    } else {
      for (final b in behaviours) {
        if (b is! String || !_allowedBehaviours.contains(b)) {
          failed.add('manifest.behaviours.$b');
        }
      }
    }
  }
  final sections = manifest['sections'];
  if (sections is! List || sections.isEmpty) {
    failed.add('manifest.sections');
  } else {
    final listed = <String>{};
    for (final s in sections) {
      if (s is! String || !_sectionFiles.contains(s)) {
        failed.add('manifest.sections.$s');
      } else {
        listed.add(s);
      }
    }
    for (final required in _requiredSections) {
      if (!listed.contains(required)) {
        failed.add('manifest.sections.missing.$required');
      }
    }
  }
  final dataNeeds = manifest['dataNeeds'];
  if (dataNeeds != null) {
    if (dataNeeds is! List) {
      failed.add('manifest.dataNeeds');
    } else {
      for (final d in dataNeeds) {
        if (d is! String || !_allowedDataNeeds.contains(d)) {
          failed.add('manifest.dataNeeds.$d');
        }
      }
    }
  }
  final cartLayout = manifest['cartLayout'];
  if (cartLayout != null &&
      cartLayout is! String ||
      (cartLayout is String &&
          cartLayout != 'drawer' &&
          cartLayout != 'bottom-sheet')) {
    failed.add('manifest.cartLayout');
  }
  final modalLayout = manifest['modalLayout'];
  if (modalLayout != null &&
      modalLayout is! String ||
      (modalLayout is String &&
          modalLayout != 'default' &&
          modalLayout != 'sheet')) {
    failed.add('manifest.modalLayout');
  }
  final fonts = manifest['fonts'];
  if (fonts != null) {
    if (fonts is! List) {
      failed.add('manifest.fonts');
    } else {
      for (final f in fonts) {
        if (f is! Map) {
          failed.add('manifest.fonts.entry');
          continue;
        }
        final origin = f['origin'];
        if (origin is! String || !_allowedFontOrigins.contains(origin)) {
          failed.add('manifest.fonts.origin');
        }
        final family = f['family'];
        if (family is! String || family.trim().isEmpty) {
          failed.add('manifest.fonts.family');
        }
      }
    }
  }
  return BundleValidationReport(
    passed: failed.isEmpty,
    failedChecks: failed,
    warnings: warnings,
  );
}

/// Validates a whole bundle: manifest + section files + styles.css +
/// tokens.json (+ the hash when [expectedBundleHash] is given).
/// Pure — the admin "validate" action and the parity fixtures run
/// this. [sections] maps file names ('hero.html') to contents.
///
/// Classic wrap: pass [indexHtml] + [classicJson] together and the
/// section-file / JS-scan / motion checks are skipped (the wrap is
/// the trusted live files verbatim — validated by byte-identity +
/// hash, with the brand satisfied by construction from the shell
/// topbar). This mirrors the JS gateway's isClassicWrap carve-out.
BundleValidationReport validateBundleFiles({
  required Map<String, dynamic> manifest,
  Map<String, String> sections = const {},
  String? stylesCss,
  Map<String, dynamic>? tokens,
  String? expectedBundleHash,
  String? registryId,
  String? indexHtml,
  String? classicJson,
}) {
  final failed = <String>[];
  final warnings = <String>[];
  final manifestReport =
      validateBundleManifest(manifest, registryId: registryId);
  failed.addAll(manifestReport.failedChecks);
  final isWrap = indexHtml != null && classicJson != null;

  // Required section files + brand slot (skipped for the classic
  // wrap — see above).
  if (!isWrap) {
    for (final required in _requiredSections) {
      if (!sections.containsKey('$required.html')) {
        failed.add('sections.missing.$required');
      }
    }
    final listedSections = manifest['sections'];
    if (listedSections is List) {
      for (final s in listedSections) {
        if (s is String && !sections.containsKey('$s.html')) {
          failed.add('sections.missingFile.$s');
        }
      }
    }
    var hasBrandSlot = false;
    for (final entry in sections.entries) {
      final name = entry.key.replaceAll('.html', '');
      if (!_sectionFiles.contains(name)) {
        failed.add('sections.unknown.$name');
        continue;
      }
      if (entry.value.contains('data-section="brand"') ||
          entry.value.contains("data-section='brand'")) {
        hasBrandSlot = true;
      }
      failed.addAll(_scanSectionHtml(entry.key, entry.value));
    }
    if (!hasBrandSlot) failed.add('brandSlot');
  }

  // tokens.json is REQUIRED — a bundle without it fails, so no
  // template can ship a checkout that silently leaks classic teal.
  if (tokens == null) {
    failed.add('tokens.json.missing');
  } else {
    final light = tokens['light'];
    if (light is! Map) {
      failed.add('tokens.light');
    } else {
      for (final key in _tokenJsonKeys) {
        if (light[key] is! String || (light[key] as String).isEmpty) {
          failed.add('tokens.light.$key');
        }
      }
    }
    final dark = manifest['dark'];
    if (dark == 'variant') {
      final darkTokens = tokens['dark'];
      if (darkTokens is! Map) {
        failed.add('tokens.dark');
      } else {
        for (final key in _tokenJsonKeys) {
          if (darkTokens[key] is! String ||
              (darkTokens[key] as String).isEmpty) {
            failed.add('tokens.dark.$key');
          }
        }
      }
    }
  }

  // CSS: scoping, url/import origins, motion budget, RTL warning.
  // Skipped for the classic wrap — its styles.css is the trusted
  // shell stylesheet (it uses backdrop-filter etc. by design).
  if (stylesCss == null) {
    failed.add('styles.css.missing');
  } else if (!isWrap) {
    final css = stylesCss.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
    if (css.contains('productsGrid')) {
      failed.add('css.writesProductsGrid');
    }
    for (final selector in _forbiddenSelectors) {
      if (css.contains(selector)) {
        failed.add('css.forbiddenSelector');
        break;
      }
    }
    failed.addAll(_scanCssDisplayNone(css));
    failed.addAll(_scanCssUrls(css));
    failed.addAll(_scanCssProperties(css));
    final motion = _scanCssMotion(css);
    failed.addAll(motion.$1);
    warnings.addAll(motion.$2);
  }

  // Bundle hash — SHA-256 over the canonical file set (the wrap's
  // own file set for the classic wrap).
  if (expectedBundleHash != null) {
    if (tokens == null || stylesCss == null) {
      failed.add('bundleHash.unverifiable');
    } else {
      final files = isWrap
          ? canonicalClassicWrapFiles(
              manifest: manifest,
              indexHtml: indexHtml,
              classicJson: classicJson,
              stylesCss: stylesCss,
              tokens: tokens,
            )
          : canonicalBundleFiles(
              manifest: manifest,
              sections: sections,
              stylesCss: stylesCss,
              tokens: tokens,
            );
      if (computeBundleHash(files) != expectedBundleHash.toLowerCase()) {
        failed.add('bundleHash.mismatch');
      }
    }
  }

  return BundleValidationReport(
    passed: failed.isEmpty,
    failedChecks: failed.toSet().toList(),
    warnings: warnings.toSet().toList(),
  );
}

/// No-JavaScript allow-list scan of one section file (gateway
/// check 3): only the named tags/attributes, only the B1 slots and
/// actions, no on* handlers, no javascript: URLs, no forbidden tags.
List<String> _scanSectionHtml(String fileName, String html) {
  final failed = <String>{};
  if (html.contains('javascript:')) failed.add('noJs.javascriptUrl');
  // A bundle must never write into the shell-owned #productsGrid by
  // id (B1 slot-contract fixture). The id attribute is already
  // rejected by the allow-list below; this names the violation.
  if (html.contains('productsGrid')) {
    failed.add('noJs.writesProductsGrid');
  }
  final tagRe = RegExp(r'<\s*/?\s*([A-Za-z][A-Za-z0-9]*)');
  for (final m in tagRe.allMatches(html)) {
    final tag = m.group(1)!.toLowerCase();
    if (_forbiddenTags.contains(tag)) {
      failed.add('noJs.$tag');
    } else if (!_allowedTags.contains(tag)) {
      failed.add('tags.$tag');
    }
  }
  // Attribute names inside each tag.
  final tagBlockRe = RegExp(r'<[^>]+>');
  final attrRe = RegExp(r'([A-Za-z][A-Za-z0-9-]*)\s*=');
  for (final block in tagBlockRe.allMatches(html)) {
    final text = block.group(0)!;
    for (final m in attrRe.allMatches(text)) {
      final attr = m.group(1)!.toLowerCase();
      if (attr.startsWith('on')) {
        failed.add('noJs.eventHandler');
      } else if (!_allowedAttributes.contains(attr)) {
        failed.add('attributes.$attr');
      }
    }
  }
  final slotRe = RegExp(r'''data-slot=["']([^"']+)["']''');
  for (final m in slotRe.allMatches(html)) {
    if (!_allowedSlots.contains(m.group(1))) {
      failed.add('slots.${m.group(1)}');
    }
  }
  final actionRe = RegExp(r'''data-action=["']([^"']+)["']''');
  for (final m in actionRe.allMatches(html)) {
    if (!_allowedActions.contains(m.group(1))) {
      failed.add('actions.${m.group(1)}');
    }
  }
  final srcRe = RegExp(r'''src=["']([^"']+)["']''');
  for (final m in srcRe.allMatches(html)) {
    final src = m.group(1)!;
    if (src.startsWith('http') &&
        !_allowedImageOrigins.any(
            (o) => o != 'self' && src.startsWith(o))) {
      failed.add('src.origin');
    }
  }
  // href: http(s) links to the store's own pages only, plus the
  // allow-listed link origins (gateway-rules.json linkOrigins —
  // https://wa.me/ is the store's own WhatsApp contact channel;
  // bundles keep their hardcoded wa.me hrefs, decision 3).
  final hrefRe = RegExp(r'''href=["']([^"']+)["']''');
  for (final m in hrefRe.allMatches(html)) {
    final href = m.group(1)!;
    if (href.startsWith('http') &&
        !href.startsWith(storefrontBaseUrl) &&
        !href.startsWith('https://wa.me/')) {
      failed.add('href.external');
    }
  }
  return failed.toList();
}

/// CSS scoping (gateway check 9): no rule may hide a price, a
/// button, or an input with display:none INSIDE a transactional
/// surface (cart drawer, modal, journey, checkout/cart buttons,
/// toasts). A browsing-surface rule like `.sl-old-price:empty
/// { display: none; }` — hiding an absent old-price block — is
/// legitimate and must NOT fail: the rule is the surface, not the
/// word "price".
///
/// The comparison is case-insensitive on BOTH sides: the forbidden
/// selectors carry mixed case (#checkoutBtn, #cartBtn) and a
/// stylesheet may write them in any case — a case-sensitive
/// comparison lets `#CheckoutBtn { display: none; }` through.
List<String> _scanCssDisplayNone(String css) {
  final failed = <String>{};
  final ruleRe = RegExp(r'([^{}]+)\{([^{}]*)\}');
  for (final m in ruleRe.allMatches(css)) {
    final selector = m.group(1)!;
    final body = m.group(2)!;
    if (RegExp(r'display\s*:\s*none').hasMatch(body)) {
      if (_forbiddenSelectors.any(
          (f) => selector.toLowerCase().contains(f.toLowerCase()))) {
        failed.add('css.hiddenTransactional');
      }
    }
  }
  return failed.toList();
}

/// CSS url() / @import: only declared font/image origins.
List<String> _scanCssUrls(String css) {
  final failed = <String>{};
  final urlRe = RegExp(r'''url\(\s*["']?([^)"']+)["']?\s*\)''');
  for (final m in urlRe.allMatches(css)) {
    final url = m.group(1)!;
    if (url.startsWith('http') &&
        !_allowedFontOrigins.any((o) => o != 'self' && url.startsWith(o)) &&
        !_allowedImageOrigins.any(
            (o) => o != 'self' && url.startsWith(o))) {
      failed.add('css.url');
    }
  }
  final importRe = RegExp(r'''@import\s+(?:url\(\s*["']?([^)"']+)["']?\s*\)|["']([^"']+)["'])''');
  for (final m in importRe.allMatches(css)) {
    final url = m.group(1) ?? m.group(2) ?? '';
    if (url.startsWith('http') &&
        !_allowedFontOrigins.any((o) => o != 'self' && url.startsWith(o))) {
      failed.add('css.import');
    }
  }
  return failed.toList();
}

/// CSS property allow-list (gateway-rules.json): only the named
/// properties, except custom properties (--*) which are tokens.
/// Mirrors the JS gateway's property scan.
List<String> _scanCssProperties(String css) {
  final failed = <String>{};
  final propRe = RegExp(r'(?:^|[;{])\s*([a-z-]+)\s*:');
  for (final m in propRe.allMatches(css)) {
    final prop = m.group(1)!.toLowerCase();
    if (prop.startsWith('--')) continue;
    // `left` / `right` are owned by gateway check 8 (RTL): the spec
    // says physical left/right is a WARNING only, never a failure.
    // The rules file's allowedCssProperties omits them, which would
    // make the warning unreachable (every `left:` would fail here
    // first) — flagged to the coordinator; the JS gateway currently
    // fails them via the allow-list, so the two gateways diverge on
    // a stylesheet that uses `left:`/`right:` until the rules file
    // is fixed.
    if (prop == 'left' || prop == 'right') continue;
    if (!_allowedCssProperties.contains(prop)) {
      failed.add('css.property.$prop');
    }
  }
  return failed.toList();
}

/// CSS motion budget (gateway check 4): transform/opacity only,
/// max 1500ms; blur / backdrop-filter fail outright. Returns
/// (failures, warnings) — physical left/right positioning is a
/// warning (RTL, gateway check 8), never a failure.
///
/// Duration cap exemption (mirrors the JS gateway): the 1500ms cap
/// governs one-shot motion (transitions, entrance animations).
/// Infinite ambient loops — the marquee band and the slow-zoom hero,
/// both named pure-CSS effects — are exempt by construction: a
/// marquee cannot scroll in 1.5s, and a slow zoom is slow by
/// definition. (The rules file states the cap without the exemption
/// — flagged to the coordinator by the shell child.)
(List<String>, List<String>) _scanCssMotion(String css) {
  final failed = <String>{};
  final warnings = <String>{};
  if (css.contains('backdrop-filter') ||
      RegExp(r'filter\s*:[^;]*blur\s*\(').hasMatch(css)) {
    failed.add('motion.blur');
  }
  // Durations in transition/animation declarations — except inside
  // infinite animation declarations (ambient loops, see above).
  final declRe = RegExp(r'(?:transition|animation)\s*:[^;]+');
  final durRe = RegExp(r'(\d+(?:\.\d+)?)\s*(ms|s)\b');
  const animatableProps = {
    'width',
    'height',
    'left',
    'right',
    'top',
    'bottom',
    'margin',
    'margin-inline-start',
    'margin-inline-end',
    'padding',
    'color',
    'background',
    'background-color',
    'filter',
    'visibility',
    'border',
    'border-radius',
    'box-shadow',
    'font-size',
    'opacity',
    'transform',
  };
  for (final m in declRe.allMatches(css)) {
    final decl = m.group(0)!;
    // Infinite ambient loops (marquee, slow-zoom) are exempt from
    // the duration cap — see the doc comment above.
    final isAmbientLoop =
        decl.startsWith('animation') && decl.contains('infinite');
    if (!isAmbientLoop) {
      for (final d in durRe.allMatches(decl)) {
        final value = double.tryParse(d.group(1)!) ?? 0;
        final ms = d.group(2) == 's' ? value * 1000 : value;
        if (ms > _maxMotionDurationMs) failed.add('motion.maxDuration');
      }
    }
    if (decl.startsWith('transition')) {
      final parts = decl
          .substring('transition:'.length)
          .split(',')
          .map((p) => p.trim().split(RegExp(r'\s+')).first.toLowerCase());
      for (final prop in parts) {
        if (prop == 'all') {
          failed.add('motion.property');
        } else if (animatableProps.contains(prop) &&
            prop != 'transform' &&
            prop != 'opacity') {
          failed.add('motion.property');
        }
      }
    }
  }
  // transition-property lists.
  final propRe = RegExp(r'transition-property\s*:[^;]+');
  for (final m in propRe.allMatches(css)) {
    final props = m
        .group(0)!
        .split(':')[1]
        .split(',')
        .map((p) => p.trim().toLowerCase());
    for (final prop in props) {
      if (prop != 'transform' && prop != 'opacity' && prop != 'none') {
        failed.add('motion.property');
      }
    }
  }
  // @keyframes bodies: only transform/opacity declarations.
  var searchFrom = 0;
  while (true) {
    final idx = css.indexOf('@keyframes', searchFrom);
    if (idx < 0) break;
    final open = css.indexOf('{', idx);
    if (open < 0) break;
    var depth = 0;
    var close = -1;
    for (var i = open; i < css.length; i++) {
      if (css[i] == '{') depth++;
      if (css[i] == '}') {
        depth--;
        if (depth == 0) {
          close = i;
          break;
        }
      }
    }
    if (close < 0) break;
    final body = css.substring(open + 1, close);
    final declPropRe = RegExp(r'([a-z-]+)\s*:');
    for (final d in declPropRe.allMatches(body)) {
      final prop = d.group(1)!;
      if (prop != 'transform' && prop != 'opacity') {
        failed.add('motion.keyframes');
      }
    }
    searchFrom = close + 1;
  }
  // RTL warning: physical left/right positioning.
  if (RegExp(r'(?:^|[;{\s])(left|right)\s*:').hasMatch(css)) {
    warnings.add('rtl.physicalPosition');
  }
  return (failed.toList(), warnings.toList());
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
    this.nameAr = '',
    this.nameEn = '',
    this.bundleVersion = '',
    this.bundleHash = '',
    this.shellMinVersion = '',
    this.previewImageUrl = '',
    this.approvalApprover = '',
    this.approvalShellVersion = '',
    this.approvalBundleHash = '',
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

  // --- Bundle-model fields (empty for v1 templates) ---
  final String nameAr;
  final String nameEn;

  /// Bundle version string ('1.0.0') — empty for v1 templates.
  final String bundleVersion;

  /// SHA-256 hex over the canonical file set — empty for v1.
  final String bundleHash;
  final String shellMinVersion;

  /// Hosting URL of preview.png — outside the hash, so a re-capture
  /// after approval does NOT void the approval.
  final String previewImageUrl;

  /// Approval record (frozen at approval time): who approved, and
  /// the shell version + bundle hash it was approved against. A
  /// changed hash requires re-approval.
  final String approvalApprover;
  final String approvalShellVersion;
  final String approvalBundleHash;

  /// True when this record carries a bundle (registry manifest copy).
  bool get isBundle => bundleHash.isNotEmpty;

  /// The approval still binds this exact bundle + shell.
  bool get approvalStillValid =>
      approvalBundleHash.isNotEmpty &&
      approvalBundleHash == bundleHash &&
      approvalShellVersion.isNotEmpty;

  /// Arabic name + English gloss + one-sentence identity from the
  /// locked glossary, falling back to the stored fields.
  String get displayNameAr =>
      nameAr.isNotEmpty ? nameAr : (bundleGlossary[id]?[0] ?? name);
  String get displayNameEn =>
      nameEn.isNotEmpty ? nameEn : (bundleGlossary[id]?[1] ?? '');
  String get identityLine => bundleGlossary[id]?[2] ?? description;

  /// Short hash for cards (first 12 hex chars).
  String get shortHash =>
      bundleHash.length >= 12 ? bundleHash.substring(0, 12) : bundleHash;

  /// "3 × 2" / "تلقائي" — the grid summary shown on the card.
  String get gridSummary {
    final cols = gridColumns == null ? 'تلقائي' : '$gridColumns';
    final rows = gridRows == null ? 'الكل' : '$gridRows صفوف';
    return '$cols × $rows';
  }

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
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
    // Bundle fields ride along only for bundle records — the v1
    // classic map stays exactly as the existing tests expect.
    if (isBundle) {
      map['nameAr'] = nameAr;
      map['nameEn'] = nameEn;
      map['bundleVersion'] = bundleVersion;
      map['bundleHash'] = bundleHash;
      map['shellMinVersion'] = shellMinVersion;
      map['previewImageUrl'] = previewImageUrl;
    }
    return map;
  }
}

/// The launch template: the current live site, preserved as-is.
/// Tokens are styles.css :root verbatim; grid nulls reproduce the
/// current auto-fill behaviour exactly. This definition is the
/// single source of truth — storefront/templates/classic.json carries
/// the same values as the Hosting asset, and the storefront's
/// built-in fallback carries them too.
///
/// KEPT until the classic bundle (entry 7, shell child's work)
/// passes its screenshot-diff gate — until then it is the fallback
/// chain. Delete ONLY after that gate passes (see M3 fix).
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
/// v1 token/schema checks, kept for v1 registry documents. When a
/// document also carries bundle fields (bundleHash), the bundle
/// checks run on top: a bundle manifest with a bad hash, a shell
/// newer than live, or a non-canonical status fails here too.
TemplateValidationReport validateTemplateDoc(Map<String, dynamic>? doc) {
  final failed = <String>[];
  final d = doc ?? {};
  // Bundle registry doc (spec §2, entry 19): the six-field manifest
  // copy — string `version`, no v1 `name`/`schemaVersion`. It
  // validates against the bundle rules ONLY: the v1 checks (name,
  // schemaVersion, int version, v1 status set) do not apply to it,
  // and the full-manifest validator must NOT run here either — the
  // registry copy carries no motion/dark/sections (see the
  // contradiction group in test/phase3_templates_test.dart). A
  // hybrid doc (v1 fields + bundle fields, int version) keeps the
  // v1 path below with the bundle addendum on top.
  final isBundleDoc = (d.containsKey('bundleHash') ||
          d.containsKey('shellMinVersion')) &&
      d['version'] is String;
  if (isBundleDoc) {
    final status = d['status'];
    if (status is! String ||
        (!bundleStatuses.contains(status) && status != 'archived')) {
      failed.add('status');
    }
    final id = d['id'];
    if (id is! String || !bundleTemplateIds.contains(id)) {
      failed.add('manifest.id');
    }
    final nameAr = d['nameAr'];
    if (nameAr is! String || nameAr.trim().isEmpty) {
      failed.add('manifest.nameAr');
    }
    final nameEn = d['nameEn'];
    if (nameEn is! String || nameEn.trim().isEmpty) {
      failed.add('manifest.nameEn');
    }
    final version = d['version'];
    if (version is! String || !_isSemver(version)) {
      failed.add('manifest.version');
    }
    final shellMin = d['shellMinVersion'];
    if (shellMin is! String || !_isSemver(shellMin)) {
      failed.add('manifest.shellMinVersion');
    } else if (compareSemver(shellMin, liveShellVersion) > 0) {
      failed.add('manifest.shellMinVersion.newerThanShell');
    }
    final bundleHash = d['bundleHash'];
    if (bundleHash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(bundleHash)) {
      failed.add('manifest.bundleHash');
    }
    final previewImageUrl = d['previewImageUrl'];
    if (previewImageUrl != null &&
        previewImageUrl is String &&
        previewImageUrl.isNotEmpty &&
        !previewImageUrl.startsWith('http')) {
      failed.add('previewImageUrl');
    }
    return TemplateValidationReport(
      passed: failed.isEmpty,
      failedChecks: failed,
    );
  }
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
  // Bundle fields, when present: the registry manifest copy must be
  // a well-formed bundle manifest for the live shell.
  if (d.containsKey('bundleHash') ||
      d.containsKey('bundleVersion') ||
      d.containsKey('shellMinVersion')) {
    final bundleHash = d['bundleHash'];
    if (bundleHash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(bundleHash)) {
      failed.add('manifest.bundleHash');
    }
    final bundleVersion = d['bundleVersion'];
    if (bundleVersion is! String || !_isSemver(bundleVersion)) {
      failed.add('manifest.bundleVersion');
    }
    final shellMin = d['shellMinVersion'];
    if (shellMin is! String || !_isSemver(shellMin)) {
      failed.add('manifest.shellMinVersion');
    } else if (compareSemver(shellMin, liveShellVersion) > 0) {
      failed.add('manifest.shellMinVersion.newerThanShell');
    }
    final bundleStatus = d['status'];
    if (bundleStatus is String &&
        !bundleStatuses.contains(bundleStatus) &&
        bundleStatus != 'archived') {
      failed.add('manifest.status');
    }
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
  // `sections` is a Map<String, bool> on v1 docs and a List<String>
  // (the manifest's section names) on bundle docs — either shape
  // degrades to the classic defaults, never a crash.
  final rawSections = d['sections'];
  final sections = <String, bool>{...Templates.classicSections};
  if (rawSections is Map) {
    for (final entry in rawSections.entries) {
      final key = entry.key.toString();
      if (templateSectionKeys.contains(key) && entry.value is bool) {
        sections[key] = entry.value as bool;
      }
    }
  } else if (rawSections is List) {
    for (final s in rawSections) {
      final key = s.toString();
      if (templateSectionKeys.contains(key)) sections[key] = true;
    }
  }
  int asInt(dynamic v, int fallback) => v is int ? v : fallback;
  int? asGridInt(dynamic v, int min, int max) =>
      v is int && v >= min && v <= max ? v : null;
  final bundleHash = (d['bundleHash'] as String?) ?? '';
  // The spec-shaped registry doc carries the bundle version as the
  // string `version` ('1.0.0'), not `bundleVersion` — read that
  // first, with an explicit `bundleVersion` key (hybrids) winning.
  final bundleVersion = (d['bundleVersion'] as String?) ??
      (d['version'] is String ? d['version'] as String : null) ??
      '';
  final approval = (d['approval'] as Map<String, dynamic>?) ?? {};
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
    // The Dart model's bodyPath is the Hosting bundle path for
    // bundle templates (B6 fix); v1 templates keep the old path.
    bodyPath: bundleHash.isNotEmpty
        ? '/templates/$id/$bundleVersion/manifest.json'
        : ((d['bodyPath'] as String?) ?? 'templates/$id.json'),
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
    nameAr: (d['nameAr'] as String?) ?? '',
    nameEn: (d['nameEn'] as String?) ?? '',
    bundleVersion: bundleVersion,
    bundleHash: bundleHash,
    shellMinVersion: (d['shellMinVersion'] as String?) ?? '',
    previewImageUrl: (d['previewImageUrl'] as String?) ??
        (d['thumbnailUrl'] as String?) ??
        '',
    approvalApprover: (approval['approver'] as String?) ?? '',
    approvalShellVersion: (approval['shellVersion'] as String?) ?? '',
    approvalBundleHash: (approval['bundleHash'] as String?) ?? '',
  );
}

// ------------------------------------------------------------------
// Pointer history stack — pure helpers (unit-tested). The pointer
// document carries an ordered stack; rollback restores the
// SECOND-LAST entry. Rolling back twice walks the stack backwards
// one step at a time and can never ping-pong.
// ------------------------------------------------------------------

/// The rollback target: the second-last entry of the history stack,
/// or null when there is nothing to roll back to.
Map<String, dynamic>? rollbackTargetEntry(List<dynamic> history) {
  if (history.length < 2) return null;
  final target = history[history.length - 2];
  return target is Map<String, dynamic> ? target : null;
}

/// Appends one entry to a history stack (returns a new list).
List<Map<String, dynamic>> appendHistoryEntry(
  List<dynamic> history,
  Map<String, dynamic> entry,
) {
  final next = history
      .whereType<Map<String, dynamic>>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
  next.add(Map<String, dynamic>.from(entry));
  return next;
}

/// Classic pin (spec §2): the classic bundle cannot be archived or
/// deleted while it is the rollback target — i.e. while it is live
/// or anywhere in the pointer history stack.
bool classicMayBeArchived({
  required bool isLive,
  required bool inHistory,
}) =>
    !isLive && !inHistory;

// ------------------------------------------------------------------
// Preview slugs — 128-bit unguessable, URL-safe (spec entry 8).
// ------------------------------------------------------------------

/// Issues a fresh 128-bit random slug (16 bytes → 22 base64url
/// chars, no padding). Never derived from the template id or time.
String generatePreviewSlug() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// The shareable preview link for a slug.
String previewUrlForSlug(String slug) => '$storefrontBaseUrl/?preview=$slug';

class TemplatesService {
  TemplatesService._();
  static final TemplatesService instance = TemplatesService._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  /// Who is approving / activating, for the approval + history
  /// records (ids only in telemetry; the email is the audit actor).
  String get currentActor =>
      FirebaseAuth.instance.currentUser?.email ??
      FirebaseAuth.instance.currentUser?.uid ??
      'admin';

  /// The registry, newest first. Rules: list is admin/manager only.
  Stream<QuerySnapshot<Map<String, dynamic>>> templatesStream() => _db
      .collection('templates')
      .orderBy('createdAt', descending: true)
      .snapshots();

  /// The activation pointer (storeSettings/activeTemplate). Public
  /// read — the storefront reads the same document at boot.
  Stream<DocumentSnapshot<Map<String, dynamic>>> activeTemplatePointerStream() =>
      _db.collection('storeSettings').doc('activeTemplate').snapshots();

  /// One template's activation history (subcollection, newest
  /// first). Append-only audit data.
  Stream<QuerySnapshot<Map<String, dynamic>>> templateActivationsStream(
    String id, {
    int limit = 5,
  }) =>
      _db
          .collection('templates')
          .doc(id)
          .collection('activations')
          .orderBy('at', descending: true)
          .limit(limit)
          .snapshots();

  Future<Map<String, dynamic>?> _pointerData() async {
    final snap =
        await _db.collection('storeSettings').doc('activeTemplate').get();
    return snap.data();
  }

  Future<List<dynamic>> _pointerHistory() async {
    final pointer = await _pointerData();
    final history = pointer?['history'];
    return history is List ? history : <dynamic>[];
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
    // Six-field bundle shape (spec §2 line 276; rules
    // templateShapeOk): the v1-shaped seed (Templates.classic.toMap)
    // is denied by the strict bundle-shape rules, so a missing
    // classic doc could never be re-seeded and rollback-to-classic
    // failed. Templates.classic itself is UNCHANGED — it stays the
    // v1 fallback definition for the fallback chain (decision 15).
    final doc = <String, dynamic>{
      'id': 'classic',
      'nameAr': 'الكلاسيكي',
      'nameEn': 'Classic',
      'version': '1.0.0',
      'shellMinVersion': '1.0.0',
      'bundleHash': classicBundleHash,
      'status': 'active',
      'previewImageUrl':
          'https://store-3384c.web.app/templates/classic/1.0.0/preview.png',
    };
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

  /// Validates a registry document's manifest copy (pure part of the
  /// gateway — no Hosting fetch). Registry-shape (A): a bundle
  /// document is validated against the six-field bundle rules only
  /// (validateTemplateDoc's bundle branch); a v1 document against
  /// the v1 checks. The full-manifest validator NEVER runs on
  /// registry data — the hosted manifest is validated by
  /// validateLiveBundle instead.
  Future<BundleValidationReport> validateRegistryTemplate(String id) async {
    final snap = await _db.collection('templates').doc(id).get();
    final data = snap.data();
    if (data == null) {
      return const BundleValidationReport(
        passed: false,
        failedChecks: ['registry.missing'],
      );
    }
    // Registry-shape (A): the registry doc is validated with the
    // bundle-rules-only six-field check (validateTemplateDoc's
    // bundle branch for bundle docs, the v1 checks for v1 docs) —
    // NEVER the full-manifest validator; the hosted manifest is
    // validated separately by validateLiveBundle.
    final v1 = validateTemplateDoc(data);
    return BundleValidationReport(
      passed: v1.passed,
      failedChecks: v1.failedChecks,
      warnings: v1.warnings,
    );
  }

  /// Validates the LIVE bundle files on Hosting against the registry
  /// (manifest + sections + styles.css + tokens.json + hash).
  /// 10-second total timeout per the gateway rules; any fetch
  /// failure fails the whole bundle to classic — a bundle never
  /// renders partially.
  Future<BundleValidationReport> validateLiveBundle(String id) async {
    final snap = await _db.collection('templates').doc(id).get();
    final data = snap.data();
    if (data == null) {
      return const BundleValidationReport(
        passed: false,
        failedChecks: ['registry.missing'],
      );
    }
    final record = parseTemplateDoc(id, data);
    if (!record.isBundle) {
      return const BundleValidationReport(
        passed: false,
        failedChecks: ['bundle.notABundle'],
      );
    }
    final base =
        '$storefrontBaseUrl/templates/$id/${record.bundleVersion}';
    try {
      final manifestText = await _fetchText('$base/manifest.json');
      final manifest = jsonDecode(manifestText) as Map<String, dynamic>;
      final styles = await _fetchText('$base/styles.css');
      final tokensText = await _fetchText('$base/tokens.json');
      final tokens = jsonDecode(tokensText) as Map<String, dynamic>;
      // The classic bundle is a wrap (index.html + classic.json),
      // not authored sections — validate it the wrap way (identity
      // + tokens + hash), like the JS gateway's isClassicWrap.
      if (id == 'classic') {
        final indexHtml = await _fetchText('$base/index.html');
        final classicJson = await _fetchText('$base/classic.json');
        return validateBundleFiles(
          manifest: manifest,
          stylesCss: styles,
          tokens: tokens,
          expectedBundleHash: record.bundleHash,
          registryId: id,
          indexHtml: indexHtml,
          classicJson: classicJson,
        );
      }
      final sections = <String, String>{};
      final listed = manifest['sections'];
      if (listed is List) {
        for (final name in listed) {
          sections['$name.html'] =
              await _fetchText('$base/sections/$name.html');
        }
      }
      return validateBundleFiles(
        manifest: manifest,
        sections: sections,
        stylesCss: styles,
        tokens: tokens,
        expectedBundleHash: record.bundleHash,
        registryId: id,
      );
    } catch (e) {
      Diagnostics.instance.log('validateLiveBundle($id) failed: $e');
      return const BundleValidationReport(
        passed: false,
        failedChecks: ['bundle.fetch'],
      );
    }
  }

  Future<String> _fetchText(String url) async {
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw BackendException('تعذر تحميل $url (${response.statusCode})');
    }
    return response.body;
  }

  /// Runs the gateway on a draft and, on pass, moves it to `preview`
  /// (the state that IS awaiting Mohamed's approval — there is no
  /// separate awaiting-approval state). A failed gateway leaves it
  /// in `draft` with the report stored on the document.
  Future<BundleValidationReport> runValidation(String id) async {
    final report = await validateRegistryTemplate(id);
    final snap = await _db.collection('templates').doc(id).get();
    final data = snap.data();
    if (data == null) throw BackendException('القالب مش موجود');
    final status = (data['status'] as String?) ?? 'draft';
    final writes = <String, Map<String, dynamic>>{
      'templates/$id': {
        'validation': {
          'passed': report.passed,
          'checks': report.failedChecks,
          'at': FieldValue.serverTimestamp(),
        },
      },
    };
    if (report.passed && status == 'draft') {
      writes['templates/$id']!['status'] = 'preview';
    }
    await Backend.instance.auditedWrite(
      writes: writes,
      sensitive: const {},
      operation: 'template_validate',
      oldValues: {
        'templates/$id': {'status': status},
      },
      topNewValues: {
        'templateId': id,
        'validationPassed': report.passed,
      },
    );
    return report;
  }

  /// Mohamed's approval (D1 checklist is judged in the UI — this
  /// method only records it). Requires a passing gateway + status
  /// `preview`. Freezes bundle hash + shell version; a changed hash
  /// requires re-approval. Rotates the preview slug on re-approval.
  Future<void> approveTemplate({required String id}) async {
    final snap = await _db.collection('templates').doc(id).get();
    final data = snap.data();
    if (data == null) throw BackendException('القالب مش موجود');
    final record = parseTemplateDoc(id, data);
    if (!record.isBundle) {
      throw BackendException('القالب ده من النظام القديم — مفيش اعتماد بالهاش');
    }
    // Registry-shape (A): the registry doc gets the six-field
    // bundle-rules check only; the HOSTED manifest (fetch from
    // Hosting + hash check) is validated by validateLiveBundle —
    // the full-manifest validator never runs on registry data.
    final report = validateTemplateDoc(data);
    if (!report.passed) {
      throw BackendException(
          'القالب مش صالح للاعتماد: ${report.failedChecks.join('، ')}');
    }
    final live = await validateLiveBundle(id);
    if (!live.passed) {
      throw BackendException(
          'القالب المستضاف مش صالح للاعتماد: ${live.failedChecks.join('، ')}');
    }
    if (record.status != 'preview') {
      throw BackendException('القالب لازم يكون في حالة المعاينة قبل الاعتماد');
    }
    final wasApproved = record.approvalBundleHash.isNotEmpty;
    await Backend.instance.auditedWrite(
      writes: {
        'templates/$id': {
          'status': 'approved',
          'approval': {
            'approver': currentActor,
            'at': FieldValue.serverTimestamp(),
            'shellVersion': liveShellVersion,
            'bundleHash': record.bundleHash,
          },
        },
      },
      sensitive: const {},
      operation: 'template_approve',
      oldValues: {
        'templates/$id': {'status': record.status},
      },
      topNewValues: {
        'templateId': id,
        'status': 'approved',
        'bundleHash': record.bundleHash,
      },
    );
    // Rotate the preview slug on re-approval (a fresh slug per
    // approval round); failures are logged, never fatal.
    if (wasApproved) {
      try {
        await rotatePreviewSlug(
          templateId: id,
          version: record.bundleVersion,
        );
      } catch (e) {
        Diagnostics.instance.log('Preview slug rotation failed ($id): $e');
      }
    }
    Diagnostics.instance.log('Template approved: $id');
  }

  /// Activates a template: draft → preview → confirm → apply.
  /// One pointer write (templateId + bundleVersion + bundleHash,
  /// approver + timestamp) + activation-history append + pointer
  /// history-stack append. The status move (approved → active) and
  /// the pointer write happen in ONE audited batch, so the rules'
  /// getAfter check sees the target as 'active'.
  ///
  /// Bundle templates require a live approval whose frozen hash
  /// still matches the registry hash — a changed hash requires
  /// re-approval. v1 templates (classic, until its bundle lands)
  /// use the legacy v1 gateway instead.
  Future<void> activateTemplate({required String templateId}) async {
    final snap = await _db.collection('templates').doc(templateId).get();
    final data = snap.data();
    if (data == null) {
      throw BackendException('القالب مش موجود');
    }
    final record = parseTemplateDoc(templateId, data);
    if (record.isBundle) {
      // Registry-shape (A): the registry doc gets the six-field
      // bundle-rules check only; the HOSTED manifest (fetch from
      // Hosting + hash check) is validated by validateLiveBundle —
      // the full-manifest validator never runs on registry data.
      final report = validateTemplateDoc(data);
      if (!report.passed) {
        throw BackendException(
            'القالب مش صالح للتفعيل: ${report.failedChecks.join('، ')}');
      }
      final live = await validateLiveBundle(templateId);
      if (!live.passed) {
        throw BackendException(
            'القالب المستضاف مش صالح للتفعيل: ${live.failedChecks.join('، ')}');
      }
      if (record.status != 'approved' && record.status != 'active') {
        throw BackendException(
            'القالب لسه معتمدش — لازم المعاينة والاعتماد الأول');
      }
      if (!record.approvalStillValid) {
        throw BackendException(
            'الهاش اتغير بعد الاعتماد — لازم إعادة اعتماد قبل التفعيل');
      }
    } else {
      final report = validateTemplateDoc(data);
      if (!report.passed) {
        throw BackendException(
            'القالب مش صالح للتفعيل: ${report.failedChecks.join('، ')}');
      }
    }
    await _ensureClassicTemplateDoc();
    final pointer = await _pointerData();
    final history = await _pointerHistory();
    final currentId = (pointer?['templateId'] as String?) ?? 'classic';
    if (currentId == templateId) {
      throw BackendException('القالب ده مفعّل أصلاً');
    }
    final by = currentActor;
    final entry = <String, dynamic>{
      'templateId': templateId,
      'bundleVersion': record.bundleVersion,
      'bundleHash': record.bundleHash,
      'at': Timestamp.now(),
      'by': by,
      'action': 'activate',
    };
    final writes = <String, Map<String, dynamic>>{
      'templates/$templateId': {'status': 'active'},
      'storeSettings/activeTemplate': {
        'templateId': templateId,
        'bundleVersion': record.bundleVersion,
        'bundleHash': record.bundleHash,
        'previousTemplateId': currentId,
        'history': appendHistoryEntry(history, entry),
        'activatedBy': by,
        'activatedAt': FieldValue.serverTimestamp(),
      },
    };
    // The template that stops being live returns to 'approved' —
    // it keeps its approval, so re-activation needs no re-approval
    // unless its hash changed. Only for bundle templates that
    // HAVE an approval record; v1 classic keeps 'active' so the
    // old rollback path keeps working.
    String? previousStatus;
    if (currentId != 'classic' && currentId.isNotEmpty) {
      final prevSnap =
          await _db.collection('templates').doc(currentId).get();
      final prevData = prevSnap.data();
      if (prevData != null) {
        final prev = parseTemplateDoc(currentId, prevData);
        if (prev.isBundle &&
            prev.approvalBundleHash.isNotEmpty &&
            prev.status == 'active') {
          previousStatus = prev.status;
          writes['templates/$currentId'] = {'status': 'approved'};
        }
      }
    }
    await Backend.instance.auditedWrite(
      writes: writes,
      sensitive: const {},
      operation: 'template_activate',
      oldValues: {
        'templates/$templateId': {'status': data['status']},
        if (previousStatus != null)
          'templates/$currentId': {'status': previousStatus},
        'storeSettings/activeTemplate': {'templateId': currentId},
      },
      topNewValues: {
        'templateId': templateId,
        'previousTemplateId': currentId,
        'bundleVersion': record.bundleVersion,
        'bundleHash': record.bundleHash,
      },
    );
    await _appendActivationHistory(
      templateId: templateId,
      bundleVersion: record.bundleVersion,
      bundleHash: record.bundleHash,
      action: 'activate',
      by: by,
    );
    Diagnostics.instance.log('Template activated: $templateId');
  }

  /// One-tap rollback: the pointer restores the SECOND-LAST entry
  /// of the pointer history stack (previousTemplateId is display
  /// only — never the rollback source). Rollback itself appends a
  /// new history entry, so rolling back twice walks the stack
  /// backwards one step at a time and can never ping-pong.
  /// Rolling back to a template that has since been archived or
  /// retired is denied by the rules — in that case rollback restores
  /// classic instead, and the denial is recorded in the history.
  Future<void> rollbackTemplate() async {
    final pointer = await _pointerData();
    final history = await _pointerHistory();
    final currentId = (pointer?['templateId'] as String?) ?? 'classic';
    final target = rollbackTargetEntry(history);
    if (target == null) {
      throw BackendException('مفيش قالب سابق للرجوع ليه');
    }
    var targetId = (target['templateId'] as String?) ?? '';
    if (targetId.isEmpty || targetId == currentId) {
      throw BackendException('القالب السابق هو نفسه الحالي');
    }
    String? denial;
    final targetSnap = await _db.collection('templates').doc(targetId).get();
    final targetData = targetSnap.data();
    if (targetData == null) {
      denial = 'القالب السابق مش موجود — رجعنا للكلاسيكي';
      targetId = 'classic';
    } else if (isRetiredStatus(targetData['status'] as String?)) {
      denial =
          'القالب السابق اتأرشف — الرجوع ليه مرفوض، رجعنا للكلاسيكي';
      targetId = 'classic';
    }
    TemplateRecord targetRecord;
    if (targetId == 'classic' && targetData == null) {
      await _ensureClassicTemplateDoc();
      targetRecord = Templates.classic;
    } else {
      final snap = await _db.collection('templates').doc(targetId).get();
      final data = snap.data();
      if (data == null) {
        throw BackendException('القالب السابق مش موجود');
      }
      targetRecord = parseTemplateDoc(targetId, data);
      if (targetRecord.isBundle) {
        // Registry-shape (A): six-field registry check + hosted
        // manifest check (validateLiveBundle); the full-manifest
        // validator never runs on registry data.
        final report = validateTemplateDoc(data);
        if (!report.passed) {
          throw BackendException(
              'القالب السابق مش صالح: ${report.failedChecks.join('، ')}');
        }
        final live = await validateLiveBundle(targetId);
        if (!live.passed) {
          throw BackendException(
              'القالب المستضاف السابق مش صالح: ${live.failedChecks.join('، ')}');
        }
      } else {
        final report = validateTemplateDoc(data);
        if (!report.passed) {
          throw BackendException(
              'القالب السابق مش صالح: ${report.failedChecks.join('، ')}');
        }
      }
    }
    final by = currentActor;
    final entry = <String, dynamic>{
      'templateId': targetId,
      'bundleVersion': targetRecord.bundleVersion,
      'bundleHash': targetRecord.bundleHash,
      'at': Timestamp.now(),
      'by': by,
      'action': 'rollback',
      if (denial != null) 'note': denial,
    };
    await Backend.instance.auditedWrite(
      writes: {
        'templates/$targetId': {'status': 'active'},
        'storeSettings/activeTemplate': {
          'templateId': targetId,
          'bundleVersion': targetRecord.bundleVersion,
          'bundleHash': targetRecord.bundleHash,
          'previousTemplateId': currentId,
          'history': appendHistoryEntry(history, entry),
          'activatedBy': by,
          'activatedAt': FieldValue.serverTimestamp(),
        },
      },
      sensitive: const {},
      operation: 'template_rollback',
      oldValues: {
        'storeSettings/activeTemplate': {'templateId': currentId},
      },
      topNewValues: {
        'templateId': targetId,
        'previousTemplateId': currentId,
      },
    );
    await _appendActivationHistory(
      templateId: targetId,
      bundleVersion: targetRecord.bundleVersion,
      bundleHash: targetRecord.bundleHash,
      action: 'rollback',
      by: by,
    );
    Diagnostics.instance.log('Template rolled back to: $targetId');
    if (denial != null) {
      Diagnostics.instance.log('Rollback denial: $denial');
    }
  }

  /// Appends one activation/rollback document to the template's
  /// activation-history subcollection. Best-effort: the rules for
  /// this subcollection land with the rules child's entry 10 — until
  /// then the write fails at runtime and is logged, never fatal,
  /// because the pointer write already committed.
  Future<void> _appendActivationHistory({
    required String templateId,
    required String bundleVersion,
    required String bundleHash,
    required String action,
    required String by,
  }) async {
    try {
      final ref = _db
          .collection('templates')
          .doc(templateId)
          .collection('activations')
          .doc();
      await ref.set({
        'operationId': ref.id,
        'templateId': templateId,
        'bundleVersion': bundleVersion,
        'bundleHash': bundleHash,
        'shellVersion': liveShellVersion,
        'approver': by,
        'at': FieldValue.serverTimestamp(),
        'action': action,
      });
    } catch (e) {
      Diagnostics.instance.log(
          'Activation history append failed ($templateId): $e');
    }
  }

  /// Issues an unguessable 128-bit preview slug for a template
  /// version and writes its previews/{slug} document (admin app
  /// owns the slug lifecycle — a Firestore write, never a deploy).
  /// Returns the shareable preview URL.
  Future<String> issuePreviewSlug({
    required String templateId,
    required String version,
  }) async {
    final slug = generatePreviewSlug();
    try {
      await _db.collection('previews').doc(slug).set({
        'templateId': templateId,
        'version': version,
        'issuedAt': FieldValue.serverTimestamp(),
        'issuedBy': currentActor,
        'status': 'open',
      });
    } catch (e) {
      Diagnostics.instance.log('Preview slug issue failed: $e');
      throw BackendException('تعذر إصدار رابط المعاينة: $e');
    }
    return previewUrlForSlug(slug);
  }

  /// Revokes one preview slug. A revoked slug renders a plain
  /// "preview closed" state with no store content.
  Future<void> revokePreviewSlug(String slug) async {
    try {
      await _db.collection('previews').doc(slug).update({
        'status': 'revoked',
      });
    } catch (e) {
      Diagnostics.instance.log('Preview slug revoke failed: $e');
      throw BackendException('تعذر إلغاء رابط المعاينة: $e');
    }
  }

  /// Rotates a template's preview slugs: revokes every open slug
  /// for the template, then issues a fresh one. Returns the new
  /// preview URL.
  Future<String> rotatePreviewSlug({
    required String templateId,
    required String version,
  }) async {
    final open = await _db
        .collection('previews')
        .where('templateId', isEqualTo: templateId)
        .where('status', isEqualTo: 'open')
        .get();
    for (final doc in open.docs) {
      try {
        await doc.reference.update({'status': 'revoked'});
      } catch (e) {
        Diagnostics.instance.log('Preview slug rotate revoke failed: $e');
      }
    }
    return issuePreviewSlug(templateId: templateId, version: version);
  }

  /// Revokes every open preview slug for a template (called on
  /// retire — a retired template's previews close with it).
  Future<void> revokeAllPreviewSlugs(String templateId) async {
    final open = await _db
        .collection('previews')
        .where('templateId', isEqualTo: templateId)
        .where('status', isEqualTo: 'open')
        .get();
    for (final doc in open.docs) {
      try {
        await doc.reference.update({'status': 'revoked'});
      } catch (e) {
        Diagnostics.instance.log('Preview slug revoke failed: $e');
      }
    }
  }

  /// Archives a template or returns it to draft. Activation goes
  /// only through activateTemplate (which runs the gateway first)
  /// and approval only through approveTemplate.
  /// Classic pin: the classic bundle cannot be archived or retired
  /// while it is the rollback target (live or in the history stack).
  Future<void> setTemplateStatus({
    required String id,
    required String status,
  }) async {
    if (status != 'draft' &&
        status != 'archived' &&
        status != 'retired') {
      throw BackendException('الحالة دي بتتغير من التفعيل بس');
    }
    final snap = await _db.collection('templates').doc(id).get();
    final data = snap.data();
    if (data == null) throw BackendException('القالب مش موجود');
    final pointer = await _pointerData();
    if ((pointer?['templateId'] as String?) == id) {
      throw BackendException('مينفعش تغير حالة القالب المفعّل — رجّع قالب تاني الأول');
    }
    if (id == 'classic' && isRetiredStatus(status)) {
      final history = await _pointerHistory();
      final inHistory = history.any((e) =>
          e is Map<String, dynamic> && e['templateId'] == 'classic');
      final isLive = (pointer?['templateId'] as String?) == 'classic';
      if (!classicMayBeArchived(isLive: isLive, inHistory: inHistory)) {
        throw BackendException(
            'الكلاسيكي مثبت كقالب الرجوع الآمن — مينفعش يتأرشف وهو في سجل التفعيل');
      }
      // Retiring classic also closes its previews.
      try {
        await revokeAllPreviewSlugs(id);
      } catch (e) {
        Diagnostics.instance.log('Preview revoke on retire failed: $e');
      }
    }
    if (isRetiredStatus(status)) {
      try {
        await revokeAllPreviewSlugs(id);
      } catch (e) {
        Diagnostics.instance.log('Preview revoke on retire failed: $e');
      }
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
