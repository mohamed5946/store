/* Bundle gateway — shell fast structural check (spec Section 2, entry 3).
 *
 * Pure functions, no DOM dependency. Importable by the browser
 * (storefront/index.html loads this file before app.js, exposing
 * window.BundleGateway) and by node --test (module.exports).
 *
 * Single source of truth: storefront/templates/gateway-rules.json.
 * The RULES constant below is a verbatim copy of that file — do NOT
 * edit the rules here; edit gateway-rules.json and copy it in (the
 * node tests assert the two agree). Every function also accepts an
 * explicit `rules` argument so the tests can pass the JSON file
 * itself; when omitted, the embedded copy is used.
 *
 * Checks implemented here (the shell fast check): identity/version/
 * hash, required sections incl. the brand slot, no-JavaScript
 * allow-list scan, motion budget, tokens.json required, data-needs
 * naming, CSS scoping, font origins, RTL warning. NOT implemented
 * here (need admin context): registry-side approval-freeze
 * verification and live CSP-header verification.
 *
 * Returns a validation report ({ passed, failed: [...], warnings: [...]
 * , checks: {...} }) — never a bare boolean. */
'use strict';

/* GATEWAY-RULES-BEGIN — verbatim copy of
 * storefront/templates/gateway-rules.json. Keep in sync; the node
 * tests fail if this copy disagrees with the JSON file. */
const GATEWAY_RULES = {
  allowedActions: ['add-to-cart', 'open-cart', 'open-product', 'select-category', 'search', 'toggle-grid-list', 'toggle-compare', 'filter-chip'],
  allowedAttributes: ['data-slot', 'data-action', 'data-section', 'href', 'src', 'alt', 'class'],
  allowedCssProperties: ['display', 'flex', 'flex-direction', 'flex-wrap', 'flex-grow', 'flex-shrink', 'gap', 'align-items', 'justify-content', 'grid-template-columns', 'grid-auto-flow', 'padding', 'padding-inline-start', 'padding-inline-end', 'padding-top', 'padding-bottom', 'margin', 'margin-inline-start', 'margin-inline-end', 'margin-top', 'margin-bottom', 'border', 'border-radius', 'border-start-start-radius', 'border-start-end-radius', 'border-end-start-radius', 'border-end-end-radius', 'background', 'background-color', 'color', 'font-family', 'font-size', 'font-weight', 'line-height', 'letter-spacing', 'text-align', 'text-decoration', 'opacity', 'transform', 'transition', 'animation', 'overflow', 'overflow-x', 'overflow-y', 'position', 'inset-inline-start', 'inset-inline-end', 'top', 'bottom', 'width', 'height', 'min-height', 'max-width', 'max-height', 'box-shadow', 'cursor', 'white-space', 'text-overflow', 'object-fit', 'aspect-ratio', 'z-index', 'direction', 'scroll-snap-type', 'scroll-snap-align', 'scroll-behavior'],
  allowedSlots: ['product-name', 'product-price', 'product-old-price', 'product-image', 'product-card', 'category-name', 'category-image', 'featured-spot', 'promo-banner', 'delivery-fee', 'brand-name', 'brand-logo', 'brand-tagline', 'whatsapp-number', 'cod-message', 'max-discount-pct'],
  allowedTags: ['section', 'div', 'span', 'h1', 'h2', 'h3', 'p', 'a', 'img', 'button', 'ul', 'li'],
  behaviours: ['countdown-strip', 'feed', 'grid-list-toggle', 'filter-chips', 'comparison-strip', 'hero-crossfade'],
  bundleHash: { algorithm: 'SHA-256', excluded: ['preview.png'], files: ['manifest.json (excluding its own bundleHash field)', 'every file in sections/', 'styles.css', 'tokens.json'], order: 'lexicographic path order, concatenated', serialisation: 'canonical: manifest.json and tokens.json are parsed as JSON and re-serialised with object keys sorted recursively and no whitespace (manifest.json with its bundleHash field removed first); sections/*.html and styles.css are hashed as raw bytes. The classic wrap hashes manifest.json, index.html, classic.json, styles.css, tokens.json under the same rule.' },
  bundleTimeoutMs: 10000,
  cartLayouts: ['drawer', 'bottom-sheet'],
  dataNeeds: ['oldPrice', 'specs', 'deliveryFee'],
  fontOrigins: ['self', 'https://fonts.googleapis.com', 'https://fonts.gstatic.com'],
  forbiddenAttributePrefixes: ['on'],
  forbiddenCss: ['url() except declared font/image origins', '@import except declared font origins', 'blur', 'backdrop-filter', 'animation or transition of any property other than transform/opacity'],
  forbiddenSelectorPatterns: ['display: none on a price, a button, or an input inside a transactional surface'],
  forbiddenSelectors: ['#cartDrawer', '#modal', '#journey', '#checkoutBtn', '#cartBtn', '.toast'],
  forbiddenTags: ['script', 'form', 'meta', 'link', 'iframe', 'object', 'embed', 'style', 'input', 'select', 'textarea'],
  forbiddenUrlSchemes: ['javascript:'],
  imageOrigins: ['self', 'https://res.cloudinary.com'],
  linkOrigins: ['self', 'https://wa.me/'],
  modalLayouts: ['default', 'sheet'],
  motion: { ambientLoopExempt: true, ambientLoopNote: 'The 1500 ms cap governs entrance/transitions only; infinite ambient loops (named pure-CSS effects such as marquee and slow-zoom) are exempt.', animatedProperties: ['transform', 'opacity'], forbiddenAnimatedProperties: ['blur', 'backdrop-filter', 'width', 'height'], maxDurationMs: 1500 },
  note: 'Single source of truth for the bundle gateway (spec Section 2, entry 3). All three gateway implementations (shell bundle-gateway.js, Flutter templates_service.dart, PC firebase-store.js) MUST interpret this file; an implementation that disagrees with it fails the parity tests. If it is not on an allow-list here, it is rejected.',
  pureCssEffects: ['marquee', 'slow-zoom', 'card-glide'],
  requiredBrandSlot: true,
  requiredSections: ['products', 'delivery', 'contact'],
  rtlPhysicalPosition: 'warning-only: physical left/right positioning is a warning (spec check 8), never a failure',
  sectionFiles: ['hero', 'marquee', 'categories', 'featured', 'offers', 'products', 'delivery', 'contact', 'about'],
  sectionVariants: ['photo-menu', 'deal-rails', 'curated-grid'],
  shellVersion: '1.0.0',
  statusEnum: ['draft', 'preview', 'approved', 'active', 'retired'],
  templateIds: ['bazaar', 'gallery', 'scroll', 'speclab', 'boutique', 'classic'],
  tokensRequired: true,
  version: 1,
};
/* GATEWAY-RULES-END */

