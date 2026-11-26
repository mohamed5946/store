/* No-functions Firestore rules tests (contract 2026-11-26 §3 — replaces
 * the Phase 2 file-36 list: anonymous order creation is now ALLOWED
 * through the client transaction, with shape + price + discount +
 * audit checks in the rules; feedback is a one-way card).
 *
 * EMULATOR-GATED: these tests CANNOT run on a machine without Java
 * (the Firestore emulator needs it) and they CANNOT run against the
 * live project (they write test data). Run them with the emulator:
 *
 *   npm install --no-save @firebase/rules-unit-testing firebase-tools
 *   npx firebase emulators:exec --only firestore \
 *     "node --test test/rules.test.js"
 *
 * (from the repo root, with firestore.rules in place). The emulator
 * loads firestore.rules automatically. CI wiring for this job is NOT
 * in build.yml, so run it on a machine with the emulator before
 * deploying the rules. Rules are verified by code review + these
 * emulator tests, NOT by a live run — say so plainly if the emulator
 * could not run.
 *
 * The function-side audit tests (T14: one entry per order, no second
 * entry on an idempotent retry, no customer PII) live in
 * functions/test/audit.test.js and run without the emulator.
 */

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');
const {
  doc, setDoc, getDoc, updateDoc, deleteDoc, deleteField, writeBatch,
  serverTimestamp, collection, getDocs, runTransaction, Timestamp,
} = require('firebase/firestore');

const PROJECT_ID = 'demo-store-3384c';
const RULES_PATH = path.join(__dirname, '..', 'firestore.rules');
const ADMIN_UID = 'admin-uid';
const MANAGER_UID = 'manager-uid';
const MANAGER2_UID = 'manager2-uid';

let testEnv;
let opCounter = 0;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: fs.readFileSync(RULES_PATH, 'utf8'),
      host: '127.0.0.1',
      port: 8080,
    },
  });
  // Seed: admin + manager profiles, one product + its inventory,
  // one order, feedback records, the active-template pointer, plus
  // the no-functions fixtures: dedicated products/inventory for the
  // order-transaction tests (prod-1's price/stock mutate across the
  // older tests, so the new tests own their own docs), discount
  // codes in every state, and a manager WITH orders_create_manual.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'admins', ADMIN_UID), { role: 'admin', name: 'Admin' });
    await setDoc(doc(db, 'admins', MANAGER_UID), { role: 'manager', name: 'Manager' });
    await setDoc(doc(db, 'admins', MANAGER2_UID), {
      role: 'manager', name: 'Manager 2',
      permissions: { orders_create_manual: true },
    });
    await setDoc(doc(db, 'products', 'prod-1'), {
      name: 'سماعة بلوتوث', price: 500, categoryId: 'cat-1', inStock: true,
    });
    await setDoc(doc(db, 'inventory', 'prod-1'), {
      productId: 'prod-1', stock: 5, reserved: 0, minStock: 5, costPrice: 300,
    });
    // prod-2: anonymous order tests (price 200, stock 3).
    await setDoc(doc(db, 'products', 'prod-2'), {
      name: 'شاحن سريع', price: 200, categoryId: 'cat-1', inStock: true,
    });
    await setDoc(doc(db, 'inventory', 'prod-2'), {
      productId: 'prod-2', stock: 3, reserved: 0, minStock: 5, costPrice: 100,
    });
    // prod-3: the §13 inStock refresh tests (stock 2, reserved 2 —
    // the flag must be false; the seed deliberately says true).
    await setDoc(doc(db, 'products', 'prod-3'), {
      name: 'كابل USB', price: 100, categoryId: 'cat-1', inStock: true,
    });
    await setDoc(doc(db, 'inventory', 'prod-3'), {
      productId: 'prod-3', stock: 2, reserved: 2, minStock: 5, costPrice: 50,
    });
    // prod-4: discount-invalid + bad-shape tests (price 300, stock 10).
    await setDoc(doc(db, 'products', 'prod-4'), {
      name: 'جراب موبايل', price: 300, categoryId: 'cat-1', inStock: true,
    });
    await setDoc(doc(db, 'inventory', 'prod-4'), {
      productId: 'prod-4', stock: 10, reserved: 0, minStock: 5, costPrice: 150,
    });
    // prod-5: manual-order tests (price 300, stock 10).
    await setDoc(doc(db, 'products', 'prod-5'), {
      name: 'سماعة سلكية', price: 300, categoryId: 'cat-1', inStock: true,
    });
    await setDoc(doc(db, 'inventory', 'prod-5'), {
      productId: 'prod-5', stock: 10, reserved: 0, minStock: 5, costPrice: 150,
    });
    // prod-6: fractional-price test (correction 2026-11-26 — the
    // order rule uses `is number`, so a stored 19.99 price must not
    // deny a matching order).
    await setDoc(doc(db, 'products', 'prod-6'), {
      name: 'وصلة صوت', price: 19.99, categoryId: 'cat-1', inStock: true,
    });
    await setDoc(doc(db, 'inventory', 'prod-6'), {
      productId: 'prod-6', stock: 10, reserved: 0, minStock: 5, costPrice: 10,
    });
    await setDoc(doc(db, 'discounts', 'SAVE10'), {
      percent: 10, active: true, usedBy: null, expiresAt: null,
    });
    await setDoc(doc(db, 'discounts', 'USED10'), {
      percent: 10, active: true, usedBy: 'order-old', expiresAt: null,
    });
    await setDoc(doc(db, 'discounts', 'OFF10'), {
      percent: 10, active: false, usedBy: null, expiresAt: null,
    });
    await setDoc(doc(db, 'discounts', 'EXP10'), {
      percent: 10, active: true, usedBy: null,
      expiresAt: Timestamp.fromMillis(Date.now() - 86400000),
    });
    await setDoc(doc(db, 'discounts', 'CLAIM10'), {
      percent: 15, active: true, usedBy: null, expiresAt: null,
    });
    await setDoc(doc(db, 'orders', 'order-1'), {
      id: 'order-1', clientOrderId: 'order-1', status: 'new',
      paymentStatus: 'cod_pending', total: 1000,
      customerName: 'اختبار', customerPhone: '01012345678',
    });
    // A3 batch (2026-11-26): fresh orders for the cancel-coverage
    // tests — order-1's status mutates across the earlier tests, so
    // the cancel tests need their own 'new' orders.
    await setDoc(doc(db, 'orders', 'order-cancel-ok'), {
      id: 'order-cancel-ok', clientOrderId: 'order-cancel-ok',
      status: 'new', paymentStatus: 'cod_pending', total: 1000,
      customerName: 'اختبار', customerPhone: '01012345678',
    });
    await setDoc(doc(db, 'orders', 'order-cancel-bad'), {
      id: 'order-cancel-bad', clientOrderId: 'order-cancel-bad',
      status: 'new', paymentStatus: 'cod_pending', total: 1000,
      customerName: 'اختبار', customerPhone: '01012345678',
    });
    // Reopen hotfix (2026-11-26): fresh CANCELLED orders — the
    // reopen tests need orders already carrying the cancel stamp.
    await setDoc(doc(db, 'orders', 'order-reopen-ok'), {
      id: 'order-reopen-ok', clientOrderId: 'order-reopen-ok',
      status: 'cancelled', paymentStatus: 'cod_pending', total: 1000,
      customerName: 'اختبار', customerPhone: '01012345678',
      cancelledAt: serverTimestamp(), cancelReason: 'cancelled_by_admin',
    });
    await setDoc(doc(db, 'orders', 'order-reopen-bad'), {
      id: 'order-reopen-bad', clientOrderId: 'order-reopen-bad',
      status: 'cancelled', paymentStatus: 'cod_pending', total: 1000,
      customerName: 'اختبار', customerPhone: '01012345678',
      cancelledAt: serverTimestamp(), cancelReason: 'cancelled_by_admin',
    });
    // Feedback seeds use the NEW one-way shape (contract §6).
    await setDoc(doc(db, 'feedback', 'fb-1'), {
      name: 'أحمد', email: 'a@test.com', address: 'القاهرة',
      message: 'شكوى تجريبية كافية الطول', createdAt: serverTimestamp(),
    });
    await setDoc(doc(db, 'feedback', 'fb-2'), {
      name: 'منى', email: 'm@test.com', address: 'الجيزة',
      message: 'شكوى تجريبية ثانية كافية الطول', createdAt: serverTimestamp(),
    });
    await setDoc(doc(db, 'storeSettings', 'activeTemplate'), { templateId: 'tpl-live' });
    await setDoc(doc(db, 'templates', 'tpl-live'), { name: 'Live', status: 'active' });
    await setDoc(doc(db, 'templates', 'tpl-draft'), { name: 'Draft', status: 'draft' });
  });
});

