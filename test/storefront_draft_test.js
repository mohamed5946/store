/* Storefront draft / journey / out-of-stock pure-logic tests.
 * Extracts the PURE-HELPERS block from storefront/app.js (between the
 * PURE-HELPERS-BEGIN / PURE-HELPERS-END markers) and runs it in a
 * sandbox — the block is dependency-free by design, so no DOM or
 * Firebase is needed. Run: node --test test/storefront_draft_test.js
 */
'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const appJs = fs.readFileSync(
  path.join(__dirname, '..', 'storefront', 'app.js'),
  'utf8',
);
const blockStart = appJs.indexOf('/* PURE-HELPERS-BEGIN');
const blockEnd = appJs.indexOf('/* PURE-HELPERS-END */');
assert.ok(blockStart >= 0 && blockEnd > blockStart, 'PURE-HELPERS block must exist in app.js');
const block = appJs.slice(blockStart, blockEnd);
assert.ok(block.length > 100, 'PURE-HELPERS block must be non-trivial');

const moduleSandbox = { exports: {} };
new Function('module', 'exports', block)(moduleSandbox, moduleSandbox.exports);
const H = moduleSandbox.exports;

test('governorate list: all 27 present with stable ids', () => {
  assert.equal(H.GOVERNORATES_27.length, 27);
  const ids = new Set(H.GOVERNORATES_27.map((g) => g.id));
  assert.equal(ids.size, 27);
  assert.ok(ids.has('cairo') && ids.has('giza') && ids.has('south-sinai'));
});

test('Egyptian mobile: valid prefixes 010/011/012/015, 11 digits', () => {
  for (const n of ['01001234567', '01112345678', '01223456789', '01555555555']) {
    assert.equal(H.isValidEgyptianMobile(n), true, n);
  }
  assert.equal(H.isValidEgyptianMobile('01901234567'), false); // bad prefix
  assert.equal(H.isValidEgyptianMobile('0100123456'), false); // 10 digits
  assert.equal(H.isValidEgyptianMobile('010012345678'), false); // 12 digits
  assert.equal(H.isValidEgyptianMobile(''), false);
  assert.equal(H.isValidEgyptianMobile('0100 123 4567'), true); // spaces tolerated
});

test('Egyptian mobile: +20 / 20 country code folds to 01…', () => {
  assert.equal(H.normalizeEgyptianMobile('+201001234567'), '01001234567');
  assert.equal(H.normalizeEgyptianMobile('201001234567'), '01001234567');
  assert.equal(H.isValidEgyptianMobile('+201001234567'), true);
  assert.equal(H.normalizeEgyptianMobile('01001234567'), '01001234567');
});

test('dwell bands: 9s <10s, 10s and 60s 10-60s, 61s >60s', () => {
  assert.equal(H.dwellBand(0), '<10s');
  assert.equal(H.dwellBand(9), '<10s');
  assert.equal(H.dwellBand(10), '10-60s');
  assert.equal(H.dwellBand(60), '10-60s');
  assert.equal(H.dwellBand(61), '>60s');
  assert.equal(H.dwellBand(3600), '>60s');
});

test('line availability: ok / out / short with clamped available', () => {
  assert.deepEqual(H.lineAvailability(5, 3), { state: 'ok', availableQty: 5 });
  assert.deepEqual(H.lineAvailability(3, 3), { state: 'ok', availableQty: 3 });
  assert.deepEqual(H.lineAvailability(0, 1), { state: 'out', availableQty: 0 });
  assert.deepEqual(H.lineAvailability(-4, 1), { state: 'out', availableQty: 0 });
  assert.deepEqual(H.lineAvailability(2, 5), { state: 'short', availableQty: 2 });
});

test('draft triage score: 25 per filled part, 100 when complete', () => {
  assert.equal(H.draftTriageScore({}), 0);
  assert.equal(H.draftTriageScore({ name: 'أحمد' }), 25);
  assert.equal(H.draftTriageScore({ name: 'أحمد', phone: '01001234567' }), 50);
  assert.equal(
    H.draftTriageScore({ name: 'أ', phone: '01001234567', cart: 2, address: 'x' }),
    100,
  );
  assert.equal(H.draftTriageScore({ cart: 1 }), 25); // cart-only draft scores 25
});

test('governorate fallback: missing doc -> full 27; zero active -> not set up', () => {
  const missing = H.governorateFallback(null);
  assert.equal(missing.entries.length, 27);
  assert.equal(missing.fromFallback, true);
  assert.equal(missing.notSetUp, false);

  const partial = H.governorateFallback({
    entries: [
      { id: 'cairo', name: 'القاهرة', active: true },
      { id: 'giza', name: 'الجيزة', active: false },
      { id: 'alexandria', name: 'الإسكندرية', active: true },
      { id: 'broken', active: true }, // no name -> dropped
    ],
  });
  assert.deepEqual(partial.entries.map((g) => g.id), ['cairo', 'alexandria']);
  assert.equal(partial.notSetUp, false);

  const none = H.governorateFallback({
    entries: [{ id: 'cairo', name: 'القاهرة', active: false }],
  });
  assert.deepEqual(none.entries, []);
  assert.equal(none.notSetUp, true);

  const empty = H.governorateFallback({ entries: [] });
  assert.equal(empty.notSetUp, true);
});

test('draft sync gate: throttle under 30s, cap at 20 saves, free otherwise', () => {
  const now = 1_000_000;
  assert.equal(H.draftSyncBlockReason({ nowMs: now, lastSyncAtMs: null, savesUsed: 0 }), null);
  assert.equal(
    H.draftSyncBlockReason({ nowMs: now, lastSyncAtMs: now - 10_000, savesUsed: 3 }),
    'throttle',
  );
  assert.equal(
    H.draftSyncBlockReason({ nowMs: now, lastSyncAtMs: now - 29_999, savesUsed: 3 }),
    'throttle',
  );
  assert.equal(
    H.draftSyncBlockReason({ nowMs: now, lastSyncAtMs: now - 30_000, savesUsed: 3 }),
    null,
  );
  assert.equal(
    H.draftSyncBlockReason({ nowMs: now, lastSyncAtMs: now - 60_000, savesUsed: 19 }),
    null,
  );
  // 21st save is skipped: savesUsed 20 blocks even with a cold throttle.
  assert.equal(
    H.draftSyncBlockReason({ nowMs: now, lastSyncAtMs: now - 60_000, savesUsed: 20 }),
    'cap',
  );
  assert.equal(
    H.draftSyncBlockReason({ nowMs: now, lastSyncAtMs: now - 1_000, savesUsed: 20 }),
    'cap',
  );
});

test('out-of-stock cart gating: any out/short line blocks checkout before details', () => {
  assert.equal(H.cartHasUnorderableLine([]), false);
  assert.equal(H.cartHasUnorderableLine(['ok', 'ok']), false);
  assert.equal(H.cartHasUnorderableLine(['ok', 'out']), true);
  assert.equal(H.cartHasUnorderableLine(['short']), true);
  assert.equal(H.cartHasUnorderableLine(['out', 'short']), true);
  // A short line (some stock, less than qty) still blocks: the
  // customer must lower the quantity first.
  const lines = [
    H.lineAvailability(10, 1),
    H.lineAvailability(0, 2),
  ];
  assert.equal(H.cartHasUnorderableLine(lines.map((l) => l.state)), true);
});
