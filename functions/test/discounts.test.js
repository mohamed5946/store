/* Phase 2 discount tests (design doc file 33: T4 forged discount,
 * T18 discount consumption, rate limits Decisions 12–14).
 *
 * Runs the REAL functions/lib code (createOrderTx + the validation
 * helpers) against the in-memory fake Firestore
 * (functions/test/fake-firestore.js). No network. Run from the repo
 * root:
 *   node --test functions/test/discounts.test.js
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');

const { createFakeFirestore } = require('./fake-firestore');
const { createOrderTx } = require('../lib/orders');
const {
  checkRateLimit, countFailedDiscountAttempt, discountBlocked, dedupeItems,
} = require('../lib/validation');

const NOW = 1793000000000; // fixed "now" (ms)

function seedStore(db) {
  db.seed('products/prod-1', { name: 'سماعة بلوتوث', price: 500, categoryId: 'cat-1', inStock: true });
  db.seed('products/prod-2', { name: 'شاحن سريع', price: 250, categoryId: 'cat-1', inStock: true });
  db.seed('inventory/prod-1', { productId: 'prod-1', stock: 5, reserved: 0, minStock: 5, costPrice: 300 });
  db.seed('inventory/prod-2', { productId: 'prod-2', stock: 3, reserved: 0, minStock: 5, costPrice: 150 });
}

function placeOrder(db, overrides = {}) {
  return createOrderTx(db, {
    clientOrderId: 'order-1',
    items: [{ productId: 'prod-1', qty: 2 }, { productId: 'prod-2', qty: 1 }],
    discountCode: null,
    customer: { name: 'اختبار', phone: '01012345678', address: 'عنوان اختبار' },
    source: 'storefront',
    createdBy: null,
    shippingCompanyId: null,
    notes: null,
    seenPrices: { 'prod-1': 500, 'prod-2': 250 },
    seenTotal: 1250,
    serverTimestamp: () => NOW,
    ...overrides,
  });
}

/* ---------- T4: a forged discount code is impossible ---------- */

test('Phase 2 (T4): a code with no database record is refused, nothing is written', async () => {
  const db = createFakeFirestore();
  seedStore(db);

  await assert.rejects(
    placeOrder(db, { discountCode: 'FAKE99' }),
    (e) => e.code === 'DISCOUNT_INVALID',
  );
  assert.equal(db.all('orders/').length, 0);
  assert.equal(db.all('audit/').length, 0);
  assert.equal(db.all('inventory/').find((d) => d.id === 'prod-1').data.reserved, 0);
});

test('Phase 2 (T4): client-supplied discount fields are ignored — the total always comes from the database', async () => {
  const db = createFakeFirestore();
  seedStore(db);

  // A forged client tries to smuggle its own discount in: extra fields
  // the function never reads. The order must still total 1250 with no
  // discount applied.
  const { order } = await placeOrder(db, {
    discountPercent: 90, discountAmount: 1125, total: 125,
  });
  assert.equal(order.discountPercent, null);
  assert.equal(order.discountAmount, 0);
  assert.equal(order.total, 1250);
  assert.equal(order.discountCode, null);
});

/* ---------- T18: discount consumption rules ---------- */

test('Phase 2 (T18): an expired code is refused and is NOT claimed', async () => {
  const db = createFakeFirestore();
  seedStore(db);
  db.seed('discounts/OLD10', { percent: 10, active: true, usedBy: null, expiresAt: NOW - 1000 });

  await assert.rejects(
    placeOrder(db, { discountCode: 'OLD10' }),
    (e) => e.code === 'DISCOUNT_INVALID',
  );
  assert.equal(db.all('orders/').length, 0);
  assert.equal(db.all('discounts/').find((d) => d.id === 'OLD10').data.usedBy, null);
});

test('Phase 2 (T18): an inactive code is refused', async () => {
  const db = createFakeFirestore();
  seedStore(db);
  db.seed('discounts/OFF10', { percent: 10, active: false, usedBy: null, expiresAt: null });

  await assert.rejects(
    placeOrder(db, { discountCode: 'OFF10' }),
    (e) => e.code === 'DISCOUNT_INVALID',
  );
  assert.equal(db.all('orders/').length, 0);
});

test('Phase 2 (T18): a code whose percent is out of range (0 or 101) is refused', async () => {
  const db = createFakeFirestore();
  seedStore(db);
  db.seed('discounts/ZERO', { percent: 0, active: true, usedBy: null, expiresAt: null });
  db.seed('discounts/HUGE', { percent: 101, active: true, usedBy: null, expiresAt: null });

  await assert.rejects(placeOrder(db, { discountCode: 'ZERO' }), (e) => e.code === 'DISCOUNT_INVALID');
  await assert.rejects(placeOrder(db, { discountCode: 'HUGE' }), (e) => e.code === 'DISCOUNT_INVALID');
  assert.equal(db.all('orders/').length, 0);
});