after(async () => {
  await testEnv.cleanup();
});

function adminDb() { return testEnv.authenticatedContext(ADMIN_UID).firestore(); }
function managerDb() { return testEnv.authenticatedContext(MANAGER_UID).firestore(); }
function manager2Db() { return testEnv.authenticatedContext(MANAGER2_UID).firestore(); }
function anonDb() { return testEnv.unauthenticatedContext().firestore(); }

/* Write one document + its audit entry in a single batch, the way the
 * app does it. `sensitive` carries the changed sensitive fields with
 * their new values (price/stock/reserved/status/paymentStatus/inStock/
 * percent) for the newValuesByDoc check. Returns the operationId. */
async function auditedSet(db, uid, { collection: coll, docId, data, operation = 'update', sensitive = {} }) {
  opCounter += 1;
  const opId = `op-test-${opCounter}`;
  const batch = writeBatch(db);
  const dataWithOp = { ...data, operationId: opId, updatedAt: serverTimestamp() };
  batch.set(doc(db, coll, docId), dataWithOp, { merge: true });
  const changedFields = Object.keys(dataWithOp);
  batch.set(doc(db, 'audit', opId), {
    operationId: opId,
    actor: uid,
    actorName: 'Test Admin',
    timestamp: serverTimestamp(),
    collection: coll,
    docId,
    operation,
    changedFields,
    oldValues: {},
    newValues: sensitive,
    docIds: { [`${coll}/${docId}`]: changedFields },
    newValuesByDoc: { [`${coll}/${docId}`]: sensitive },
    documents: [{ collection: coll, docId, changedFields, oldValues: {}, newValues: sensitive }],
    source: 'test',
  });
  await batch.commit();
  return opId;
}

/* Delete one document + its deterministic delete-audit entry in a
 * single batch (del_<collection>_<docId>). */
async function deleteWithAudit(db, uid, coll, docId) {
  const opId = `del_${coll}_${docId}`;
  const batch = writeBatch(db);
  batch.delete(doc(db, coll, docId));
  batch.set(doc(db, 'audit', opId), {
    operationId: opId,
    actor: uid,
    actorName: 'Test Admin',
    timestamp: serverTimestamp(),
    collection: coll,
    docId,
    operation: 'delete',
    changedFields: [],
    oldValues: {},
    newValues: {},
    docIds: { [`${coll}/${docId}`]: [] },
    newValuesByDoc: { [`${coll}/${docId}`]: {} },
    documents: [],
    source: 'test',
  });
  await batch.commit();
  return opId;
}

/* The client order transaction the way storefront/app.js placeOrderTx
 * does it (contract §1): idempotency read, product + inventory (+
 * discount) reads, total from DATABASE prices, stock reservation,
 * discount claim, order + movement + audit entry. `source` /
 * `createdBy` / `actor` / `operation` switch it to the manual-order
 * shape. Deliberately does NOT validate stock client-side — the
 * rules must deny an over-reservation on their own. */
