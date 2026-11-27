/* Storefront templates shell — gateway + loader guards.
 * Runs with zero DOM: bundle-gateway.js is pure; the app.js /
 * index.html / firebase.json checks are static string guards.
 * Usage: node --test test/storefront_templates_test.js
 *
 * Conventions the fixture must follow (from gateway-rules.json and
 * bundle-gateway.js, NOT from the spec prose):
 * - manifest.sections is an array of section NAME strings;
 *   section files live at sections/{name}.html in the bundle.
 * - The brand requirement is an element carrying
 *   data-section="brand" (not a brand-name slot).
 * - data-behaviour is NOT an allowed attribute: bundles enable
 *   behaviours by naming them in the manifest only; the shell
 *   creates/ticks the strip itself.
 * - validateBundle returns failed as STRINGS "check:detail".
 * - computeBundleHash(files) is async; files includes the raw
 *   'manifest.json' text (hashed in its CANONICAL form: parsed,
 *   bundleHash removed, keys sorted, no whitespace — same for
 *   tokens.json; sections + styles.css raw).
 * - verifyBundleHash(files, hash) returns {passed, actual, reason}.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const gw = require('../storefront/bundle-gateway.js');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (rel) => readFileSync(path.join(root, rel), 'utf8');
const readBuf = (rel) => readFileSync(path.join(root, rel));
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');

const GATEWAY_RULES = JSON.parse(read('storefront/templates/gateway-rules.json'));
const APP = read('storefront/app.js');
const INDEX = read('storefront/index.html');
const FIREBASE = read('firebase.json');

/* A minimal VALID bundle fixture: every slot/action the allow-list
 * permits, so a regression in the rules file or the gateway fails
 * loudly here instead of in the field. The manifest is serialised
 * pretty (2-space, trailing newline) exactly as authored bundles
 * are — the hash input is the manifest's CANONICAL form (parsed,
 * bundleHash removed, keys sorted, no whitespace), so the fixture
 * hash does not depend on the authoring format. */
async function validFixture() {
  const manifest = {
    id: 'bazaar', version: '1.0.0', shellMinVersion: '1.0.0',
    bundleHash: '', motion: 'lively', dark: 'variant',
    behaviours: ['countdown-strip', 'feed', 'grid-list-toggle', 'filter-chips', 'comparison-strip', 'hero-crossfade'],
    sections: ['hero', 'marquee', 'categories', 'featured', 'offers', 'products', 'delivery', 'contact', 'about'],
    dataNeeds: ['oldPrice', 'specs', 'deliveryFee'],
    cartLayout: 'drawer', modalLayout: 'default',
    fonts: [{ family: 'Tajawal', src: '/fonts/tajawal.woff2' }],
    previewImageUrl: '/templates/bazaar/1.0.0/preview.png',
  };
  const files = {
    'sections/hero.html': '<section data-section="hero"><div data-section="brand"><span data-slot="brand-name">S</span><span data-slot="brand-tagline">t</span></div>'
      + '<img data-slot="brand-logo" alt=""><span data-slot="whatsapp-number"></span><div data-slot="cod-message"></div>'
      + '<div data-slot="featured-spot"><span data-slot="product-name"></span><span data-slot="product-price"></span></div></section>',
    'sections/marquee.html': '<section data-section="marquee"><div data-slot="promo-banner">x</div></section>',
    'sections/categories.html': '<section data-section="categories"><button data-action="select-category"><img data-slot="category-image" alt=""><span data-slot="category-name"></span></button></section>',
    'sections/featured.html': '<section data-section="featured"><div data-slot="featured-spot"><span data-slot="product-name"></span><span data-slot="product-price"></span></div></section>',
    'sections/offers.html': '<section data-section="offers"><div data-slot="product-card"><span data-slot="product-name"></span><span data-slot="product-price"></span><span data-slot="product-old-price"></span><img data-slot="product-image" alt=""></div></section>',
    'sections/products.html': '<section data-section="products"><div data-slot="product-card"><span data-slot="product-name"></span><span data-slot="product-price"></span><span data-slot="product-old-price"></span><img data-slot="product-image" alt=""><button data-action="add-to-cart">+</button><button data-action="open-product">v</button></div><button data-action="toggle-grid-list">t</button><button data-action="filter-chip">f</button></section>',
    'sections/delivery.html': '<section data-section="delivery"><span data-slot="delivery-fee"></span><span data-slot="whatsapp-number"></span><div data-slot="cod-message"></div></section>',
    'sections/contact.html': '<section data-section="contact"><span data-slot="whatsapp-number"></span><div data-slot="cod-message"></div><a data-action="open-cart">c</a><button data-action="search">s</button><button data-action="select-category">cat</button><button data-action="toggle-compare">cmp</button></section>',
    'sections/about.html': '<section data-section="about"><span data-slot="brand-name"></span><span data-slot="brand-tagline"></span></section>',
    'styles.css': '.x { color: red; transition: opacity 300ms; }',
    'tokens.json': JSON.stringify({
      light: { bg: '#fff', bg2: '#eee', surface: '#fff', surfaceStrong: '#fff', border: '#000', text: '#111', textSoft: '#555', accent: '#333', accent2: '#666', warm: '#999', radius: '24px', font: 'Tajawal' },
      dark: 'variant',
    }),
  };
  const hash = await gw.computeBundleHash({ ...files, 'manifest.json': JSON.stringify(manifest, null, 2) + '\n' });
  manifest.bundleHash = hash;
  files['manifest.json'] = JSON.stringify(manifest, null, 2) + '\n';
  return { manifest, files, hash };
}

