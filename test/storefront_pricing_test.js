/* Storefront pricing pure-logic tests (fee-default-free 2026-11-27).
 * Extracts the PRICING-HELPER block from storefront/app.js (between the
 * PRICING-HELPER-BEGIN / PRICING-HELPER-END markers) and runs it in a
 * sandbox — the block is dependency-free except for `money` (defined
 * just above the block in app.js), which the harness shims. Run:
 * node --test test/storefront_pricing_test.js
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
const blockStart = appJs.indexOf('/* PRICING-HELPER-BEGIN');
const blockEnd = appJs.indexOf('/* PRICING-HELPER-END */');
assert.ok(blockStart >= 0 && blockEnd > blockStart, 'PRICING-HELPER block must exist in app.js');
const block = appJs.slice(blockStart, blockEnd);
assert.ok(block.length > 100, 'PRICING-HELPER block must be non-trivial');

// `money` lives just above the block in app.js; the harness shims it
// so feeLineText's priced branch can run in the sandbox.
const shim = 'const money = (n) => `${Number(n || 0)} EGP`;\n';
const moduleSandbox = { exports: {} };
new Function('module', 'exports', shim + block + '\n;module.exports = { computePricing, feeLineText, salePercent, maxDiscountPct, roundHalfUp, isOnSale };')(moduleSandbox, moduleSandbox.exports);
const H = moduleSandbox.exports;

const oneLine = [{ price: 300, basePrice: 500, qty: 1 }]; // subtotal 300, saving 200
const twoLines = [{ price: 300, basePrice: 500, qty: 2 }]; // subtotal 600, saving 400

test('missing fee means FREE: computePricing with deliveryFee null yields fee 0 and amountDue == total', () => {
  const pr = H.computePricing(oneLine, { deliveryFee: null, freeDeliveryThreshold: null });
  assert.equal(pr.feeUnset, true);
  assert.equal(pr.deliveryFee, 0);
  assert.equal(pr.amountDue, 300);
  assert.equal(pr.insteadOf, 500);
});

test('missing fee + threshold: a missing fee is free even when the total is below the threshold', () => {
  const pr = H.computePricing(oneLine, { deliveryFee: null, freeDeliveryThreshold: 500 });
  assert.equal(pr.deliveryFee, 0);
  assert.equal(pr.amountDue, 300);
});

test('threshold waiver: fee 30 waived to 0 when total >= threshold', () => {
  const pr = H.computePricing(twoLines, { deliveryFee: 30, freeDeliveryThreshold: 500 });
  assert.equal(pr.feeWaived, true);
  assert.equal(pr.deliveryFee, 0);
  assert.equal(pr.amountDue, 600);
});

test('threshold not met: fee 30 kept when total < threshold', () => {
  const pr = H.computePricing(oneLine, { deliveryFee: 30, freeDeliveryThreshold: 500 });
  assert.equal(pr.feeWaived, false);
  assert.equal(pr.deliveryFee, 30);
  assert.equal(pr.amountDue, 330);
});

test('feeLineText: missing fee (null) reads free, exactly as fee 0', () => {
  assert.equal(H.feeLineText(null, 'browse'), 'التوصيل مجاني');
  assert.equal(H.feeLineText(null, 'review'), 'الشحن مجانًا');
  assert.equal(H.feeLineText(0, 'browse'), 'التوصيل مجاني');
  assert.equal(H.feeLineText(0, 'review'), 'الشحن مجانًا');
});

test('feeLineText: a set fee still renders the amount', () => {
  assert.equal(H.feeLineText(30, 'browse'), 'التوصيل: 30 EGP');
  assert.equal(H.feeLineText(30, 'review'), 'الشحن: 30 EGP');
});

// Source guards: the cart render, checkout gating and order
// transaction are DOM + Firestore code the node suite cannot execute
// (no DOM harness in this repo), so these pin the removal at the
// source level — the behaviour they guard is: cart shows
// «التوصيل مجاني», checkout NOT disabled by a missing fee, no
// FEE_UNSET throw. The pure logic behind all three is covered above.
test('source guard: no FEE_UNSET throw and no fee-based checkout block remain in app.js', () => {
  assert.ok(!appJs.includes("throw new OrderError('FEE_UNSET'"), 'FEE_UNSET throw must be gone');
  assert.ok(!appJs.includes('feeIsSet()'), 'feeIsSet() must be gone (no caller may block on the fee)');
  assert.ok(!appJs.includes('رسوم التوصيل غير محددة بعد'), 'missing-fee block message must be gone');
});