async function placeOrderTx(db, {
  orderId, productId, qty, discountCode = null,
  priceOverride = null, totalOverride = null,
  source = 'storefront', createdBy = null,
  actor = 'anonymous', actorName = 'storefront', operation = 'create',
  movementSource = 'placeOrder',
  /* stampOperationId: the PC (Electron) manual-order shape —
   * operationId stamped on the inventory write, the discount
   * claim and the order doc (coordinator fix 2026-11-26: the
   * rules tolerate it in the reservation / claim / order-shape
   * branches). */
  stampOperationId = false,
}) {
  const auditId = `audit-${orderId}`;
  await runTransaction(db, async (tx) => {
    const existing = await tx.get(doc(db, 'orders', orderId));
    if (existing.exists()) throw new Error('order already exists');
    const productSnap = await tx.get(doc(db, 'products', productId));
    const product = productSnap.data();
    const invSnap = await tx.get(doc(db, 'inventory', productId));
    const inv = invSnap.data();
    let discount = null;
    if (discountCode) {
      const discSnap = await tx.get(doc(db, 'discounts', discountCode));
      const rec = discSnap.data();
      discount = { code: discountCode, percent: rec.percent };
    }
    const price = priceOverride != null ? priceOverride : product.price;
    const subtotal = price * qty;
    const discountPercent = discount ? discount.percent : null;
    const discountAmount = discount ? Math.round((subtotal * discount.percent) / 100) : 0;
    const total = totalOverride != null ? totalOverride : subtotal - discountAmount;
    const now = serverTimestamp();
    const invWrite = {
      productId, stock: inv.stock, reserved: inv.reserved + qty,
      minStock: inv.minStock, costPrice: inv.costPrice, updatedAt: now,
    };
    if (stampOperationId) invWrite.operationId = auditId;
    tx.set(doc(db, 'inventory', productId), invWrite, { merge: true });
    tx.set(doc(collection(db, 'movements')), {
      productId, type: 'order_reserve', qty: -qty, orderId,
      source: movementSource, actorUid: createdBy, createdAt: now,
    });
    if (discount) {
      const claim = { usedBy: orderId, usedAt: now };
      if (stampOperationId) { claim.operationId = auditId; claim.updatedAt = now; }
      tx.set(doc(db, 'discounts', discount.code), claim, { merge: true });
    }
    tx.set(doc(db, 'orders', orderId), {
      id: orderId, clientOrderId: orderId,
      customerName: 'اختبار', customerPhone: '01012345678', customerAddress: 'القاهرة',
      items: [{ productId, name: product.name, price, qty }],
      subtotal, discountCode: discount ? discount.code : null,
      discountPercent, discountAmount, total,
      status: 'new', paymentStatus: 'cod_pending', source,
      createdBy, shippingCompanyId: null, trackingNumber: null, notes: null,
      createdAt: now, updatedAt: now,
      acceptedAt: null, deliveredAt: null, cancelledAt: null, cancelReason: null,
      auditId,
      ...(stampOperationId ? { operationId: auditId } : {}),
    });
    tx.set(doc(db, 'audit', auditId), {
      operationId: auditId, actor, actorName,
      timestamp: now, collection: 'orders', docId: orderId, operation,
      changedFields: ['status', 'total'], oldValues: {},
      newValues: { status: 'new', total },
      docIds: { [`orders/${orderId}`]: ['status', 'total'] },
      newValuesByDoc: { [`orders/${orderId}`]: { status: 'new', total } },
      documents: [{ collection: 'orders', docId: orderId, changedFields: ['status', 'total'], oldValues: {}, newValues: { status: 'new', total } }],
      source: movementSource,
    });
  });
  return orderId;
}

/* Write one order + its reservation + movement + audit in a batch,
 * starting from the valid storefront shape and applying `omit`
 * (keys to delete) / `overrides`. The batch mirrors the
 * transaction's writes, so a denial isolates the order rule. */
async function rawOrderBatch(db, {
  orderId, productId, productName, price, qty, stock, reserved,
  omit = [], overrides = {},
}) {
  const auditId = `audit-${orderId}`;
  const subtotal = price * qty;
  const now = serverTimestamp();
  const order = {
    id: orderId, clientOrderId: orderId,
    customerName: 'اختبار', customerPhone: '01012345678', customerAddress: 'القاهرة',
    items: [{ productId, name: productName, price, qty }],
    subtotal, discountCode: null, discountPercent: null, discountAmount: 0, total: subtotal,
    status: 'new', paymentStatus: 'cod_pending', source: 'storefront',
    createdBy: null, shippingCompanyId: null, trackingNumber: null, notes: null,
    createdAt: now, updatedAt: now,
    acceptedAt: null, deliveredAt: null, cancelledAt: null, cancelReason: null,
    auditId,
  };
  for (const k of omit) delete order[k];
  Object.assign(order, overrides);
  const batch = writeBatch(db);
  batch.set(doc(db, 'inventory', productId), {
    productId, stock, reserved: reserved + qty,
    minStock: 5, costPrice: 100, updatedAt: now,
  }, { merge: true });
  batch.set(doc(collection(db, 'movements')), {
    productId, type: 'order_reserve', qty: -qty, orderId,
    source: 'placeOrder', actorUid: null, createdAt: now,
  });
  batch.set(doc(db, 'orders', orderId), order);
  batch.set(doc(db, 'audit', auditId), {
    operationId: auditId, actor: 'anonymous', actorName: 'storefront',
    timestamp: now, collection: 'orders', docId: orderId, operation: 'create',
    changedFields: ['status', 'total'], oldValues: {},
    newValues: { status: 'new', total: order.total },
    docIds: { [`orders/${orderId}`]: ['status', 'total'] },
    newValuesByDoc: { [`orders/${orderId}`]: { status: 'new', total: order.total } },
    documents: [{ collection: 'orders', docId: orderId, changedFields: ['status', 'total'], oldValues: {}, newValues: { status: 'new', total: order.total } }],
    source: 'placeOrder',
  });
  return batch.commit();
}

/* ---------- anonymous access: the order transaction ---------- */

test('No-functions: an anonymous order create via the storefront transaction succeeds', async () => {
  const db = anonDb();
  await assertSucceeds(placeOrderTx(db, {
    orderId: 'order-nf-1', productId: 'prod-2', qty: 2,
  }));
  const order = (await getDoc(doc(adminDb(), 'orders', 'order-nf-1'))).data();
  assert.equal(order.status, 'new');
  assert.equal(order.total, 400);
  assert.equal(order.paymentStatus, 'cod_pending');
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-2'))).data().reserved, 2);
});