test('Phase 2 (T18): a code with surrounding whitespace is trimmed and works', async () => {
  const db = createFakeFirestore();
  seedStore(db);
  db.seed('discounts/SAVE10', { percent: 10, active: true, usedBy: null, expiresAt: null });

  const { order } = await placeOrder(db, { discountCode: '  SAVE10  ' });
  assert.equal(order.discountCode, 'SAVE10');
  assert.equal(order.total, 1125);
});

test('Phase 2 (T18): a 100% code zeroes the total', async () => {
  const db = createFakeFirestore();
  seedStore(db);
  db.seed('discounts/FREE100', { percent: 100, active: true, usedBy: null, expiresAt: null });

  const { order } = await placeOrder(db, { discountCode: 'FREE100' });
  assert.equal(order.discountPercent, 100);
  assert.equal(order.discountAmount, 1250);
  assert.equal(order.total, 0);
});

/* ---------- rate limits (Decisions 12–14) ---------- */

test('Phase 2: 10 failed discount attempts in 15 minutes block the key for 15 minutes', async () => {
  const db = createFakeFirestore();
  const key = 'ip:hash123:discount';

  for (let i = 0; i < 9; i++) {
    await countFailedDiscountAttempt(db, { key, now: NOW + i * 1000 });
    assert.deepEqual(await discountBlocked(db, { key, now: NOW + i * 1000 }), { blocked: false });
  }
  // The 10th failed attempt sets the block.
  await countFailedDiscountAttempt(db, { key, now: NOW + 9 * 1000 });
  const blocked = await discountBlocked(db, { key, now: NOW + 9 * 1000 });
  assert.equal(blocked.blocked, true);
  assert.equal(blocked.retryAfterMs, 15 * 60 * 1000);

  // Still blocked 14 minutes later; free after the 15-minute block.
  assert.equal((await discountBlocked(db, { key, now: NOW + 14 * 60 * 1000 })).blocked, true);
  assert.deepEqual(await discountBlocked(db, { key, now: NOW + 16 * 60 * 1000 }), { blocked: false });
});

test('Phase 2: placeOrder allows 20 calls in 15 minutes, then blocks', async () => {
  const db = createFakeFirestore();
  const key = 'ip:hash456';

  for (let i = 0; i < 20; i++) {
    const res = await checkRateLimit(db, { key, kind: 'placeOrder', now: NOW + i * 1000 });
    assert.equal(res.allowed, true, `call ${i + 1} must be allowed`);
  }
  const denied = await checkRateLimit(db, { key, kind: 'placeOrder', now: NOW + 20 * 1000 });
  assert.equal(denied.allowed, false);
  assert.equal(denied.retryAfterMs, 15 * 60 * 1000);

  // A different key is unaffected.
  assert.equal((await checkRateLimit(db, { key: 'ip:other', kind: 'placeOrder', now: NOW })).allowed, true);
  // And the window resets after 15 minutes.
  assert.equal((await checkRateLimit(db, { key, kind: 'placeOrder', now: NOW + 16 * 60 * 1000 })).allowed, true);
});

/* ---------- shared input validation (the discount total depends on it) ---------- */

test('Phase 2 (T22): duplicate lines for one product merge and sum quantities', async () => {
  const db = createFakeFirestore();
  seedStore(db);

  const { order } = await placeOrder(db, {
    items: [
      { productId: 'prod-1', qty: 1 },
      { productId: 'prod-1', qty: 1 },
      { productId: 'prod-2', qty: 1 },
    ],
  });
  assert.deepEqual(order.items, [
    { productId: 'prod-1', name: 'سماعة بلوتوث', price: 500, qty: 2 },
    { productId: 'prod-2', name: 'شاحن سريع', price: 250, qty: 1 },
  ]);
  assert.equal(order.total, 1250);
  assert.equal(db.all('inventory/').find((d) => d.id === 'prod-1').data.reserved, 2);
});

test('Phase 2 (T22): dedupe keeps first-seen order', () => {
  assert.deepEqual(dedupeItems([
    { productId: 'b', qty: 1 },
    { productId: 'a', qty: 2 },
    { productId: 'b', qty: 3 },
  ]), [
    { productId: 'b', qty: 4 },
    { productId: 'a', qty: 2 },
  ]);
});

test('Phase 2: a line quantity above 20 is refused', async () => {
  const db = createFakeFirestore();
  seedStore(db);

  await assert.rejects(
    placeOrder(db, { items: [{ productId: 'prod-1', qty: 21 }], seenPrices: { 'prod-1': 500 }, seenTotal: 10500 }),
    (e) => e.code === 'INVALID_INPUT',
  );
  assert.equal(db.all('orders/').length, 0);
});