test('gateway: embedded rules agree with gateway-rules.json (single source of truth)', () => {
  assert.deepEqual(gw.GATEWAY_RULES, GATEWAY_RULES);
});

test('gateway: valid fixture bundle passes every check', async () => {
  const { manifest, files } = await validFixture();
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, true, JSON.stringify(r.failed));
  assert.deepEqual(r.failed, []);
});

test('gateway: unknown slot fails with a named failure', async () => {
  const { manifest, files } = await validFixture();
  files['sections/hero.html'] = files['sections/hero.html'].replace('brand-name', 'brand-slogan');
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('noJavaScript:') && f.includes('brand-slogan')), JSON.stringify(r.failed));
});

test('gateway: unknown action fails with a named failure', async () => {
  const { manifest, files } = await validFixture();
  files['sections/products.html'] = files['sections/products.html'].replace('add-to-cart', 'buy-now');
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('buy-now')), JSON.stringify(r.failed));
});

test('gateway: <script> tag fails no-JavaScript', async () => {
  const { manifest, files } = await validFixture();
  files['sections/about.html'] += '<script>alert(1)</script>';
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('noJavaScript:') && f.includes('script')), JSON.stringify(r.failed));
});

test('gateway: on* attribute fails no-JavaScript', async () => {
  const { manifest, files } = await validFixture();
  files['sections/about.html'] = files['sections/about.html'].replace('<section', '<section onclick="x()"');
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('noJavaScript:')), JSON.stringify(r.failed));
});

test('gateway: missing products section fails required-sections', async () => {
  const { manifest, files } = await validFixture();
  manifest.sections = manifest.sections.filter((s) => s !== 'products');
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('requiredSections:') && f.includes('products')), JSON.stringify(r.failed));
});

test('gateway: missing brand slot fails required-sections', async () => {
  const { manifest, files } = await validFixture();
  files['sections/hero.html'] = files['sections/hero.html'].replace(/<div data-section="brand">.*?<\/div>/, '');
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('requiredSections:brand_slot_missing')), JSON.stringify(r.failed));
});

test('gateway: non-whitelisted behaviour fails', async () => {
  const { manifest, files } = await validFixture();
  manifest.behaviours = ['countdown-strip', 'confetti-cannon'];
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('confetti-cannon')), JSON.stringify(r.failed));
});

test('gateway: unknown dataNeed fails', async () => {
  const { manifest, files } = await validFixture();
  manifest.dataNeeds = ['oldPrice', 'customerEmails'];
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('dataNeeds:')), JSON.stringify(r.failed));
});

test('gateway: missing tokens.json fails', async () => {
  const { manifest, files } = await validFixture();
  delete files['tokens.json'];
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('tokens:')), JSON.stringify(r.failed));
});

test('gateway: forbidden selector #cartDrawer fails CSS check', async () => {
  const { manifest, files } = await validFixture();
  files['styles.css'] = '#cartDrawer { display: none; }';
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('motion:')), JSON.stringify(r.failed));
});

test('gateway: width animation fails CSS motion budget', async () => {
  const { manifest, files } = await validFixture();
  files['styles.css'] = '.x { transition: width 300ms; }';
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('motion:')), JSON.stringify(r.failed));
});