test('No-functions: an anonymous order with a WRONG price is rejected', async () => {
  const db = anonDb();
  // The totals are consistent with the forged price — only the price
  // check (against the products doc) must deny it.
  await assertFails(placeOrderTx(db, {
    orderId: 'order-nf-price', productId: 'prod-2', qty: 1, priceOverride: 999,
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'order-nf-price'))).exists(), false);
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-2'))).data().reserved, 2);
});

test('No-functions: an anonymous order reserving MORE than available is rejected', async () => {
  const db = anonDb();
  // prod-2: stock 3, reserved 2 — asking for 5 more writes
  // reserved 7 > stock 3; the inventory rule must deny the batch.
  await assertFails(placeOrderTx(db, {
    orderId: 'order-nf-stock', productId: 'prod-2', qty: 5,
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'order-nf-stock'))).exists(), false);
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-2'))).data().reserved, 2);
});

test('No-functions: an anonymous order with a BAD shape is rejected', async () => {
  const db = anonDb();
  const base = {
    productId: 'prod-4', productName: 'جراب موبايل', price: 300,
    qty: 1, stock: 10, reserved: 0,
  };
  // Missing customerAddress.
  await assertFails(rawOrderBatch(db, { ...base, orderId: 'order-bad-1', omit: ['customerAddress'] }));
  // Phone shorter than 10 digits.
  await assertFails(rawOrderBatch(db, { ...base, orderId: 'order-bad-2', overrides: { customerPhone: '010123456' } }));
  // qty 0.
  await assertFails(rawOrderBatch(db, { ...base, orderId: 'order-bad-3', overrides: { items: [{ productId: 'prod-4', name: 'جراب موبايل', price: 300, qty: 0 }] } }));
  // Total does not match subtotal - discountAmount.
  await assertFails(rawOrderBatch(db, { ...base, orderId: 'order-bad-4', overrides: { total: 999 } }));
  // Extra field outside the exact key list.
  await assertFails(rawOrderBatch(db, { ...base, orderId: 'order-bad-5', overrides: { extraField: 1 } }));
  for (const id of ['order-bad-1', 'order-bad-2', 'order-bad-3', 'order-bad-4', 'order-bad-5']) {
    assert.equal((await getDoc(doc(adminDb(), 'orders', id))).exists(), false);
  }
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-4'))).data().reserved, 0);
});

test('No-functions: an anonymous order with a VALID discount code succeeds and claims it', async () => {
  const db = anonDb();
  await assertSucceeds(placeOrderTx(db, {
    orderId: 'order-nf-disc', productId: 'prod-2', qty: 1, discountCode: 'SAVE10',
  }));
  const order = (await getDoc(doc(adminDb(), 'orders', 'order-nf-disc'))).data();
  assert.equal(order.discountCode, 'SAVE10');
  assert.equal(order.discountPercent, 10);
  assert.equal(order.discountAmount, 20);
  assert.equal(order.total, 180);
  assert.equal((await getDoc(doc(adminDb(), 'discounts', 'SAVE10'))).data().usedBy, 'order-nf-disc');
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-2'))).data().reserved, 3);
});

test('No-functions: an anonymous order with a FRACTIONAL stored price succeeds', async () => {
  const db = anonDb();
  // prod-6 costs 19.99 — the order rule checks `is number`, not
  // `is int`, so the matching line price must pass.
  await assertSucceeds(placeOrderTx(db, {
    orderId: 'order-nf-frac', productId: 'prod-6', qty: 2,
  }));
  const order = (await getDoc(doc(adminDb(), 'orders', 'order-nf-frac'))).data();
  assert.equal(order.total, 39.98);
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-6'))).data().reserved, 2);
});

test('No-functions: an order with an INACTIVE, USED, or EXPIRED code is rejected', async () => {
  const db = anonDb();
  for (const code of ['OFF10', 'USED10', 'EXP10']) {
    await assertFails(placeOrderTx(db, {
      orderId: `order-nf-${code.toLowerCase()}`, productId: 'prod-4', qty: 1, discountCode: code,
    }));
    assert.equal((await getDoc(doc(adminDb(), 'orders', `order-nf-${code.toLowerCase()}`))).exists(), false);
  }
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-4'))).data().reserved, 0);
});

test('No-functions: claiming a discount WITHOUT a matching order is denied', async () => {
  const db = anonDb();
  await assertFails(updateDoc(doc(db, 'discounts', 'CLAIM10'), {
    usedBy: 'order-nope', usedAt: serverTimestamp(),
  }));
  assert.equal((await getDoc(doc(adminDb(), 'discounts', 'CLAIM10'))).data().usedBy, null);
  // And a second claim of the already-used SAVE10 is denied too.
  await assertFails(updateDoc(doc(db, 'discounts', 'SAVE10'), {
    usedBy: 'order-nf-other', usedAt: serverTimestamp(),
  }));
  assert.equal((await getDoc(doc(adminDb(), 'discounts', 'SAVE10'))).data().usedBy, 'order-nf-disc');
});

/* ---------- anonymous reads: what the transaction needs ---------- */

test('No-functions: anonymous may probe a non-existent order id, never read an existing order', async () => {
  const db = anonDb();
  const probe = await getDoc(doc(db, 'orders', 'order-nope-123'));
  await assertSucceeds(Promise.resolve(probe));
  assert.equal(probe.exists(), false);
  await assertFails(getDoc(doc(db, 'orders', 'order-1')));
});

test('Phase 2 (T19): the public catalog stays readable anonymously', async () => {
  const db = anonDb();
  await assertSucceeds(getDoc(doc(db, 'products', 'prod-1')));
  await assertSucceeds(getDoc(doc(db, 'storeSettings', 'activeTemplate')));
  await assertSucceeds(getDocs(collection(db, 'products')));
});