function rulesOf(rules) {
  return (rules && typeof rules === 'object') ? rules : GATEWAY_RULES;
}

/* semver compare: -1 / 0 / 1. Only major.minor.patch numerics. */
function compareSemver(a, b) {
  const pa = String(a || '0').split('.').map((x) => Number(x) || 0);
  const pb = String(b || '0').split('.').map((x) => Number(x) || 0);
  for (let i = 0; i < 3; i++) {
    const x = pa[i] || 0;
    const y = pb[i] || 0;
    if (x < y) return -1;
    if (x > y) return 1;
  }
  return 0;
}

/* Tolerant pointer read (spec entry 0 / M38): a pointer missing
 * bundleVersion/bundleHash means "classic, version 1" — never a
 * failure. Returns { templateId, version, bundleHash,
 * previousTemplateId, isLegacy }. */
function resolvePointer(pointer) {
  const p = (pointer && typeof pointer === 'object') ? pointer : {};
  const templateId = (typeof p.templateId === 'string' && p.templateId) ? p.templateId : 'classic';
  const version = (typeof p.bundleVersion === 'string' && p.bundleVersion)
    ? p.bundleVersion
    : (Number.isInteger(p.version) ? String(p.version) + '.0.0' : '1.0.0');
  // A legacy v1 pointer ({templateId, previousTemplateId} only, or a
  // numeric version 1) is classic version 1 by definition.
  const isLegacy = !p.bundleVersion || !p.bundleHash;
  return {
    templateId,
    version: isLegacy && templateId === 'classic' ? '1.0.0' : version,
    bundleHash: (typeof p.bundleHash === 'string' && p.bundleHash) ? p.bundleHash : null,
    previousTemplateId: (typeof p.previousTemplateId === 'string') ? p.previousTemplateId : null,
    isLegacy,
  };
}