test('gateway: non-infinite 2000ms transition fails the 1500ms cap', async () => {
  const { manifest, files } = await validFixture();
  files['styles.css'] = '.x { transition: opacity 2000ms; }';
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('motion:')), JSON.stringify(r.failed));
});

test('gateway: font origin not allowed fails', async () => {
  const { manifest, files } = await validFixture();
  files['styles.css'] = "@import url('https://evil.example/font.css');";
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('motion:')), JSON.stringify(r.failed));
});

test('gateway: hash round-trip passes, tampered file fails', async () => {
  const { manifest, files, hash } = await validFixture();
  assert.equal((await gw.verifyBundleHash(files, hash)).passed, true);
  files['styles.css'] = '.x { color: blue; }';
  const after = await gw.verifyBundleHash(files, hash);
  assert.equal(after.passed, false);
  assert.equal(after.reason, 'hash_mismatch');
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, false);
  assert.ok(r.failed.some((f) => f.includes('hash:')), JSON.stringify(r.failed));
  assert.equal(hash.length, 64);
});

test('gateway: manifestBytesForHash is the canonical form (decision 1)', async () => {
  // The hash input is the manifest parsed, bundleHash removed,
  // keys sorted recursively, no whitespace — so a pretty-printed
  // manifest, its compact re-serialisation, and a key-reordered
  // copy all hash identically (the old raw-bytes reading failed
  // every bundle whose authoring format differed).
  const dir = 'storefront/templates/bazaar/1.0.0';
  const bazaarManifest = read(dir + '/manifest.json');
  const stored = JSON.parse(bazaarManifest).bundleHash;
  const files = { 'manifest.json': bazaarManifest };
  for (const f of ['styles.css', 'tokens.json']) files[f] = read(`${dir}/${f}`);
  // sections are read from disk the same way the loader does
  const manifest = JSON.parse(bazaarManifest);
  for (const s of manifest.sections) files[`sections/${s}.html`] = read(`${dir}/sections/${s}.html`);
  assert.equal(await gw.computeBundleHash(files), stored);
  // Formatting independence: compact + key-reordered manifest text
  // canonicalises to the same bytes, hence the same hash.
  const reordered = JSON.stringify(
    Object.fromEntries(Object.entries(manifest).reverse()),
  );
  assert.equal(gw.manifestBytesForHash(bazaarManifest), gw.manifestBytesForHash(reordered));
  assert.equal(gw.manifestBytesForHash(bazaarManifest), gw.canonicalManifestString(manifest));
});

test('gateway: resolvePointer is tolerant (missing version/hash = classic v1)', () => {
  assert.deepEqual(gw.resolvePointer({}), { templateId: 'classic', version: '1.0.0', bundleHash: null, previousTemplateId: null, isLegacy: true });
  assert.deepEqual(gw.resolvePointer(null), { templateId: 'classic', version: '1.0.0', bundleHash: null, previousTemplateId: null, isLegacy: true });
  const full = gw.resolvePointer({ templateId: 'bazaar', bundleVersion: '1.0.0', bundleHash: 'abc', previousTemplateId: 'classic' });
  assert.equal(full.templateId, 'bazaar');
  assert.equal(full.version, '1.0.0');
  assert.equal(full.bundleHash, 'abc');
  assert.equal(full.isLegacy, false);
});

test('gateway: compareSemver orders versions', () => {
  assert.equal(gw.compareSemver('1.0.0', '1.0.0'), 0);
  assert.equal(gw.compareSemver('1.0.1', '1.0.0'), 1);
  assert.equal(gw.compareSemver('0.9.9', '1.0.0'), -1);
  assert.equal(gw.compareSemver('1.10.0', '1.9.0'), 1);
});