test('No-functions: anonymous gets of inventory and discounts are allowed (the transaction reads them), lists and feedback/audit are denied', async () => {
  const db = anonDb();
  await assertSucceeds(getDoc(doc(db, 'inventory', 'prod-1')));
  await assertSucceeds(getDoc(doc(db, 'discounts', 'SAVE10')));
  await assertFails(getDocs(collection(db, 'inventory')));
  await assertFails(getDocs(collection(db, 'discounts')));
  await assertFails(getDoc(doc(db, 'feedback', 'fb-1')));
  await assertFails(getDoc(doc(db, 'audit', 'op-test-1')));
  await assertFails(getDoc(doc(db, 'rateLimits', 'ip:x')));
});

/* ---------- anonymous inventory writes: reservation only ---------- */

test('No-functions: an anonymous inventory write that is NOT a reservation is denied', async () => {
  const db = anonDb();
  // prod-2 is fully reserved now (stock 3, reserved 3).
  await assertFails(setDoc(doc(db, 'inventory', 'prod-2'), { stock: 99 }, { merge: true }));
  await assertFails(setDoc(doc(db, 'inventory', 'prod-2'), { reserved: 1 }, { merge: true }));
  const inv = (await getDoc(doc(adminDb(), 'inventory', 'prod-2'))).data();
  assert.equal(inv.stock, 3);
  assert.equal(inv.reserved, 3);
});

/* ---------- §13 inStock refresh ---------- */

test('No-functions: the anonymous inStock refresh sets the verified value', async () => {
  const db = anonDb();
  // prod-3: stock 2, reserved 2 — inStock must be false.
  await assertSucceeds(setDoc(doc(db, 'products', 'prod-3'), { inStock: false }, { merge: true }));
  assert.equal((await getDoc(doc(adminDb(), 'products', 'prod-3'))).data().inStock, false);
});

test('No-functions: the anonymous inStock refresh with a WRONG value is denied', async () => {
  const db = anonDb();
  await assertFails(setDoc(doc(db, 'products', 'prod-3'), { inStock: true }, { merge: true }));
  assert.equal((await getDoc(doc(adminDb(), 'products', 'prod-3'))).data().inStock, false);
});

test('No-functions: an anonymous products price change is denied', async () => {
  const db = anonDb();
  await assertFails(setDoc(doc(db, 'products', 'prod-3'), { price: 1 }, { merge: true }));
  assert.equal((await getDoc(doc(adminDb(), 'products', 'prod-3'))).data().price, 100);
});

/* ---------- manual orders (authenticated) ---------- */

test('No-functions: an authenticated manual order succeeds', async () => {
  const db = adminDb();
  await assertSucceeds(placeOrderTx(db, {
    orderId: 'order-nf-manual-1', productId: 'prod-5', qty: 1,
    source: 'admin_manual', createdBy: ADMIN_UID,
    actor: ADMIN_UID, actorName: 'Admin', operation: 'manual_order_create',
    movementSource: 'createManualOrder',
  }));
  const order = (await getDoc(doc(db, 'orders', 'order-nf-manual-1'))).data();
  assert.equal(order.source, 'admin_manual');
  assert.equal(order.createdBy, ADMIN_UID);
  assert.equal(order.total, 300);
  assert.equal((await getDoc(doc(db, 'inventory', 'prod-5'))).data().reserved, 1);
});

test('No-functions: a manager WITHOUT orders_create_manual may not place a manual order', async () => {
  const db = managerDb();
  await assertFails(placeOrderTx(db, {
    orderId: 'order-nf-manual-no', productId: 'prod-5', qty: 1,
    source: 'admin_manual', createdBy: MANAGER_UID,
    actor: MANAGER_UID, actorName: 'Manager', operation: 'manual_order_create',
    movementSource: 'createManualOrder',
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'order-nf-manual-no'))).exists(), false);
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-5'))).data().reserved, 1);
});

test('No-functions: a manager WITH orders_create_manual may place a manual order', async () => {
  const db = manager2Db();
  await assertSucceeds(placeOrderTx(db, {
    orderId: 'order-nf-manual-2', productId: 'prod-5', qty: 1,
    source: 'admin_manual', createdBy: MANAGER2_UID,
    actor: MANAGER2_UID, actorName: 'Manager 2', operation: 'manual_order_create',
    movementSource: 'createManualOrder',
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'order-nf-manual-2'))).data().source, 'admin_manual');
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-5'))).data().reserved, 2);
});

/* Coordinator fix 2026-11-26: the PC manual order stamps
 * operationId on the inventory write, the discount claim and the
 * order doc. Before the fix the reservation branch denied the
 * inventory write (operationId not in its changed-keys list), the
 * claim branch denied the discount write, and the order shape
 * (25 keys) denied the 26-key order — the whole manual order
 * failed. The rules now tolerate the correlation id in all three
 * branches, and this test pins that shape (with a discount code,
 * so the claim branch is exercised too). */
test('No-functions: a manual order stamping operationId (PC shape) succeeds, including the discount claim', async () => {
  const db = adminDb();
  await setDoc(doc(db, 'discounts', 'OPID10'), {
    percent: 10, active: true, usedBy: null, expiresAt: null,
  });
  await assertSucceeds(placeOrderTx(db, {
    orderId: 'order-nf-manual-opid', productId: 'prod-5', qty: 1,
    discountCode: 'OPID10',
    source: 'admin_manual', createdBy: ADMIN_UID,
    actor: ADMIN_UID, actorName: 'Admin', operation: 'manual_order_create',
    movementSource: 'createManualOrder', stampOperationId: true,
  }));
  const order = (await getDoc(doc(db, 'orders', 'order-nf-manual-opid'))).data();
  assert.equal(order.operationId, 'audit-order-nf-manual-opid');
  assert.equal(order.discountCode, 'OPID10');
  assert.equal(order.total, 270);
  assert.equal((await getDoc(doc(db, 'discounts', 'OPID10'))).data().usedBy, 'order-nf-manual-opid');
  assert.equal((await getDoc(doc(db, 'inventory', 'prod-5'))).data().reserved, 3);
});

/* The reservation branch on its own: an admin inventory update
 * that ONLY raises reserved (and stamps operationId + updatedAt)
 * passes without any audit entry. */