/* Manifest bytes for the hash (decision 1, canonical rule pinned in
 * gateway-rules.json bundleHash.serialisation): the manifest parsed
 * as JSON, its own bundleHash field removed, re-serialised with
 * object keys sorted recursively and NO whitespace. The raw file
 * bytes are NEVER hashed: pretty vs compact authoring, key order
 * and trailing newlines must not change the hash. This is the same
 * canonical form the Dart gateway (canonicalJson) and the fixture
 * generator hash, so all three agree byte for byte. */
function manifestBytesForHash(text) {
  return canonicalManifestString(JSON.parse(String(text == null ? '' : text)));
}

function canonicalJsonString(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(canonicalJsonString).join(',') + ']';
  const keys = Object.keys(value).sort();
  return '{' + keys.map((k) => JSON.stringify(k) + ':' + canonicalJsonString(value[k])).join(',') + '}';
}

function canonicalManifestString(manifest) {
  // The hash encoding for manifest.json: deterministic manifest
  // encoding (sorted keys, no whitespace, bundleHash removed).
  // computeBundleHash uses this — see manifestBytesForHash.
  const strip = (v) => {
    if (Array.isArray(v)) return v.map(strip);
    if (v && typeof v === 'object') {
      const out = {};
      for (const k of Object.keys(v).sort()) {
        if (k === 'bundleHash') continue;
        out[k] = strip(v[k]);
      }
      return out;
    }
    return v;
  };
  return JSON.stringify(strip(manifest || {}));
}

function textToBytes(text) {
  if (typeof TextEncoder !== 'undefined') return new TextEncoder().encode(String(text));
  // Node fallback (TextEncoder exists in modern Node too; this is belt
  // and braces for old runtimes).
  return Buffer.from(String(text), 'utf8');
}

function bytesToHex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

/* SHA-256 hex of a Uint8Array/Buffer. Works in the browser
 * (crypto.subtle) and in Node (node:crypto via require when present,
 * else the WebCrypto global). */
async function sha256Hex(data) {
  const bytes = (typeof data === 'string') ? textToBytes(data) : data;
  if (typeof crypto !== 'undefined' && crypto.subtle && crypto.subtle.digest) {
    const digest = await crypto.subtle.digest('SHA-256', bytes);
    return bytesToHex(new Uint8Array(digest));
  }
  if (typeof require === 'function') {
    try {
      const nodeCrypto = require('node:crypto');
      return nodeCrypto.createHash('sha256').update(Buffer.from(bytes)).digest('hex');
    } catch (_) { /* fall through */ }
  }
  throw new Error('sha256_unavailable');
}

/* Bundle hash over the canonical file set: manifest.json (excluding
 * its own bundleHash field), every file in sections/, styles.css,
 * tokens.json — concatenated in lexicographic path order.
 * `files` is an object path -> string content (text files only;
 * preview.png is EXCLUDED by rule and must not be passed in).
 * Canonical serialisation (decision 1): manifest.json and
 * tokens.json are parsed and re-serialised with sorted keys and no
 * whitespace; sections/*.html and styles.css are raw bytes.
 * The classic bundle is a wrap (index.html + classic.json verbatim)
 * rather than sections: the same function hashes whatever canonical
 * files are present, in lexicographic order, so the classic
 * manifest's hash is computed over its own file set and verified
 * with the same code. */
async function computeBundleHash(files, rules) {
  void rules;
  const map = (files && typeof files === 'object') ? files : {};
  const paths = Object.keys(map).filter((p) => p !== 'preview.png').sort();
  const chunks = [];
  for (const p of paths) {
    if (p === 'manifest.json') {
      // Canonical manifest string (sorted keys, no whitespace,
      // bundleHash removed) — never the raw file bytes.
      chunks.push(textToBytes(manifestBytesForHash(map[p])));
    } else if (p === 'tokens.json') {
      // Canonical tokens string, like the manifest. An unparsable
      // tokens.json falls back to its raw bytes here; the tokens
      // check itself fails the bundle separately.
      let text = map[p];
      try { text = canonicalJsonString(JSON.parse(map[p])); } catch (_) { /* keep raw */ }
      chunks.push(textToBytes(text));
    } else {
      chunks.push(textToBytes(map[p]));
    }
  }
  let total = 0;
  for (const c of chunks) total += c.length;
  const all = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) { all.set(c, off); off += c.length; }
  return sha256Hex(all);
}