test('gateway: classic bundle on disk validates (freeze + hash)', async () => {
  const dir = 'storefront/templates/classic/1.0.0';
  assert.ok(existsSync(path.join(root, dir, 'index.html')));
  assert.ok(existsSync(path.join(root, dir, 'styles.css')));
  assert.ok(existsSync(path.join(root, dir, 'classic.json')));
  assert.ok(existsSync(path.join(root, dir, 'manifest.json')));
  assert.ok(existsSync(path.join(root, dir, 'tokens.json')));
  assert.ok(existsSync(path.join(root, dir, 'preview.png')));
  // Freeze: bundle copies are byte-identical to the live files.
  assert.equal(sha256(readBuf(dir + '/index.html')), sha256(readBuf('storefront/index.html')));
  assert.equal(sha256(readBuf(dir + '/styles.css')), sha256(readBuf('storefront/styles.css')));
  assert.equal(sha256(readBuf(dir + '/classic.json')), sha256(readBuf('storefront/templates/classic.json')));
  const manifest = JSON.parse(read(dir + '/manifest.json'));
  const files = {
    'manifest.json': read(dir + '/manifest.json'),
    'index.html': read(dir + '/index.html'),
    'styles.css': read(dir + '/styles.css'),
    'classic.json': read(dir + '/classic.json'),
    'tokens.json': read(dir + '/tokens.json'),
  };
  const r = await gw.validateBundle(files, manifest);
  assert.equal(r.passed, true, JSON.stringify(r.failed));
  assert.equal(manifest.bundleHash, await gw.computeBundleHash(files));
});

test('shell: SHELL_VERSION 1.0.0 in app.js and data-shell-version on <html>', () => {
  assert.ok(APP.includes("const SHELL_VERSION = '1.0.0';"));
  assert.ok(INDEX.includes('data-shell-version="1.0.0"'));
});

test('shell: bundle-gateway.js loads before app.js in index.html', () => {
  const gwPos = INDEX.indexOf('bundle-gateway.js');
  const appPos = INDEX.indexOf('src="app.js"');
  assert.ok(gwPos > 0 && appPos > gwPos);
});

test('shell: all 9 section mount points present', () => {
  for (const m of ['hero', 'marquee', 'categories', 'featured', 'offers', 'products', 'delivery', 'contact', 'about']) {
    assert.ok(INDEX.includes(`data-mount="${m}"`), `missing mount ${m}`);
  }
});

test('shell: preview stamp slot present; D11 chip removed', () => {
  assert.ok(INDEX.includes('id="previewStamp"'));
  assert.ok(!INDEX.includes('★ 4.9'), 'D11 chip still present in index.html');
  assert.ok(!read('storefront/templates/classic/1.0.0/index.html').includes('★ 4.9'), 'D11 chip still present in classic bundle copy');
});

test('shell: preview dry-run guards present (no placeOrderTx in preview)', () => {
  assert.ok(APP.includes("if (isPreviewMode) return;"));
  assert.ok(APP.includes('preview-end-stamp'));
  assert.ok(APP.includes("showPreviewClosed"));
  assert.ok(APP.includes("previews"));
});

test('shell: preview mode never syncs a checkout draft (decision 10)', () => {
  // The guard must live inside syncDraftToServer itself — every
  // caller (field input timer, focusout, pagehide) funnels through
  // it, so one early return covers all of them.
  const body = APP.slice(APP.indexOf('async function syncDraftToServer()'));
  const guard = body.slice(0, body.indexOf('if (quotaCutoff'));
  assert.ok(guard.includes('if (isPreviewMode) return;'), 'no preview guard in syncDraftToServer');
});

test('shell: loader + observability guards present', () => {
  assert.ok(APP.includes('template_fallback'));
  assert.ok(APP.includes('render_blank_detected'));
  assert.ok(APP.includes('motion_downgraded'));
  assert.ok(APP.includes('sale_window_expired'));
  assert.ok(APP.includes('sale_window_missing'));
  assert.ok(APP.includes('template_preview_opened'));
  assert.ok(APP.includes('writeSessionDoc'));
  assert.ok(APP.includes('countTelemetry'));
  assert.ok(APP.includes('heartbeatIntervalMs'));
  assert.ok(APP.includes('serverTimeOffsetMs'));
  assert.ok(APP.includes('data-bundle-card'));
});

test('shell: reveal observer replays (no unobserve after first intersect)', () => {
  assert.ok(!APP.includes('revealObs.unobserve(el)'));
  assert.ok(APP.includes("classList.remove('in')"));
});

test('firebase.json: versioned bundle rule before legacy rule', () => {
  const v = FIREBASE.indexOf('/templates/*/*/**');
  const legacy = FIREBASE.indexOf('/templates/**');
  assert.ok(v > 0 && legacy > v, 'versioned rule must precede legacy rule');
  assert.ok(FIREBASE.includes('max-age=31536000, immutable'));
  assert.ok(FIREBASE.includes('max-age=60'));
});