test('No-functions: an inventory reservation stamping operationId passes with no audit entry', async () => {
  const db = adminDb();
  await assertSucceeds(updateDoc(doc(db, 'inventory', 'prod-5'), {
    reserved: 4, operationId: 'op-reserve-test', updatedAt: serverTimestamp(),
  }));
  assert.equal((await getDoc(doc(db, 'inventory', 'prod-5'))).data().reserved, 4);
});

/* ---------- audit enforcement (T19/T20) ---------- */

test('Phase 2 (T19): an admin product update WITHOUT an audit entry is denied', async () => {
  const db = adminDb();
  await assertFails(updateDoc(doc(db, 'products', 'prod-1'), { price: 600 }));
});

test('Phase 2 (T19): an admin product update WITHOUT an operationId but WITH an audit entry is denied', async () => {
  const db = adminDb();
  // The audit entry exists, but the product write carries no
  // operationId, so the rule cannot find it.
  opCounter += 1;
  const opId = `op-test-${opCounter}`;
  const batch = writeBatch(db);
  batch.set(doc(db, 'audit', opId), {
    operationId: opId, actor: ADMIN_UID, actorName: 'Test Admin',
    timestamp: serverTimestamp(), collection: 'products', docId: 'prod-1',
    operation: 'update', changedFields: ['price'], oldValues: {}, newValues: { price: 600 },
    docIds: { 'products/prod-1': ['price'] },
    newValuesByDoc: { 'products/prod-1': { price: 600 } },
    documents: [{ collection: 'products', docId: 'prod-1', changedFields: ['price'], oldValues: {}, newValues: { price: 600 } }],
    source: 'test',
  });
  await batch.commit();
  await assertFails(updateDoc(doc(db, 'products', 'prod-1'), { price: 600 }));
});

test('Phase 2 (T19): an admin product update WITH a valid audit entry passes', async () => {
  const db = adminDb();
  await assertSucceeds(auditedSet(db, ADMIN_UID, {
    collection: 'products', docId: 'prod-1',
    data: { price: 600 }, sensitive: { price: 600 },
  }));
  const snap = await getDoc(doc(db, 'products', 'prod-1'));
  assert.equal(snap.data().price, 600);
});

test('Phase 2 (T20): a fake audit whose changedFields OMITS the changed field is denied', async () => {
  const db = adminDb();
  opCounter += 1;
  const opId = `op-test-${opCounter}`;
  const batch = writeBatch(db);
  // The write changes price, but the audit entry lists only operationId
  // and updatedAt — the changed price is missing from docIds.
  batch.set(doc(db, 'products', 'prod-1'), { price: 700, operationId: opId, updatedAt: serverTimestamp() }, { merge: true });
  batch.set(doc(db, 'audit', opId), {
    operationId: opId, actor: ADMIN_UID, actorName: 'Test Admin',
    timestamp: serverTimestamp(), collection: 'products', docId: 'prod-1',
    operation: 'update', changedFields: ['operationId', 'updatedAt'], oldValues: {}, newValues: {},
    docIds: { 'products/prod-1': ['operationId', 'updatedAt'] },
    newValuesByDoc: { 'products/prod-1': {} },
    documents: [{ collection: 'products', docId: 'prod-1', changedFields: ['operationId', 'updatedAt'], oldValues: {}, newValues: {} }],
    source: 'test',
  });
  await assertFails(batch.commit());
});

test('Phase 2 (T20): a fake audit whose recorded new price is WRONG is denied', async () => {
  const db = adminDb();
  opCounter += 1;
  const opId = `op-test-${opCounter}`;
  const batch = writeBatch(db);
  // The write sets price 700, but the audit records newValues.price 600.
  batch.set(doc(db, 'products', 'prod-1'), { price: 700, operationId: opId, updatedAt: serverTimestamp() }, { merge: true });
  batch.set(doc(db, 'audit', opId), {
    operationId: opId, actor: ADMIN_UID, actorName: 'Test Admin',
    timestamp: serverTimestamp(), collection: 'products', docId: 'prod-1',
    operation: 'update', changedFields: ['price', 'operationId', 'updatedAt'], oldValues: {}, newValues: { price: 600 },
    docIds: { 'products/prod-1': ['price', 'operationId', 'updatedAt'] },
    newValuesByDoc: { 'products/prod-1': { price: 600 } },
    documents: [{ collection: 'products', docId: 'prod-1', changedFields: ['price', 'operationId', 'updatedAt'], oldValues: {}, newValues: { price: 600 } }],
    source: 'test',
  });
  await assertFails(batch.commit());
  const snap = await getDoc(doc(db, 'products', 'prod-1'));
  assert.notEqual(snap.data().price, 700, 'the denied write changed nothing');
});

test('Phase 2 (T20): a REUSED operationId is denied', async () => {
  const db = adminDb();
  const opId = await auditedSet(db, ADMIN_UID, {
    collection: 'products', docId: 'prod-1',
    data: { price: 800 }, sensitive: { price: 800 },
  });
  // A second write reusing the same operationId: the audit create fails
  // (the document already exists) and the timestamp no longer matches.
  const batch = writeBatch(db);
  batch.set(doc(db, 'products', 'prod-1'), { price: 900, operationId: opId, updatedAt: serverTimestamp() }, { merge: true });
  batch.set(doc(db, 'audit', opId), {
    operationId: opId, actor: ADMIN_UID, actorName: 'Test Admin',
    timestamp: serverTimestamp(), collection: 'products', docId: 'prod-1',
    operation: 'update', changedFields: ['price', 'operationId', 'updatedAt'], oldValues: {}, newValues: { price: 900 },
    docIds: { 'products/prod-1': ['price', 'operationId', 'updatedAt'] },
    newValuesByDoc: { 'products/prod-1': { price: 900 } },
    documents: [{ collection: 'products', docId: 'prod-1', changedFields: ['price', 'operationId', 'updatedAt'], oldValues: {}, newValues: { price: 900 } }],
    source: 'test',
  });
  await assertFails(batch.commit());
});

