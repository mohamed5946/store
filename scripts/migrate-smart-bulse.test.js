/* Migration mapping tests (design doc file 37).
 *
 * Pure functions only — no Firestore, no credentials. Run from the
 * repo root:
 *   node --test scripts/migrate-smart-bulse.test.js
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');

const {
  mapOrderStatus, normalizePhone, mergeCustomers, mapPaymentStatus,
  buildProductWrites, buildOrderWrite,
} = require('./migrate-smart-bulse');

const NOW = 1793000000000;

test('migration: Smart Bulse statuses map through v1.4 §6.1', () => {
  assert.deepEqual(mapOrderStatus('pending'), { status: 'new', flag: null });
  assert.deepEqual(mapOrderStatus('shipped'), { status: 'in_transit', flag: null });
  assert.deepEqual(mapOrderStatus('delivered'), { status: 'delivered', flag: null });
  assert.deepEqual(mapOrderStatus('late'), { status: 'in_transit', flag: 'late' });
  assert.deepEqual(mapOrderStatus('delayed'), { status: 'in_transit', flag: 'delayed' });
  assert.deepEqual(mapOrderStatus('weird'), { status: 'new', flag: 'unknown_status:weird' });
});

test('migration: phone normalization for the customer merge key', () => {
  assert.equal(normalizePhone('01012345678'), '01012345678');
  assert.equal(normalizePhone('+201012345678'), '01012345678');
  assert.equal(normalizePhone('00201012345678'), '01012345678');
  assert.equal(normalizePhone('1012345678'), '01012345678');
  assert.equal(normalizePhone(' 0101 234 5678 '), '01012345678');
  assert.equal(normalizePhone('123'), null);
  assert.equal(normalizePhone(''), null);
  assert.equal(normalizePhone(null), null);
});

test('migration: customers merge by normalized phone, Smart Bulse wins', () => {
  const { byPhone, byId, merged } = mergeCustomers([
    { id: 'c1', name: 'أحمد', phone: '01012345678', address: 'القاهرة' },
    { id: 'c2', name: 'أحمد محمد', phone: '+201012345678', address: 'الجيزة' },
    { id: 'c3', name: 'منى', phone: '01199999999', address: '' },
    { id: 'c4', name: 'بدون موبايل', phone: '', address: '' },
  ]);
  assert.equal(byPhone.size, 2, 'two distinct phones');
  assert.equal(byPhone.get('01012345678').id, 'c2', 'the last record wins');
  assert.equal(byPhone.get('01012345678').address, 'الجيزة');
  assert.equal(merged.length, 1);
  assert.equal(merged[0].phone, '01012345678');
  assert.equal(byId.get('c4').name, 'بدون موبايل', 'phoneless customers are kept by id');
});

test('migration: payment status maps to COD', () => {
  assert.equal(mapPaymentStatus('paid'), 'cod_paid');
  assert.equal(mapPaymentStatus('unpaid'), 'cod_pending');
  assert.equal(mapPaymentStatus('partial'), 'cod_pending');
  assert.equal(mapPaymentStatus(undefined), 'cod_pending');
});

test('migration: a product builds its product + inventory writes', () => {
  const { productDoc, inventoryDoc } = buildProductWrites(
    { id: 'p1', name: 'سماعة', price: 500, stock: 5, costPrice: 300, minStock: 2, description: 'x', category: 'إلكترونيات' },
    { batchId: 'mig_test', nowMs: NOW },
  );
  assert.equal(productDoc.name, 'سماعة');
  assert.equal(productDoc.price, 500);
  assert.equal(productDoc.inStock, true);
  assert.equal(productDoc.migrationBatch, 'mig_test');
  assert.equal(inventoryDoc.productId, 'p1');
  assert.equal(inventoryDoc.stock, 5);
  assert.equal(inventoryDoc.reserved, 0, 'migrated orders do not reserve stock');
  assert.equal(inventoryDoc.minStock, 2);
  assert.equal(inventoryDoc.costPrice, 300);
});

test('migration: a zero-stock product is out of stock', () => {
  const { productDoc, inventoryDoc } = buildProductWrites(
    { id: 'p2', name: 'كابل', price: 50, stock: 0 },
    { batchId: 'mig_test', nowMs: NOW },
  );
  assert.equal(productDoc.inStock, false);
  assert.equal(inventoryDoc.stock, 0);
  assert.equal(inventoryDoc.minStock, 5, 'default minStock is 5');
});

test('migration: a linked order builds items + total from its sale', () => {
  const sale = {
    id: 's1', customerId: 'c1',
    items: [
      { productId: 'p1', qty: 2, unitPrice: 500 },
      { productId: 'p2', qty: 1, unitPrice: 250 },
    ],
    total: 1150, discountAmt: 100, payStatus: 'paid', date: '2026-11-20T12:00:00',
  };
  const { orderDoc, draft } = buildOrderWrite(
    { id: 'o1', customerId: 'c1', customerName: 'أحمد', saleId: 's1', status: 'shipped', notes: 'ملاحظة' },
    {
      sale,
      customer: { id: 'c1', name: 'أحمد', phone: '01012345678', address: 'القاهرة' },
      productNames: new Map([['p1', 'سماعة'], ['p2', 'شاحن']]),
      batchId: 'mig_test', nowMs: NOW,
    },
  );
  assert.equal(draft, false);
  assert.equal(orderDoc.status, 'in_transit');
  assert.equal(orderDoc.total, 1150);
  assert.equal(orderDoc.discountAmount, 100);
  assert.equal(orderDoc.paymentStatus, 'cod_paid');
  assert.equal(orderDoc.customerPhone, '01012345678');
  assert.equal(orderDoc.notes, 'ملاحظة');
  assert.equal(orderDoc.source, 'migration');
  assert.deepEqual(orderDoc.items, [
    { productId: 'p1', name: 'سماعة', price: 500, qty: 2 },
    { productId: 'p2', name: 'شاحن', price: 250, qty: 1 },
  ]);
});

test('migration: an unmatched order (no sale, no customer) goes to draft, never dropped', () => {
  const { orderDoc, draft, notes } = buildOrderWrite(
    { id: 'o2', customerId: 'c-missing', customerName: 'غريب', saleId: 's-missing', status: 'pending', value: 400 },
    { sale: null, customer: null, productNames: new Map(), batchId: 'mig_test', nowMs: NOW },
  );
  assert.equal(draft, true);
  assert.equal(orderDoc.status, 'new');
  assert.equal(orderDoc.total, 400, 'the order value is kept as the total');
  assert.deepEqual(orderDoc.items, []);
  assert.equal(orderDoc.migrationDraft, true);
  assert.ok(notes.some((n) => n.includes('s-missing')));
  assert.ok(notes.some((n) => n.includes('c-missing')));
});

test('migration: a late order keeps its reason and delayedTo as a flag', () => {
  const { orderDoc, draft } = buildOrderWrite(
    { id: 'o3', customerId: 'c1', status: 'late', reason: 'تأخير الشحن', delayedTo: '2026-11-25', value: 100 },
    { sale: null, customer: { id: 'c1', name: 'أحمد', phone: '01012345678' }, productNames: new Map(), batchId: 'mig_test', nowMs: NOW },
  );
  assert.equal(orderDoc.status, 'in_transit');
  assert.equal(orderDoc.migrationReason, 'تأخير الشحن');
  assert.equal(orderDoc.migrationDelayedTo, '2026-11-25');
  assert.equal(draft, true, 'a late order without a sale is still a draft');
});