async function verifyBundleHash(files, expectedHash, rules) {
  if (!expectedHash || typeof expectedHash !== 'string') {
    return { passed: false, actual: null, reason: 'hash_missing' };
  }
  let actual = null;
  try {
    actual = await computeBundleHash(files, rules);
  } catch (e) {
    return { passed: false, actual: null, reason: 'hash_unavailable' };
  }
  return { passed: actual.toLowerCase() === expectedHash.toLowerCase(), actual, reason: actual.toLowerCase() === expectedHash.toLowerCase() ? null : 'hash_mismatch' };
}

/* --- Check 1: identity / version -------------------------------- */
function checkIdentity(manifest, opts) {
  const o = opts || {};
  const r = rulesOf(o.rules);
  const failed = [];
  if (!manifest || typeof manifest !== 'object') return { passed: false, failed: ['manifest_unparsable'] };
  if (typeof manifest.id !== 'string' || !manifest.id) failed.push('manifest.id_missing');
  else if (Array.isArray(r.templateIds) && !r.templateIds.includes(manifest.id)) failed.push('manifest.id_unknown:' + manifest.id);
  if (o.pointerTemplateId && manifest.id !== o.pointerTemplateId) failed.push('manifest.id_mismatch_pointer');
  if (o.registryId && manifest.id !== o.registryId) failed.push('manifest.id_mismatch_registry');
  if (typeof manifest.version !== 'string' || !manifest.version) failed.push('manifest.version_missing');
  else if (o.pointerVersion && manifest.version !== o.pointerVersion) failed.push('manifest.version_mismatch_pointer');
  if (typeof manifest.shellMinVersion !== 'string' || !manifest.shellMinVersion) failed.push('manifest.shellMinVersion_missing');
  else if (compareSemver(manifest.shellMinVersion, o.shellVersion || r.shellVersion || '1.0.0') > 0) {
    failed.push('manifest.shellMinVersion_newer:' + manifest.shellMinVersion);
  }
  if (manifest.motion !== undefined && manifest.motion !== 'calm' && manifest.motion !== 'lively') failed.push('manifest.motion_invalid');
  if (manifest.dark !== undefined && manifest.dark !== 'variant' && manifest.dark !== 'light-only') failed.push('manifest.dark_invalid');
  if (manifest.cartLayout !== undefined && Array.isArray(r.cartLayouts) && !r.cartLayouts.includes(manifest.cartLayout)) failed.push('manifest.cartLayout_invalid');
  if (manifest.modalLayout !== undefined && Array.isArray(r.modalLayouts) && !r.modalLayouts.includes(manifest.modalLayout)) failed.push('manifest.modalLayout_invalid');
  if (Array.isArray(manifest.behaviours)) {
    for (const b of manifest.behaviours) {
      if (!r.behaviours.includes(b)) failed.push('manifest.behaviour_not_whitelisted:' + b);
    }
  } else if (manifest.behaviours !== undefined) {
    failed.push('manifest.behaviours_not_array');
  }
  if (Array.isArray(manifest.sections)) {
    for (const s of manifest.sections) {
      if (!r.sectionFiles.includes(s)) failed.push('manifest.section_unknown:' + s);
    }
  } else if (manifest.sections !== undefined) {
    failed.push('manifest.sections_not_array');
  }
  return { passed: failed.length === 0, failed };
}

/* A classic wrap (entry 7) is the live files verbatim — index.html
 * + styles.css + classic.json — not authored section templates. The
 * shell stylesheet is trusted shell code (it uses backdrop-filter
 * etc.), the skeleton's own <script> tags are the shell's scripts,
 * and the brand renders from the shell topbar via applyBrand. The
 * wrap is validated by byte-identity + bundle hash, not by the
 * section-file / JS-scan / CSS-budget checks. */
function isClassicWrap(files) {
  return !!(files && typeof files['index.html'] === 'string'
    && typeof files['classic.json'] === 'string');
}