test('Phase 2 (T19): an audit entry is append-only — update and delete are denied', async () => {
  const db = adminDb();
  const opId = await auditedSet(db, ADMIN_UID, {
    collection: 'products', docId: 'prod-1',
    data: { price: 850 }, sensitive: { price: 850 },
  });
  await assertFails(updateDoc(doc(db, 'audit', opId), { operation: 'forged' }));
  await assertFails(deleteDoc(doc(db, 'audit', opId)));
});

/* ---------- inStock cross-check (T21) ---------- */

test('Phase 2 (T21): a stock change crossing 0 WITHOUT updating inStock is denied', async () => {
  const db = adminDb();
  // Stock 5 -> 0 while products.inStock stays true: the cross-check fails.
  await assertFails(auditedSet(db, ADMIN_UID, {
    collection: 'inventory', docId: 'prod-1',
    data: { stock: 0 }, sensitive: { stock: 0 },
  }));
  const snap = await getDoc(doc(db, 'inventory', 'prod-1'));
  assert.equal(snap.data().stock, 5, 'the denied write changed nothing');
});

test('Phase 2 (T21): a stock change crossing 0 WITH the matching inStock update passes', async () => {
  const db = adminDb();
  // Both documents in one batch, each with its own audit entry.
  opCounter += 1;
  const opId = `op-test-${opCounter}`;
  const batch = writeBatch(db);
  batch.set(doc(db, 'inventory', 'prod-1'), { stock: 0, operationId: opId, updatedAt: serverTimestamp() }, { merge: true });
  batch.set(doc(db, 'products', 'prod-1'), { inStock: false, operationId: opId, updatedAt: serverTimestamp() }, { merge: true });
  const changedInv = ['stock', 'operationId', 'updatedAt'];
  const changedProd = ['inStock', 'operationId', 'updatedAt'];
  batch.set(doc(db, 'audit', opId), {
    operationId: opId, actor: ADMIN_UID, actorName: 'Test Admin',
    timestamp: serverTimestamp(), collection: 'inventory', docId: 'prod-1',
    operation: 'stock_adjust', changedFields: changedInv, oldValues: {},
    newValues: { stock: 0, inStock: false },
    docIds: { 'inventory/prod-1': changedInv, 'products/prod-1': changedProd },
    newValuesByDoc: {
      'inventory/prod-1': { stock: 0 },
      'products/prod-1': { inStock: false },
    },
    documents: [
      { collection: 'inventory', docId: 'prod-1', changedFields: changedInv, oldValues: {}, newValues: { stock: 0 } },
      { collection: 'products', docId: 'prod-1', changedFields: changedProd, oldValues: {}, newValues: { inStock: false } },
    ],
    source: 'test',
  });
  await assertSucceeds(batch.commit());
  assert.equal((await getDoc(doc(db, 'inventory', 'prod-1'))).data().stock, 0);
  assert.equal((await getDoc(doc(db, 'products', 'prod-1'))).data().inStock, false);
});

/* ---------- order + feedback state machines ---------- */

test('Phase 2 (T12): an illegal order transition is denied, a legal one passes', async () => {
  const db = adminDb();
  // new -> delivered is illegal.
  await assertFails(auditedSet(db, ADMIN_UID, {
    collection: 'orders', docId: 'order-1',
    data: { status: 'delivered' }, sensitive: { status: 'delivered' },
  }));
  // new -> accepted is legal.
  await assertSucceeds(auditedSet(db, ADMIN_UID, {
    collection: 'orders', docId: 'order-1',
    data: { status: 'accepted' }, sensitive: { status: 'accepted' },
  }));
  assert.equal((await getDoc(doc(db, 'orders', 'order-1'))).data().status, 'accepted');
});

/* ---------- A3 batch (2026-11-26): the cancel/deliver lifecycle
 * fields must be covered by the audit entry. The app's stock-moving
 * status transaction stamps cancelledAt + cancelReason (or
 * deliveredAt) alongside status; the rules check
 * diff().affectedKeys() coverage, so an audit entry that lists only
 * ['status', 'operationId', 'updatedAt'] denies the write even
 * though the transition itself is legal. The app now derives the
 * docIds list from the real write — these tests pin that contract:
 * full coverage passes, the old hard-coded list is denied. */

test('A3: cancelling an order WITH the lifecycle fields covered passes', async () => {
  const db = adminDb();
  await assertSucceeds(auditedSet(db, ADMIN_UID, {
    collection: 'orders', docId: 'order-cancel-ok',
    data: {
      status: 'cancelled',
      cancelledAt: serverTimestamp(),
      cancelReason: 'cancelled_by_admin',
    },
    sensitive: { status: 'cancelled' },
  }));
  assert.equal((await getDoc(doc(db, 'orders', 'order-cancel-ok'))).data().status, 'cancelled');
});

test('A3: cancelling an order with the OLD hard-coded audit list is denied', async () => {
  const db = adminDb();
  opCounter += 1;
  const opId = `op-test-${opCounter}`;
  const batch = writeBatch(db);
  // The write sets status + cancelledAt + cancelReason, but the
  // audit entry lists only status/operationId/updatedAt — the
  // lifecycle fields are missing from docIds, so coverage fails.
  batch.set(doc(db, 'orders', 'order-cancel-bad'), {
    status: 'cancelled',
    cancelledAt: serverTimestamp(),
    cancelReason: 'cancelled_by_admin',
    operationId: opId,
    updatedAt: serverTimestamp(),
  }, { merge: true });
  batch.set(doc(db, 'audit', opId), {
    operationId: opId, actor: ADMIN_UID, actorName: 'Test Admin',
    timestamp: serverTimestamp(), collection: 'orders', docId: 'order-cancel-bad',
    operation: 'status_change',
    changedFields: ['status', 'operationId', 'updatedAt'],
    oldValues: { status: 'new' }, newValues: { status: 'cancelled' },
    docIds: { 'orders/order-cancel-bad': ['status', 'operationId', 'updatedAt'] },
    newValuesByDoc: { 'orders/order-cancel-bad': { status: 'cancelled' } },
    documents: [{ collection: 'orders', docId: 'order-cancel-bad', changedFields: ['status'], oldValues: { status: 'new' }, newValues: { status: 'cancelled' } }],
    source: 'test',
  });
  await assertFails(batch.commit());
  assert.equal((await getDoc(doc(db, 'orders', 'order-cancel-bad'))).data().status, 'new');
});

/* ---------- Reopen hotfix (2026-11-26): cancelled is no longer
 * terminal — cancelled -> new is legal, but only via new (a direct
 * jump to a later state stays denied). The app's reopen write is an
 * audited batch that sets status 'new' and DELETES cancelledAt +
 * cancelReason; the deleted keys are affectedKeys too, so the audit
 * entry must cover them — these tests pin exactly that shape. */

test('Reopen: cancelled -> new WITH the lifecycle deletes covered passes', async () => {
  const db = adminDb();
  opCounter += 1;
  const opId = `op-test-${opCounter}`;
  const batch = writeBatch(db);
  batch.set(doc(db, 'orders', 'order-reopen-ok'), {
    status: 'new',
    cancelledAt: deleteField(),
    cancelReason: deleteField(),
    operationId: opId,
    updatedAt: serverTimestamp(),
  }, { merge: true });
  batch.set(doc(db, 'audit', opId), {
    operationId: opId, actor: ADMIN_UID, actorName: 'Test Admin',
    timestamp: serverTimestamp(), collection: 'orders', docId: 'order-reopen-ok',
    operation: 'status_change',
    changedFields: ['status', 'cancelledAt', 'cancelReason', 'operationId', 'updatedAt'],
    oldValues: { status: 'cancelled' }, newValues: { status: 'new' },
    docIds: { 'orders/order-reopen-ok': ['status', 'cancelledAt', 'cancelReason', 'operationId', 'updatedAt'] },
    newValuesByDoc: { 'orders/order-reopen-ok': { status: 'new' } },
    documents: [{ collection: 'orders', docId: 'order-reopen-ok', changedFields: ['status', 'cancelledAt', 'cancelReason'], oldValues: { status: 'cancelled' }, newValues: { status: 'new' } }],
    source: 'test',
  });
  await assertSucceeds(batch.commit());
  const data = (await getDoc(doc(db, 'orders', 'order-reopen-ok'))).data();
  assert.equal(data.status, 'new');
  assert.equal(data.cancelledAt, undefined);
  assert.equal(data.cancelReason, undefined);
});

test('Reopen: cancelled -> in_transit is denied (must go via new)', async () => {
  const db = adminDb();
  await assertFails(auditedSet(db, ADMIN_UID, {
    collection: 'orders', docId: 'order-reopen-bad',
    data: { status: 'in_transit' }, sensitive: { status: 'in_transit' },
  }));
  assert.equal((await getDoc(doc(db, 'orders', 'order-reopen-bad'))).data().status, 'cancelled');
});

/* ---------- Feedback: one-way cards (contract §6) ---------- */

test('No-functions: an anonymous one-way complaint create succeeds', async () => {
  const db = anonDb();
  await assertSucceeds(setDoc(doc(collection(db, 'feedback')), {
    name: 'اختبار', email: 'test@example.com', address: 'القاهرة',
    message: 'رسالة شكوى كافية الطول', createdAt: serverTimestamp(),
  }));
});

test('No-functions: a complaint with a bad shape is rejected', async () => {
  const db = anonDb();
  // Extra field (the old Phase 3 shape is gone).
  await assertFails(setDoc(doc(collection(db, 'feedback')), {
    name: 'اختبار', email: 'test@example.com', address: 'القاهرة',
    message: 'رسالة شكوى كافية الطول', status: 'new', createdAt: serverTimestamp(),
  }));
  // Message shorter than 10 chars.
  await assertFails(setDoc(doc(collection(db, 'feedback')), {
    name: 'اختبار', email: 'test@example.com', address: 'القاهرة',
    message: 'قصير', createdAt: serverTimestamp(),
  }));
  // Email without '@'.
  await assertFails(setDoc(doc(collection(db, 'feedback')), {
    name: 'اختبار', email: 'not-an-email', address: 'القاهرة',
    message: 'رسالة شكوى كافية الطول', createdAt: serverTimestamp(),
  }));
});

test('No-functions: feedback update is denied, admin delete with a delete-audit succeeds', async () => {
  const db = adminDb();
  await assertFails(updateDoc(doc(db, 'feedback', 'fb-1'), { message: 'تعديل' }));
  await assertSucceeds(deleteWithAudit(db, ADMIN_UID, 'feedback', 'fb-1'));
  assert.equal((await getDoc(doc(db, 'feedback', 'fb-1'))).exists(), false);
});

test('No-functions: a manager may not delete feedback', async () => {
  const db = managerDb();
  await assertFails(deleteDoc(doc(db, 'feedback', 'fb-2')));
  assert.equal((await getDoc(doc(adminDb(), 'feedback', 'fb-2'))).exists(), true);
});

/* ---------- roles: manager vs admin ---------- */

test('Phase 2: a manager may edit products and orders, but not settings or discounts', async () => {
  const db = managerDb();
  await assertSucceeds(auditedSet(db, MANAGER_UID, {
    collection: 'products', docId: 'prod-1',
    data: { price: 550 }, sensitive: { price: 550 },
  }));
  await assertSucceeds(auditedSet(db, MANAGER_UID, {
    collection: 'orders', docId: 'order-1',
    data: { status: 'preparing' }, sensitive: { status: 'preparing' },
  }));
  await assertFails(auditedSet(db, MANAGER_UID, {
    collection: 'storeSettings', docId: 'settings',
    data: { brandName: 'X' }, sensitive: {},
  }));
  await assertFails(auditedSet(db, MANAGER_UID, {
    collection: 'discounts', docId: 'SAVE10',
    data: { percent: 10, active: true }, operation: 'create', sensitive: { percent: 10 },
  }));
});

/* ---------- templates: public reads only the ACTIVE one ---------- */

test('Phase 2: anonymous reads the active template, never a draft, never a list', async () => {
  const db = anonDb();
  await assertSucceeds(getDoc(doc(db, 'templates', 'tpl-live')));
  await assertFails(getDoc(doc(db, 'templates', 'tpl-draft')));
  await assertFails(getDocs(collection(db, 'templates')));
});