/* --- Check 2: required sections + brand slot -------------------- */
function checkRequiredSections(manifest, files) {
  const r = GATEWAY_RULES;
  const failed = [];
  const sections = Array.isArray(manifest && manifest.sections) ? manifest.sections : [];
  const wrap = isClassicWrap(files);
  for (const req of r.requiredSections) {
    if (!sections.includes(req)) failed.push('section_missing:' + req);
    else if (!wrap && (!files || typeof files['sections/' + req + '.html'] !== 'string')) failed.push('section_file_missing:' + req);
  }
  // Brand slot: a section element carrying data-section="brand" that
  // renders the shell-owned brand constants. In a classic wrap the
  // brand renders from the shell topbar (applyBrand), so the wrap
  // satisfies the slot by construction.
  const allHtml = Object.keys(files || {})
    .filter((p) => (p.startsWith('sections/') && p.endsWith('.html')) || p === 'index.html')
    .map((p) => files[p]).join('\n');
  if (r.requiredBrandSlot && !wrap && !/data-section\s*=\s*["']brand["']/.test(allHtml)) {
    failed.push('brand_slot_missing');
  }
  return { passed: failed.length === 0, failed };
}

/* --- Check 3: no-JavaScript allow-list scan --------------------- */
function scanHtmlForJs(html, rules) {
  const r = rulesOf(rules);
  const failed = [];
  // Comments are not markup: strip them so comment text (e.g. a
  // "<script>" mentioned in a note) cannot false-positive the scan.
  const src = String(html || '').replace(/<!--[\s\S]*?-->/g, '');
  // Tags: every opening tag must be allow-listed; every forbidden tag
  // (script/form/meta/link/iframe/...) rejects the whole bundle.
  const tagRe = /<\s*\/?\s*([a-zA-Z][a-zA-Z0-9]*)/g;
  let m;
  const seenTags = new Set();
  while ((m = tagRe.exec(src)) !== null) {
    const tag = m[1].toLowerCase();
    if (seenTags.has(tag)) continue;
    seenTags.add(tag);
    if (r.forbiddenTags.includes(tag)) failed.push('forbidden_tag:' + tag);
    else if (!r.allowedTags.includes(tag)) failed.push('tag_not_allowed:' + tag);
  }
  // Attributes: only the allow-list; any on* handler rejects.
  const attrRe = /([a-zA-Z-]+)\s*=/g;
  const seenAttrs = new Set();
  while ((m = attrRe.exec(src)) !== null) {
    const attr = m[1].toLowerCase();
    if (seenAttrs.has(attr)) continue;
    seenAttrs.add(attr);
    if (r.forbiddenAttributePrefixes.some((p) => attr.startsWith(p))) failed.push('forbidden_attribute:' + attr);
    else if (!r.allowedAttributes.includes(attr)) failed.push('attribute_not_allowed:' + attr);
  }
  // javascript: URLs anywhere.
  if (/javascript\s*:/i.test(src)) failed.push('forbidden_url_scheme:javascript:');
  // Slot / action values must come from the contract vocabulary.
  const slotRe = /data-slot\s*=\s*["']([^"']+)["']/g;
  while ((m = slotRe.exec(src)) !== null) {
    if (!r.allowedSlots.includes(m[1])) failed.push('slot_unknown:' + m[1]);
  }
  const actionRe = /data-action\s*=\s*["']([^"']+)["']/g;
  while ((m = actionRe.exec(src)) !== null) {
    if (!r.allowedActions.includes(m[1])) failed.push('action_unknown:' + m[1]);
  }
  // href/src origins: http(s) links to the store's own pages only
  // for href, plus the allow-listed link origins (gateway-rules.json
  // linkOrigins — https://wa.me/ is the store's own WhatsApp contact
  // channel; bundles keep their hardcoded wa.me hrefs). Images from
  // self or Cloudinary only.
  const hrefRe = /href\s*=\s*["']([^"']+)["']/g;
  while ((m = hrefRe.exec(src)) !== null) {
    const href = m[1];
    if (/^https?:\/\//i.test(href)
      && !(r.linkOrigins || []).some((o) => o !== 'self' && href.startsWith(o))) {
      failed.push('href_external:' + href);
    }
  }
  const srcRe = /src\s*=\s*["']([^"']+)["']/g;
  while ((m = srcRe.exec(src)) !== null) {
    const u = m[1];
    if (/^https?:\/\//i.test(u) && !r.imageOrigins.some((o) => o !== 'self' && u.startsWith(o))) {
      failed.push('img_origin_not_allowed:' + u);
    }
  }
  return failed;
}

function checkNoJavaScript(files, rules) {
  const failed = [];
  for (const p of Object.keys(files || {}).sort()) {
    if (!p.endsWith('.html')) continue;
    if (p === 'manifest.json') continue;
    if (p === 'index.html') continue; // classic wrap: shell skeleton, not bundle markup
    for (const f of scanHtmlForJs(files[p], rules)) failed.push(p + ':' + f);
  }
  // No .js file may exist in a bundle, by rule.
  for (const p of Object.keys(files || {})) {
    if (p.endsWith('.js')) failed.push(p + ':forbidden_file_js');
  }
  return { passed: failed.length === 0, failed };
}

/* --- Check 4: motion budget + CSS allow-list / scoping ---------- */
function checkCss(css, rules, opts) {
  const r = rulesOf(rules);
  const o = opts || {};
  const failed = [];
  const warnings = [];
  // Comments are not rules: strip them so comment text cannot
  // false-positive the @import / url() / duration scans.
  const src = String(css || '').replace(/\/\*[\s\S]*?\*\//g, '');
  // @import: only the manifest's DECLARED font origins (the rule
  // reads "@import except declared font origins"). With no declared
  // origin, any @import is rejected.
  const declaredFontOrigins = Array.isArray(o.declaredFontOrigins) ? o.declaredFontOrigins : [];
  const importRe = /@import\s+(?:url\(\s*["']?([^"')]+)["']?\s*\)|["']([^"']+)["'])/gi;
  let m;
  while ((m = importRe.exec(src)) !== null) {
    const u = m[1] || m[2] || '';
    if (/^https?:\/\//i.test(u)) {
      if (!declaredFontOrigins.some((origin) => origin !== 'self' && u.startsWith(origin))) {
        failed.push('css_import_origin_not_allowed:' + u);
      }
    } else if (u) {
      failed.push('css_import_forbidden');
    }
  }
  // url(): only declared font origins + the rules' image origins.
  const urlRe = /url\(\s*["']?([^"')]+)["']?\s*\)/gi;
  while ((m = urlRe.exec(src)) !== null) {
    const u = m[1];
    if (u.startsWith('data:')) continue;
    if (/^https?:\/\//i.test(u)) {
      const allowed = [...declaredFontOrigins, ...(r.imageOrigins || [])]
        .filter((origin) => origin !== 'self')
        .some((origin) => u.startsWith(origin));
      if (!allowed) failed.push('css_url_origin_not_allowed:' + u);
    }
  }
  // Properties: only the allow-list. Physical left/right are NOT
  // in the allow-list but are a WARNING only (spec check 8, pinned
  // in gateway-rules.json rtlPhysicalPosition) — the RTL warning
  // below covers them instead of a property failure.
  const propRe = /(?:^|[;{])\s*([a-z-]+)\s*:/g;
  const seenProps = new Set();
  while ((m = propRe.exec(src)) !== null) {
    const prop = m[1].toLowerCase();
    if (seenProps.has(prop)) continue;
    seenProps.add(prop);
    if (prop.startsWith('--')) continue; // custom properties are tokens
    if (prop === 'left' || prop === 'right') continue;
    if (!r.allowedCssProperties.includes(prop)) failed.push('css_property_not_allowed:' + prop);
  }
  // @keyframes bodies: only transform/opacity declarations may be
  // animated. A keyframes block animating a forbidden property
  // (e.g. height) fails as motion.keyframes — the Dart gateway's
  // name, so the three gateways agree on the verdict. This closes
  // the invalid-motion-height gap: the animation DECLARATION only
  // names the keyframes, so the declaration scan above cannot see
  // the animated property.
  {
    let searchFrom = 0;
    while (true) {
      const idx = src.toLowerCase().indexOf('@keyframes', searchFrom);
      if (idx < 0) break;
      const open = src.indexOf('{', idx);
      if (open < 0) break;
      let depth = 0;
      let close = -1;
      for (let i = open; i < src.length; i++) {
        if (src[i] === '{') depth++;
        if (src[i] === '}') { depth--; if (depth === 0) { close = i; break; } }
      }
      if (close < 0) break;
      const body = src.slice(open + 1, close);
      const declPropRe = /([a-z-]+)\s*:/g;
      let dm;
      let bad = false;
      while ((dm = declPropRe.exec(body)) !== null) {
        const prop = dm[1].toLowerCase();
        if (prop.startsWith('--')) continue;
        if (prop !== 'transform' && prop !== 'opacity') { bad = true; break; }
      }
      if (bad) failed.push('motion.keyframes');
      searchFrom = close + 1;
    }
  }
  // Animated properties: transform/opacity only.
  const animRe = /(transition|animation)\s*:\s*([^;}{]+)/gi;
  while ((m = animRe.exec(src)) !== null) {
    const value = m[2];
    const names = value.split(/[\s,]+/).filter(Boolean);
    for (const name of names) {
      if ((r.motion.forbiddenAnimatedProperties || []).includes(name)) {
        failed.push('css_animated_property_forbidden:' + name);
      }
    }
    if (/blur|backdrop-filter/i.test(value)) failed.push('css_animated_property_forbidden:blur/backdrop-filter');
  }
  // Durations inside the motion budget. The 1500ms cap governs
  // one-shot motion (transitions, entrance animations). Infinite
  // ambient loops — the marquee band and the slow-zoom hero, both
  // named pure-CSS effects — are exempt by construction, pinned in
  // gateway-rules.json motion.ambientLoopExempt: a marquee cannot
  // scroll in 1.5s, and a slow zoom is slow by definition.
  const infiniteRanges = [];
  const animDeclRe = /animation\s*:\s*([^;}{]+)/gi;
  while ((m = animDeclRe.exec(src)) !== null) {
    if (/\binfinite\b/.test(m[1])) infiniteRanges.push([m.index, m.index + m[0].length]);
  }
  const inInfinite = (idx) => infiniteRanges.some(([a, b]) => idx >= a && idx < b);
  const durRe = /(\d+(?:\.\d+)?)\s*(ms|s)\b/g;
  while ((m = durRe.exec(src)) !== null) {
    if (inInfinite(m.index)) continue;
    const ms = m[2] === 's' ? Number(m[1]) * 1000 : Number(m[1]);
    if (ms > (r.motion.maxDurationMs || 1500)) failed.push('css_duration_over_budget:' + m[0]);
  }
  if (/\bblur\s*\(/i.test(src) || /backdrop-filter/i.test(src)) failed.push('css_blur_or_backdrop_filter');
  // Scoping: no selector may target a transactional surface.
  for (const sel of (r.forbiddenSelectors || [])) {
    if (src.includes(sel)) failed.push('css_forbidden_selector:' + sel);
  }
  if (/display\s*:\s*none/i.test(src)) {
    // display:none is only a failure when it can hide a price, a
    // button, or an input inside a transactional surface; the
    // forbidden-selector scan above already rejects any rule that
    // names those surfaces, so a bare display:none is a warning.
    warnings.push('css_display_none_present');
  }
  // RTL: physical left/right positioning is a warning, not a failure.
  if (/(^|[;{\s])left\s*:|(^|[;{\s])right\s*:/i.test(src)) warnings.push('css_physical_left_right');
  return { passed: failed.length === 0, failed, warnings };
}

/* --- Check 6: data-needs naming ---------------------------------- */
function checkDataNeeds(manifest, rules) {
  const r = rulesOf(rules);
  const failed = [];
  const needs = Array.isArray(manifest && manifest.dataNeeds) ? manifest.dataNeeds : [];
  for (const n of needs) {
    if (!r.dataNeeds.includes(n)) failed.push('dataNeed_unknown:' + n);
  }
  return { passed: failed.length === 0, failed };
}

/* --- tokens.json required ---------------------------------------- */
function checkTokens(files) {
  const failed = [];
  if (!files || typeof files['tokens.json'] !== 'string') {
    failed.push('tokens_missing');
    return { passed: false, failed };
  }
  let tokens = null;
  try { tokens = JSON.parse(files['tokens.json']); } catch (_) { failed.push('tokens_unparsable'); }
  if (tokens && (typeof tokens !== 'object' || typeof tokens.light !== 'object')) {
    failed.push('tokens_light_missing');
  }
  return { passed: failed.length === 0, failed };
}

/* --- fonts: declared origins on the allow-list ------------------- */
function checkFonts(manifest, rules) {
  const r = rulesOf(rules);
  const failed = [];
  const fonts = Array.isArray(manifest && manifest.fonts) ? manifest.fonts : [];
  for (const f of fonts) {
    const origin = (f && f.origin) || 'self';
    if (!r.fontOrigins.includes(origin)) failed.push('font_origin_not_allowed:' + origin);
  }
  return { passed: failed.length === 0, failed };
}

/* Full fast check. `files` is path -> text for every bundle file
 * EXCEPT preview.png. `opts`: { pointerTemplateId, pointerVersion,
 * expectedHash, shellVersion, rules, checkHash (default true) }.
 * Hash verification is async, so this function is async. */
async function validateBundle(files, manifest, opts) {
  const o = opts || {};
  const r = rulesOf(o.rules);
  const failed = [];
  const warnings = [];
  const checks = {};
  checks.identity = checkIdentity(manifest, { ...o, rules: r });
  checks.requiredSections = checkRequiredSections(manifest, files);
  checks.noJavaScript = checkNoJavaScript(files, r);
  // Classic wrap: the styles.css file is the trusted shell
  // stylesheet, not bundle CSS — the motion budget does not apply.
  const declaredFontOrigins = Array.isArray(manifest && manifest.fonts)
    ? manifest.fonts.map((f) => f && f.origin).filter(Boolean) : [];
  checks.motion = isClassicWrap(files)
    ? { passed: true, failed: [], warnings: ['classic_wrap_css_skipped'] }
    : checkCss((files && files['styles.css']) || '', r, { declaredFontOrigins });
  checks.dataNeeds = checkDataNeeds(manifest, r);
  checks.tokens = checkTokens(files);
  checks.fonts = checkFonts(manifest, r);
  for (const [name, c] of Object.entries(checks)) {
    failed.push(...c.failed.map((f) => name + ':' + f));
    if (c.warnings) warnings.push(...c.warnings.map((w) => name + ':' + w));
  }
  if (o.checkHash !== false) {
    const hash = await verifyBundleHash(files, o.expectedHash || (manifest && manifest.bundleHash), r);
    checks.hash = hash;
    if (!hash.passed) failed.push('hash:' + (hash.reason || 'hash_mismatch'));
  }
  return { passed: failed.length === 0, failed, warnings, checks };
}

/* Synchronous structural validation only (no hash) — for use where
 * the hash is verified separately. */
function validateBundleSync(files, manifest, opts) {
  const o = opts || {};
  const r = rulesOf(o.rules);
  const failed = [];
  const warnings = [];
  const checks = {};
  checks.identity = checkIdentity(manifest, { ...o, rules: r });
  checks.requiredSections = checkRequiredSections(manifest, files);
  checks.noJavaScript = checkNoJavaScript(files, r);
  const declaredFontOrigins = Array.isArray(manifest && manifest.fonts)
    ? manifest.fonts.map((f) => f && f.origin).filter(Boolean) : [];
  checks.motion = isClassicWrap(files)
    ? { passed: true, failed: [], warnings: ['classic_wrap_css_skipped'] }
    : checkCss((files && files['styles.css']) || '', r, { declaredFontOrigins });
  checks.dataNeeds = checkDataNeeds(manifest, r);
  checks.tokens = checkTokens(files);
  checks.fonts = checkFonts(manifest, r);
  for (const [name, c] of Object.entries(checks)) {
    failed.push(...c.failed.map((f) => name + ':' + f));
    if (c.warnings) warnings.push(...c.warnings.map((w) => name + ':' + w));
  }
  return { passed: failed.length === 0, failed, warnings, checks };
}

const BundleGateway = {
  GATEWAY_RULES,
  isClassicWrap,
  manifestBytesForHash,
  canonicalJsonString,
  compareSemver,
  resolvePointer,
  canonicalManifestString,
  computeBundleHash,
  verifyBundleHash,
  checkIdentity,
  checkRequiredSections,
  checkNoJavaScript,
  checkCss,
  checkDataNeeds,
  checkTokens,
  checkFonts,
  validateBundle,
  validateBundleSync,
};

if (typeof module !== 'undefined' && module.exports) {
  module.exports = BundleGateway;
}
if (typeof window !== 'undefined') {
  window.BundleGateway = BundleGateway;
}
