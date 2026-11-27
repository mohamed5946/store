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
    // Pricing Phase A (2026-11-27): the settings fee the rules verify
    // storefront orders against; a sale product for the product-rule
    // tests; multi-line products (stock 30: the cap tests reserve
    // 7 + 7 + 8 = 22 across the file); rounding/matrix products;
    // fresh 10% codes (one per code test — codes are single-use).
    await setDoc(doc(db, 'storeSettings', 'settings'), { deliveryFee: 30 });
    await setDoc(doc(db, 'products', 'prod-sale'), {
      name: 'منتج خصم', price: 300, categoryId: 'cat-1', inStock: true,
    });
    await setDoc(doc(db, 'inventory', 'prod-sale'), {
      productId: 'prod-sale', stock: 10, reserved: 0, minStock: 5, costPrice: 150,
    });
    for (let n = 7; n <= 14; n++) {
      await setDoc(doc(db, 'products', `prod-${n}`), {
        name: `منتج ${n}`, price: 100, categoryId: 'cat-1', inStock: true,
      });
      await setDoc(doc(db, 'inventory', `prod-${n}`), {
        productId: `prod-${n}`, stock: 30, reserved: 0, minStock: 5, costPrice: 50,
      });
    }
    await setDoc(doc(db, 'products', 'prod-150'), {
      name: 'منتج 150', price: 150, categoryId: 'cat-1', inStock: true,
    });
    await setDoc(doc(db, 'inventory', 'prod-150'), {
      productId: 'prod-150', stock: 10, reserved: 0, minStock: 5, costPrice: 75,
    });
    await setDoc(doc(db, 'products', 'prod-149'), {
      name: 'منتج 149', price: 149, categoryId: 'cat-1', inStock: true,
    });
    await setDoc(doc(db, 'inventory', 'prod-149'), {
      productId: 'prod-149', stock: 10, reserved: 0, minStock: 5, costPrice: 75,
    });
    await setDoc(doc(db, 'products', 'prod-305'), {
      name: 'منتج 305', price: 305, categoryId: 'cat-1', inStock: true,
    });
    await setDoc(doc(db, 'inventory', 'prod-305'), {
      productId: 'prod-305', stock: 10, reserved: 0, minStock: 5, costPrice: 150,
    });
    // Incomplete orders (2026-11-27): dedicated out-of-stock product
    // (price 100, stock 2, reserved 0) for the per-line availability
    // guard tests, plus the seeded governorate list (public read).
    await setDoc(doc(db, 'products', 'prod-oos-1'), {
      name: 'منتج نفاد', price: 100, categoryId: 'cat-1', inStock: true,
    });
    await setDoc(doc(db, 'inventory', 'prod-oos-1'), {
      productId: 'prod-oos-1', stock: 2, reserved: 0, minStock: 5, costPrice: 50,
    });
    await setDoc(doc(db, 'storeSettings', 'governorates'), {
      entries: [
        { id: 'cairo', name: 'القاهرة', active: true },
        { id: 'giza', name: 'الجيزة', active: true },
      ],
      updatedAt: serverTimestamp(), operationId: 'seed-gov',
    });
    for (const code of ['CAP10A', 'CAP10B', 'CAP10C', 'CAP10D', 'CAP10E', 'CAP10F', 'CAP10G']) {
      await setDoc(doc(db, 'discounts', code), {
        percent: 10, active: true, usedBy: null, expiresAt: null,
      });
    }
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
      name: 'أحمد', email: 'a@test.com', phone: '01012345678',
      message: 'شكوى تجريبية كافية الطول', createdAt: serverTimestamp(),
    });
    await setDoc(doc(db, 'feedback', 'fb-2'), {
      name: 'منى', email: 'm@test.com', phone: '01123456789',
      message: 'شكوى تجريبية ثانية كافية الطول', createdAt: serverTimestamp(),
    });
    await setDoc(doc(db, 'storeSettings', 'activeTemplate'), {
      templateId: 'classic',
      bundleVersion: '1.0.0',
      bundleHash: 'c'.repeat(64),
      previousTemplateId: 'classic',
      history: [{
        templateId: 'classic', bundleVersion: '1.0.0',
        bundleHash: 'c'.repeat(64),
        at: Timestamp.now(), by: ADMIN_UID,
      }],
    });
    await setDoc(doc(db, 'templates', 'tpl-live'), { name: 'Live', status: 'active' });
    await setDoc(doc(db, 'templates', 'tpl-draft'), { name: 'Draft', status: 'draft' });
    // Templates bundle model (2026-11-27, spec entries 10/20): new-shape
    // registry docs for the pointer/rollback tests. Hashes are 64-hex
    // placeholders (rules-disabled seeds bypass the shape check).
    // 'boutique' is deliberately NOT seeded — the create tests use it.
    await setDoc(doc(db, 'templates', 'bazaar'), {
      id: 'bazaar', nameAr: 'بازار', nameEn: 'Deal Bazaar',
      version: '1.0.0', shellMinVersion: '1.0.0', bundleHash: 'a'.repeat(64),
      status: 'approved',
      approval: { approver: ADMIN_UID, timestamp: serverTimestamp(), shellVersion: '1.0.0', bundleHash: 'a'.repeat(64) },
    });
    await setDoc(doc(db, 'templates', 'gallery'), {
      id: 'gallery', nameAr: 'معرض', nameEn: 'White Gallery',
      version: '1.0.0', shellMinVersion: '1.0.0', bundleHash: 'b'.repeat(64),
      status: 'approved',
      approval: { approver: ADMIN_UID, timestamp: serverTimestamp(), shellVersion: '1.0.0', bundleHash: 'b'.repeat(64) },
    });
    await setDoc(doc(db, 'templates', 'classic'), {
      id: 'classic', nameAr: 'الكلاسيكي', nameEn: 'Classic',
      version: '1.0.0', shellMinVersion: '1.0.0', bundleHash: 'c'.repeat(64),
      status: 'active',
    });
    await setDoc(doc(db, 'templates', 'scroll'), {
      id: 'scroll', nameAr: 'اسكرول', nameEn: 'Scroll',
      version: '1.0.0', shellMinVersion: '1.0.0', bundleHash: 'a'.repeat(64),
      status: 'draft',
    });
    await setDoc(doc(db, 'templates', 'speclab'), {
      id: 'speclab', nameAr: 'قارن', nameEn: 'Spec Lab',
      version: '1.0.0', shellMinVersion: '1.0.0', bundleHash: 'a'.repeat(64),
      status: 'retired',
    });
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
 * transaction's writes, so a denial isolates the order rule.
 * Pricing Phase A: `basePrice` (undefined = old-shape 4-key line;
 * null or int = new-shape 5-key line) and `auditOmit` (audit docIds
 * entries to leave out, to pin the audit-coverage rule). The audit
 * entry covers status + total, plus the money fields and 'items'
 * when the order carries them — the same list the client must
 * write, so a denial isolates the order rule and not the audit. */
async function rawOrderBatch(db, {
  orderId, productId, productName, price, qty, stock, reserved,
  costPrice = 100,
  basePrice = undefined, omit = [], overrides = {}, auditOmit = [],
  /* Incomplete orders (2026-11-27): skip the inventory reservation
   * + movement writes so a denial isolates the ORDER rule's own
   * per-line availability guard — with the reserve write present,
   * an over-quantity batch is denied on the inventory write first
   * (reserved would exceed stock). */
  skipInventory = false,
  /* Multi-line orders for the >3-line OOS-guard-skip test:
   * [{productId, productName, price, qty, basePrice?}] — replaces
   * the single-line fields above. Inventory writes are skipped for
   * multi-line batches (the order rule is what is under test). */
  lines = null,
  /* === PROBE ONLY (2026-11-27 bisect, probe branch — never merge):
   * separate write switches + manual shape + discount claim, so the
   * probe tests can add the transaction's writes back one at a time.
   * skipMovement / skipAudit are independent of skipInventory;
   * manual 'admin' | 'manager2' switches the order + audit to the
   * admin_manual shape (test 16/18 mirror); discountCode (+
   * discountPercent) stamps the code fields on the order and writes
   * the single-use claim. */
  skipMovement = false,
  skipAudit = false,
  manual = null,
  discountCode = null,
  discountPercent = null,
}) {
  const auditId = `audit-${orderId}`;
  const now = serverTimestamp();
  const manualUid = manual === 'manager2' ? MANAGER2_UID : ADMIN_UID;
  const items = lines == null
    ? [{ productId, name: productName, price, qty, ...(basePrice !== undefined ? { basePrice } : {}) }]
    : lines.map((l) => ({ productId: l.productId, name: l.productName, price: l.price, qty: l.qty, ...(l.basePrice !== undefined ? { basePrice: l.basePrice } : {}) }));
  const subtotal = items.reduce((sum, it) => sum + it.price * it.qty, 0);
  const discountAmount = discountCode == null ? 0 : Math.round((subtotal * discountPercent) / 100);
  const order = {
    id: orderId, clientOrderId: orderId,
    customerName: 'اختبار', customerPhone: '01012345678', customerAddress: 'القاهرة',
    items,
    subtotal, discountCode, discountPercent, discountAmount, total: subtotal - discountAmount,
    status: 'new', paymentStatus: 'cod_pending',
    source: manual == null ? 'storefront' : 'admin_manual',
    createdBy: manual == null ? null : manualUid, shippingCompanyId: null, trackingNumber: null, notes: null,
    createdAt: now, updatedAt: now,
    acceptedAt: null, deliveredAt: null, cancelledAt: null, cancelReason: null,
    auditId,
  };
  for (const k of omit) delete order[k];
  Object.assign(order, overrides);
  const auditFields = ['status', 'total'];
  if ('saleSavings' in order || 'deliveryFee' in order || 'amountDue' in order) {
    auditFields.push('saleSavings', 'deliveryFee', 'amountDue');
  }
  if (items.some((it) => it.basePrice != null)) auditFields.push('items');
  const auditList = auditFields.filter((f) => !auditOmit.includes(f));
  const batch = writeBatch(db);
  if (!skipInventory && lines == null) {
    batch.set(doc(db, 'inventory', productId), {
      productId, stock, reserved: reserved + qty,
      minStock: 5, costPrice, updatedAt: now,
    }, { merge: true });
  }
  if (!skipMovement && lines == null) {
    batch.set(doc(collection(db, 'movements')), {
      productId, type: 'order_reserve', qty: -qty, orderId,
      source: manual == null ? 'placeOrder' : 'createManualOrder',
      actorUid: manual == null ? null : manualUid, createdAt: now,
    });
  }
  if (discountCode != null) {
    batch.set(doc(db, 'discounts', discountCode), {
      usedBy: orderId, usedAt: now,
    }, { merge: true });
  }
  batch.set(doc(db, 'orders', orderId), order);
  if (!skipAudit) {
  batch.set(doc(db, 'audit', auditId), {
    operationId: auditId,
    actor: manual == null ? 'anonymous' : manualUid,
    actorName: manual == null ? 'storefront' : (manual === 'manager2' ? 'Manager 2' : 'Admin'),
    timestamp: now, collection: 'orders', docId: orderId,
    operation: manual == null ? 'create' : 'manual_order_create',
    changedFields: auditList, oldValues: {},
    newValues: { status: 'new', total: order.total },
    docIds: { [`orders/${orderId}`]: auditList },
    newValuesByDoc: { [`orders/${orderId}`]: { status: 'new', total: order.total } },
    documents: [{ collection: 'orders', docId: orderId, changedFields: auditList, oldValues: {}, newValues: { status: 'new', total: order.total } }],
    source: manual == null ? 'placeOrder' : 'createManualOrder',
  });
  }
  return batch.commit();
}

/* Pricing Phase A: multi-line order transaction mirroring the
 * storefront placeOrderTx, but writing the new-shape money fields.
 * `lines`: [{productId, qty, basePrice}] — basePrice undefined means
 * the line omits basePrice (old-shape line); null means an explicit
 * no-sale line; an int means a sale line. `deliveryFee` undefined
 * means an old-shape order (no new money keys); otherwise the order
 * carries saleSavings + deliveryFee + amountDue (+ attemptId when
 * given), computed from DATABASE prices. The audit entry covers the
 * money fields and 'items' exactly when the order carries them. */
async function placePricingOrderTx(db, {
  orderId, lines, discountCode = null,
  deliveryFee = undefined, attemptId = undefined,
  source = 'storefront', createdBy = null,
  actor = 'anonymous', actorName = 'storefront', operation = 'create',
  movementSource = 'placeOrder',
}) {
  const auditId = `audit-${orderId}`;
  const newShape = deliveryFee !== undefined;
  await runTransaction(db, async (tx) => {
    const existing = await tx.get(doc(db, 'orders', orderId));
    if (existing.exists()) throw new Error('order already exists');
    let subtotal = 0;
    let saleSavings = 0;
    const orderLines = [];
    for (const line of lines) {
      const productSnap = await tx.get(doc(db, 'products', line.productId));
      const product = productSnap.data();
      const invSnap = await tx.get(doc(db, 'inventory', line.productId));
      const inv = invSnap.data();
      const price = product.price;
      subtotal += price * line.qty;
      if (line.basePrice != null) saleSavings += (line.basePrice - price) * line.qty;
      orderLines.push({
        productId: line.productId, name: product.name, price,
        qty: line.qty, inv, basePrice: line.basePrice,
      });
    }
    let discount = null;
    if (discountCode) {
      const discSnap = await tx.get(doc(db, 'discounts', discountCode));
      const rec = discSnap.data();
      discount = { code: discountCode, percent: rec.percent };
    }
    const discountPercent = discount ? discount.percent : null;
    const discountAmount = discount ? Math.round((subtotal * discount.percent) / 100) : 0;
    const total = subtotal - discountAmount;
    const now = serverTimestamp();
    for (const l of orderLines) {
      tx.set(doc(db, 'inventory', l.productId), {
        productId: l.productId, stock: l.inv.stock, reserved: l.inv.reserved + l.qty,
        minStock: l.inv.minStock, costPrice: l.inv.costPrice, updatedAt: now,
      }, { merge: true });
      tx.set(doc(collection(db, 'movements')), {
        productId: l.productId, type: 'order_reserve', qty: -l.qty, orderId,
        source: movementSource, actorUid: createdBy, createdAt: now,
      });
    }
    if (discount) {
      tx.set(doc(db, 'discounts', discount.code), { usedBy: orderId, usedAt: now }, { merge: true });
    }
    const items = orderLines.map((l) => {
      const item = { productId: l.productId, name: l.name, price: l.price, qty: l.qty };
      if (l.basePrice !== undefined) item.basePrice = l.basePrice;
      return item;
    });
    const order = {
      id: orderId, clientOrderId: orderId,
      customerName: 'اختبار', customerPhone: '01012345678', customerAddress: 'القاهرة',
      items,
      subtotal, discountCode: discount ? discount.code : null,
      discountPercent, discountAmount, total,
      status: 'new', paymentStatus: 'cod_pending', source,
      createdBy, shippingCompanyId: null, trackingNumber: null, notes: null,
      createdAt: now, updatedAt: now,
      acceptedAt: null, deliveredAt: null, cancelledAt: null, cancelReason: null,
      auditId,
    };
    const auditFields = ['status', 'total'];
    if (newShape) {
      order.saleSavings = saleSavings;
      order.deliveryFee = deliveryFee;
      order.amountDue = total + deliveryFee;
      auditFields.push('saleSavings', 'deliveryFee', 'amountDue');
      if (orderLines.some((l) => l.basePrice != null)) auditFields.push('items');
      if (attemptId !== undefined) order.attemptId = attemptId;
    }
    tx.set(doc(db, 'orders', orderId), order);
    tx.set(doc(db, 'audit', auditId), {
      operationId: auditId, actor, actorName,
      timestamp: now, collection: 'orders', docId: orderId, operation,
      changedFields: auditFields, oldValues: {},
      newValues: { status: 'new', total },
      docIds: { [`orders/${orderId}`]: auditFields },
      newValuesByDoc: { [`orders/${orderId}`]: { status: 'new', total } },
      documents: [{ collection: 'orders', docId: orderId, changedFields: auditFields, oldValues: {}, newValues: { status: 'new', total } }],
      source: movementSource,
    });
  });
  return orderId;
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

/* === PROBE ONLY — line-validation bisect (2026-11-27), probe branch,
 * NEVER MERGE. Step 1: order create alone. Mirror of test 16
 * (admin manual 1-line, old shape, no code) via rawOrderBatch, so
 * no client reads are evaluated — the batch cost is the writes
 * only. prod-5: price 300, stock 10, costPrice 150. */
const PROBE_BASE = {
  productId: 'prod-5', productName: 'سماعة سلكية', price: 300,
  qty: 1, stock: 10, costPrice: 150,
};
async function probeReserved() {
  return (await getDoc(doc(adminDb(), 'inventory', 'prod-5'))).data().reserved;
}

test('PROBE 1a: order create ALONE (admin manual 1-line, no inventory/movement/audit/claim)', async () => {
  const db = adminDb();
  // No audit entry exists, so orderAuditOk is false — expect a CLEAN
  // denial. A max-expr death here instead would mean the order
  // shape/discount/audit evaluation alone already exceeds budget.
  await assertFails(rawOrderBatch(db, {
    ...PROBE_BASE, orderId: 'probe-1a',
    reserved: await probeReserved(), manual: 'admin',
    skipInventory: true, skipMovement: true, skipAudit: true,
  }));
});

test('PROBE 1b: order + audit only (admin manual 1-line)', async () => {
  const db = adminDb();
  await assertSucceeds(rawOrderBatch(db, {
    ...PROBE_BASE, orderId: 'probe-1b',
    reserved: await probeReserved(), manual: 'admin',
    skipInventory: true, skipMovement: true,
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'probe-1b'))).data().source, 'admin_manual');
});

test('PROBE 1c: order + audit only (manager2 manual 1-line)', async () => {
  const db = manager2Db();
  await assertSucceeds(rawOrderBatch(db, {
    ...PROBE_BASE, orderId: 'probe-1c',
    reserved: await probeReserved(), manual: 'manager2',
    skipInventory: true, skipMovement: true,
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'probe-1c'))).data().source, 'admin_manual');
});

/* === PROBE ONLY — step 2: add writes back one at a time (same
 * admin manual 1-line shape). Fresh discount codes are created
 * inside the tests (auditedSet, as test 19 does for OPID10) so no
 * later test's code is consumed. */
async function probeMakeCode(code) {
  await auditedSet(adminDb(), ADMIN_UID, {
    collection: 'discounts', docId: code,
    data: { percent: 10, active: true, usedBy: null, expiresAt: null },
    operation: 'create', sensitive: { percent: 10 },
  });
}

test('PROBE 2a: order + inventory (admin manual 1-line, no movement/audit)', async () => {
  const db = adminDb();
  await assertFails(rawOrderBatch(db, {
    ...PROBE_BASE, orderId: 'probe-2a',
    reserved: await probeReserved(), manual: 'admin',
    skipMovement: true, skipAudit: true,
  }));
});

test('PROBE 2b: order + inventory + movement (admin manual 1-line, no audit)', async () => {
  const db = adminDb();
  await assertFails(rawOrderBatch(db, {
    ...PROBE_BASE, orderId: 'probe-2b',
    reserved: await probeReserved(), manual: 'admin',
    skipAudit: true,
  }));
});

test('PROBE 2c: order + inventory + movement + audit, full no-code (admin manual 1-line)', async () => {
  const db = adminDb();
  await assertSucceeds(rawOrderBatch(db, {
    ...PROBE_BASE, orderId: 'probe-2c',
    reserved: await probeReserved(), manual: 'admin',
  }));
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-5'))).data().reserved, 3);
});

test('PROBE 2d: full + discount claim (admin manual 1-line + code)', async () => {
  await probeMakeCode('PROBE10A');
  const db = adminDb();
  await assertSucceeds(rawOrderBatch(db, {
    ...PROBE_BASE, orderId: 'probe-2d',
    reserved: await probeReserved(), manual: 'admin',
    discountCode: 'PROBE10A', discountPercent: 10,
  }));
  assert.equal((await getDoc(doc(adminDb(), 'discounts', 'PROBE10A'))).data().usedBy, 'probe-2d');
});

test('PROBE 2e: full no-code (manager2 manual 1-line)', async () => {
  const db = manager2Db();
  await assertSucceeds(rawOrderBatch(db, {
    ...PROBE_BASE, orderId: 'probe-2e',
    reserved: await probeReserved(), manual: 'manager2',
  }));
});

test('PROBE 2f: full + discount claim (manager2 manual 1-line + code)', async () => {
  await probeMakeCode('PROBE10C');
  const db = manager2Db();
  await assertSucceeds(rawOrderBatch(db, {
    ...PROBE_BASE, orderId: 'probe-2f',
    reserved: await probeReserved(), manual: 'manager2',
    discountCode: 'PROBE10C', discountPercent: 10,
  }));
  assert.equal((await getDoc(doc(adminDb(), 'discounts', 'PROBE10C'))).data().usedBy, 'probe-2f');
});

test('PROBE 2g: full sale + code (admin manual 1-line, basePrice 400, new-money shape)', async () => {
  await probeMakeCode('PROBE10B');
  const db = adminDb();
  // price 300, basePrice 400 -> saleSavings 100; 10% code -> total
  // 270, deliveryFee 30 -> amountDue 300.
  await assertSucceeds(rawOrderBatch(db, {
    ...PROBE_BASE, orderId: 'probe-2g',
    reserved: await probeReserved(), manual: 'admin',
    basePrice: 400, discountCode: 'PROBE10B', discountPercent: 10,
    overrides: { saleSavings: 100, deliveryFee: 30, amountDue: 300 },
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'probe-2g'))).data().saleSavings, 100);
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
  // OPID10 must be created WITH its audit entry: discounts create is
  // audited, so a bare setDoc (no operationId, no audit) is denied by
  // the rules (fix 2026-11-27 — the old bare setDoc errored on the
  // missing operationId and the test failed at setup, before the
  // order it was meant to set up).
  await auditedSet(db, ADMIN_UID, {
    collection: 'discounts', docId: 'OPID10',
    data: { percent: 10, active: true, usedBy: null, expiresAt: null },
    operation: 'create', sensitive: { percent: 10 },
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
    name: 'اختبار', email: 'test@example.com', phone: '01012345678',
    message: 'رسالة شكوى كافية الطول', createdAt: serverTimestamp(),
  }));
});

test('No-functions: a complaint with an empty email succeeds (email is optional)', async () => {
  const db = anonDb();
  await assertSucceeds(setDoc(doc(collection(db, 'feedback')), {
    name: 'اختبار', email: '', phone: '01012345678',
    message: 'رسالة شكوى كافية الطول', createdAt: serverTimestamp(),
  }));
});

test('No-functions: a complaint with a bad shape is rejected', async () => {
  const db = anonDb();
  // Extra field (the old Phase 3 shape is gone).
  await assertFails(setDoc(doc(collection(db, 'feedback')), {
    name: 'اختبار', email: 'test@example.com', phone: '01012345678',
    message: 'رسالة شكوى كافية الطول', status: 'new', createdAt: serverTimestamp(),
  }));
  // Message shorter than 10 chars.
  await assertFails(setDoc(doc(collection(db, 'feedback')), {
    name: 'اختبار', email: 'test@example.com', phone: '01012345678',
    message: 'قصير', createdAt: serverTimestamp(),
  }));
  // Email without '@'.
  await assertFails(setDoc(doc(collection(db, 'feedback')), {
    name: 'اختبار', email: 'not-an-email', phone: '01012345678',
    message: 'رسالة شكوى كافية الطول', createdAt: serverTimestamp(),
  }));
  // Phone shorter than 10 digits.
  await assertFails(setDoc(doc(collection(db, 'feedback')), {
    name: 'اختبار', email: 'test@example.com', phone: '010123456',
    message: 'رسالة شكوى كافية الطول', createdAt: serverTimestamp(),
  }));
  // Phone with non-digits.
  await assertFails(setDoc(doc(collection(db, 'feedback')), {
    name: 'اختبار', email: 'test@example.com', phone: '010-abc-4567',
    message: 'رسالة شكوى كافية الطول', createdAt: serverTimestamp(),
  }));
  // Old shape: address instead of phone.
  await assertFails(setDoc(doc(collection(db, 'feedback')), {
    name: 'اختبار', email: 'test@example.com', address: 'القاهرة',
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

/* ---------- Pricing Phase A (2026-11-27): per-product sale prices
 * + fixed delivery fee (Model P, fee split per decision D2). Runs
 * last: the product tests mutate prod-sale, the order tests reserve
 * prod-4 / prod-7..14 / prod-149 / prod-150 / prod-305, and the
 * settings test temporarily clears the fee field. ---------- */

/* Product rule: basePrice >= price passes, and the audit entry must
 * record the changed basePrice (sensitiveValuesOk gain). */
test('Pricing A: an admin product save with basePrice >= price passes', async () => {
  const db = adminDb();
  await assertSucceeds(auditedSet(db, ADMIN_UID, {
    collection: 'products', docId: 'prod-sale',
    data: { basePrice: 500 }, sensitive: { basePrice: 500 },
  }));
  assert.equal((await getDoc(doc(db, 'products', 'prod-sale'))).data().basePrice, 500);
});

test('Pricing A: an admin product save with basePrice < price is denied', async () => {
  const db = adminDb();
  await assertFails(auditedSet(db, ADMIN_UID, {
    collection: 'products', docId: 'prod-sale',
    data: { basePrice: 100 }, sensitive: { basePrice: 100 },
  }));
  assert.equal((await getDoc(doc(db, 'products', 'prod-sale'))).data().basePrice, 500);
});

test('Pricing A: an admin product save with a FRACTIONAL basePrice is denied', async () => {
  const db = adminDb();
  await assertFails(auditedSet(db, ADMIN_UID, {
    collection: 'products', docId: 'prod-sale',
    data: { basePrice: 499.5 }, sensitive: { basePrice: 499.5 },
  }));
  assert.equal((await getDoc(doc(db, 'products', 'prod-sale'))).data().basePrice, 500);
});

test('Pricing A: a fake audit that changes basePrice but does NOT record it is denied', async () => {
  const db = adminDb();
  opCounter += 1;
  const opId = `op-test-${opCounter}`;
  const batch = writeBatch(db);
  batch.set(doc(db, 'products', 'prod-sale'), { basePrice: 450, operationId: opId, updatedAt: serverTimestamp() }, { merge: true });
  batch.set(doc(db, 'audit', opId), {
    operationId: opId, actor: ADMIN_UID, actorName: 'Test Admin',
    timestamp: serverTimestamp(), collection: 'products', docId: 'prod-sale',
    operation: 'update', changedFields: ['basePrice', 'operationId', 'updatedAt'], oldValues: {}, newValues: {},
    docIds: { 'products/prod-sale': ['basePrice', 'operationId', 'updatedAt'] },
    newValuesByDoc: { 'products/prod-sale': {} },
    documents: [{ collection: 'products', docId: 'prod-sale', changedFields: ['basePrice'], oldValues: {}, newValues: {} }],
    source: 'test',
  });
  await assertFails(batch.commit());
  assert.equal((await getDoc(doc(db, 'products', 'prod-sale'))).data().basePrice, 500);
});

/* 1.1.2-style save cases, re-run as regression cases: (1) new
 * product + empty discount field (no basePrice); (2) stock-filled
 * save WITH a discount (product + inventory in one audited batch);
 * (3) edit without a discount (merge preserves the stored basePrice). */
test('Pricing A (1.1.2 regression): a new product with an EMPTY discount field saves', async () => {
  const db = adminDb();
  await assertSucceeds(auditedSet(db, ADMIN_UID, {
    collection: 'products', docId: 'prod-reg-1',
    data: { name: 'منتج اختبار ١', price: 100, categoryId: 'cat-1', inStock: true },
    operation: 'create', sensitive: { price: 100, inStock: true },
  }));
  const data = (await getDoc(doc(db, 'products', 'prod-reg-1'))).data();
  assert.equal(data.price, 100);
  assert.equal('basePrice' in data, false);
});

test('Pricing A (1.1.2 regression): a stock-filled save WITH a discount saves product + inventory', async () => {
  const db = adminDb();
  opCounter += 1;
  const opId = `op-test-${opCounter}`;
  const batch = writeBatch(db);
  batch.set(doc(db, 'products', 'prod-reg-2'), {
    name: 'منتج اختبار ٢', price: 300, categoryId: 'cat-1', inStock: true,
    basePrice: 400, operationId: opId, updatedAt: serverTimestamp(),
  }, { merge: true });
  batch.set(doc(db, 'inventory', 'prod-reg-2'), {
    productId: 'prod-reg-2', stock: 10, reserved: 0, minStock: 5, costPrice: 150,
    operationId: opId, updatedAt: serverTimestamp(),
  }, { merge: true });
  const changedProd = ['name', 'price', 'categoryId', 'inStock', 'basePrice', 'operationId', 'updatedAt'];
  const changedInv = ['productId', 'stock', 'reserved', 'minStock', 'costPrice', 'operationId', 'updatedAt'];
  batch.set(doc(db, 'audit', opId), {
    operationId: opId, actor: ADMIN_UID, actorName: 'Test Admin',
    timestamp: serverTimestamp(), collection: 'products', docId: 'prod-reg-2',
    operation: 'product_create', changedFields: changedProd, oldValues: {},
    newValues: { price: 300, basePrice: 400, inStock: true },
    docIds: { 'products/prod-reg-2': changedProd, 'inventory/prod-reg-2': changedInv },
    newValuesByDoc: {
      'products/prod-reg-2': { price: 300, basePrice: 400, inStock: true },
      'inventory/prod-reg-2': { stock: 10, reserved: 0 },
    },
    documents: [],
    source: 'test',
  });
  await assertSucceeds(batch.commit());
  assert.equal((await getDoc(doc(db, 'products', 'prod-reg-2'))).data().basePrice, 400);
  assert.equal((await getDoc(doc(db, 'inventory', 'prod-reg-2'))).data().stock, 10);
});

test('Pricing A (1.1.2 regression): an edit WITHOUT a discount keeps the stored basePrice', async () => {
  const db = adminDb();
  await assertSucceeds(auditedSet(db, ADMIN_UID, {
    collection: 'products', docId: 'prod-sale',
    data: { price: 320 }, sensitive: { price: 320 },
  }));
  const data = (await getDoc(doc(db, 'products', 'prod-sale'))).data();
  assert.equal(data.price, 320);
  assert.equal(data.basePrice, 500);
});

/* Shared numeric matrix (Verification Plan, cases A–D, F, G) against
 * the rules. Case E is display-only (the % is derived at render and
 * never stored) — its saving (50) is covered by the saleSavings
 * invariant in cases A/D. */

test('Pricing A (matrix A): a storefront order with a sale + fee passes', async () => {
  const db = anonDb();
  await assertSucceeds(placePricingOrderTx(db, {
    orderId: 'order-pricing-A',
    lines: [{ productId: 'prod-4', qty: 1, basePrice: 500 }],
    deliveryFee: 30, attemptId: 'a-pricing-A',
  }));
  const order = (await getDoc(doc(adminDb(), 'orders', 'order-pricing-A'))).data();
  assert.equal(order.subtotal, 300);
  assert.equal(order.saleSavings, 200);
  assert.equal(order.discountAmount, 0);
  assert.equal(order.total, 300);
  assert.equal(order.deliveryFee, 30);
  assert.equal(order.amountDue, 330);
  assert.equal(order.items[0].basePrice, 500);
  assert.equal(order.attemptId, 'a-pricing-A');
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-4'))).data().reserved, 1);
});

test('Pricing A (matrix B): a storefront order with fee 0 passes', async () => {
  const db = anonDb();
  await assertSucceeds(placePricingOrderTx(db, {
    orderId: 'order-pricing-B',
    lines: [{ productId: 'prod-4', qty: 1, basePrice: 500 }],
    deliveryFee: 0, attemptId: 'a-pricing-B',
  }));
  const order = (await getDoc(doc(adminDb(), 'orders', 'order-pricing-B'))).data();
  assert.equal(order.deliveryFee, 0);
  assert.equal(order.amountDue, 300);
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-4'))).data().reserved, 2);
});

test('Pricing A (matrix C): a storefront order with a code on a sale passes', async () => {
  const db = anonDb();
  await assertSucceeds(placePricingOrderTx(db, {
    orderId: 'order-pricing-C',
    lines: [{ productId: 'prod-4', qty: 1, basePrice: 500 }],
    discountCode: 'CAP10D', deliveryFee: 30, attemptId: 'a-pricing-C',
  }));
  const order = (await getDoc(doc(adminDb(), 'orders', 'order-pricing-C'))).data();
  assert.equal(order.saleSavings, 200);
  assert.equal(order.discountAmount, 30);
  assert.equal(order.total, 270);
  assert.equal(order.amountDue, 300);
  assert.equal((await getDoc(doc(adminDb(), 'discounts', 'CAP10D'))).data().usedBy, 'order-pricing-C');
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-4'))).data().reserved, 3);
});

test('Pricing A (matrix D): a multi-line storefront order passes', async () => {
  const db = anonDb();
  await assertSucceeds(placePricingOrderTx(db, {
    orderId: 'order-pricing-D',
    lines: [
      { productId: 'prod-4', qty: 2, basePrice: 500 },
      { productId: 'prod-150', qty: 1, basePrice: null },
    ],
    deliveryFee: 30, attemptId: 'a-pricing-D',
  }));
  const order = (await getDoc(doc(adminDb(), 'orders', 'order-pricing-D'))).data();
  assert.equal(order.subtotal, 750);
  assert.equal(order.saleSavings, 400);
  assert.equal(order.total, 750);
  assert.equal(order.amountDue, 780);
  assert.equal(order.items[0].basePrice, 500);
  assert.equal(order.items[1].basePrice, null);
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-4'))).data().reserved, 5);
});

test('Pricing A (matrix F): a code discount rounds 14.9 up to 15', async () => {
  const db = anonDb();
  await assertSucceeds(placePricingOrderTx(db, {
    orderId: 'order-pricing-F',
    lines: [{ productId: 'prod-149', qty: 1, basePrice: null }],
    discountCode: 'CAP10F', deliveryFee: 30,
  }));
  const order = (await getDoc(doc(adminDb(), 'orders', 'order-pricing-F'))).data();
  assert.equal(order.discountAmount, 15);
  assert.equal(order.total, 134);
  assert.equal(order.amountDue, 164);
  assert.equal(order.saleSavings, 0);
});

test('Pricing A (matrix G): a code discount rounds 30.5 up to 31 (halves up)', async () => {
  const db = anonDb();
  await assertSucceeds(placePricingOrderTx(db, {
    orderId: 'order-pricing-G',
    lines: [{ productId: 'prod-305', qty: 1, basePrice: null }],
    discountCode: 'CAP10E', deliveryFee: 30,
  }));
  const order = (await getDoc(doc(adminDb(), 'orders', 'order-pricing-G'))).data();
  assert.equal(order.discountAmount, 31);
  assert.equal(order.total, 274);
  assert.equal(order.amountDue, 304);
});

test('Pricing A: a code discount of 30 on a 305 subtotal is denied (interval)', async () => {
  const db = anonDb();
  await assertFails(rawOrderBatch(db, {
    orderId: 'order-pricing-g-bad', productId: 'prod-305', productName: 'منتج 305',
    price: 305, qty: 1, stock: 10, reserved: 1, basePrice: null,
    overrides: {
      discountCode: 'CAP10G', discountPercent: 10, discountAmount: 30, total: 275,
      saleSavings: 0, deliveryFee: 30, amountDue: 305,
    },
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'order-pricing-g-bad'))).exists(), false);
  assert.equal((await getDoc(doc(adminDb(), 'discounts', 'CAP10G'))).data().usedBy, null);
});

test('Pricing A: a saleSavings mismatch is denied', async () => {
  const db = anonDb();
  await assertFails(rawOrderBatch(db, {
    orderId: 'order-pricing-sav-bad', productId: 'prod-4', productName: 'جراب موبايل',
    price: 300, qty: 1, stock: 10, reserved: 5, basePrice: 500,
    overrides: { saleSavings: 199, deliveryFee: 30, amountDue: 330 },
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'order-pricing-sav-bad'))).exists(), false);
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-4'))).data().reserved, 5);
});

test('Pricing A: an amountDue mismatch is denied', async () => {
  const db = anonDb();
  await assertFails(rawOrderBatch(db, {
    orderId: 'order-pricing-due-bad', productId: 'prod-4', productName: 'جراب موبايل',
    price: 300, qty: 1, stock: 10, reserved: 5, basePrice: 500,
    overrides: { saleSavings: 200, deliveryFee: 30, amountDue: 331 },
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'order-pricing-due-bad'))).exists(), false);
});

test('Pricing A: a deliveryFee != settings is denied on an anonymous create', async () => {
  const db = anonDb();
  // amountDue is consistent with the forged fee (300 + 40) — only
  // the fee check against settings (30) must deny it.
  await assertFails(rawOrderBatch(db, {
    orderId: 'order-pricing-fee-bad', productId: 'prod-4', productName: 'جراب موبايل',
    price: 300, qty: 1, stock: 10, reserved: 5, basePrice: 500,
    overrides: { saleSavings: 200, deliveryFee: 40, amountDue: 340 },
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'order-pricing-fee-bad'))).exists(), false);
});

test('Pricing A: an order carrying one new key without the other two is denied', async () => {
  const db = anonDb();
  await assertFails(rawOrderBatch(db, {
    orderId: 'order-pricing-partial', productId: 'prod-4', productName: 'جراب موبايل',
    price: 300, qty: 1, stock: 10, reserved: 5, basePrice: 500,
    overrides: { saleSavings: 200, amountDue: 330 },
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'order-pricing-partial'))).exists(), false);
});

test('Pricing A: a missing fee field denies a storefront create but allows a manual create', async () => {
  // Clear the fee field from the settings doc (rules-disabled), so
  // the storefront fee check has nothing to verify against.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'storeSettings', 'settings'), {});
  });
  const anon = anonDb();
  await assertFails(placePricingOrderTx(anon, {
    orderId: 'order-pricing-nofee-sf',
    lines: [{ productId: 'prod-4', qty: 1, basePrice: 500 }],
    deliveryFee: 30,
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'order-pricing-nofee-sf'))).exists(), false);
  // The manual path is client-asserted (fee split, decision D2):
  // no fee get, so the same order shape passes without a fee field.
  const admin = adminDb();
  await assertSucceeds(placePricingOrderTx(admin, {
    orderId: 'order-pricing-nofee-manual',
    lines: [{ productId: 'prod-4', qty: 1, basePrice: 500 }],
    deliveryFee: 30,
    source: 'admin_manual', createdBy: ADMIN_UID,
    actor: ADMIN_UID, actorName: 'Admin', operation: 'manual_order_create',
    movementSource: 'createManualOrder',
  }));
  const order = (await getDoc(doc(adminDb(), 'orders', 'order-pricing-nofee-manual'))).data();
  assert.equal(order.deliveryFee, 30);
  assert.equal(order.amountDue, 330);
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-4'))).data().reserved, 6);
  // Restore the fee field for the tests below.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'storeSettings', 'settings'), { deliveryFee: 30 });
  });
});

test('Pricing A: a 7-line manual order with a code passes (exactly 10 gets)', async () => {
  const db = adminDb();
  const lines = [];
  for (let n = 7; n <= 13; n++) lines.push({ productId: `prod-${n}`, qty: 1, basePrice: null });
  await assertSucceeds(placePricingOrderTx(db, {
    orderId: 'order-pricing-manual-7',
    lines, discountCode: 'CAP10A', deliveryFee: 30,
    source: 'admin_manual', createdBy: ADMIN_UID,
    actor: ADMIN_UID, actorName: 'Admin', operation: 'manual_order_create',
    movementSource: 'createManualOrder',
  }));
  const order = (await getDoc(doc(db, 'orders', 'order-pricing-manual-7'))).data();
  assert.equal(order.items.length, 7);
  assert.equal(order.subtotal, 700);
  assert.equal(order.discountAmount, 70);
  assert.equal(order.total, 630);
  assert.equal(order.saleSavings, 0);
  assert.equal(order.deliveryFee, 30);
  assert.equal(order.amountDue, 660);
  assert.equal(order.attemptId, undefined);
  assert.equal((await getDoc(doc(db, 'discounts', 'CAP10A'))).data().usedBy, 'order-pricing-manual-7');
});

test('Pricing A: an 8-line storefront order with a code is denied by the 10-get limit', async () => {
  const db = anonDb();
  const lines = [];
  for (let n = 7; n <= 14; n++) lines.push({ productId: `prod-${n}`, qty: 1, basePrice: null });
  // 8 product gets + 1 audit getAfter + 1 fee get + 1 code get = 11 > 10
  // — the documented cap, not a bug.
  await assertFails(placePricingOrderTx(db, {
    orderId: 'order-pricing-sf-8-code',
    lines, discountCode: 'CAP10B', deliveryFee: 30,
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'order-pricing-sf-8-code'))).exists(), false);
  assert.equal((await getDoc(doc(adminDb(), 'discounts', 'CAP10B'))).data().usedBy, null);
});

test('Pricing A: a 7-line storefront order with a code passes (exactly 10 gets)', async () => {
  const db = anonDb();
  const lines = [];
  for (let n = 7; n <= 13; n++) lines.push({ productId: `prod-${n}`, qty: 1, basePrice: null });
  await assertSucceeds(placePricingOrderTx(db, {
    orderId: 'order-pricing-sf-7-code',
    lines, discountCode: 'CAP10C', deliveryFee: 30,
  }));
  const order = (await getDoc(doc(adminDb(), 'orders', 'order-pricing-sf-7-code'))).data();
  assert.equal(order.subtotal, 700);
  assert.equal(order.discountAmount, 70);
  assert.equal(order.total, 630);
  assert.equal(order.amountDue, 660);
});

test('Pricing A: an 8-line storefront order WITHOUT a code passes (exactly 10 gets)', async () => {
  const db = anonDb();
  const lines = [];
  for (let n = 7; n <= 14; n++) lines.push({ productId: `prod-${n}`, qty: 1, basePrice: null });
  // Control for the 8-with-code denial above: 8 + 1 audit + 1 fee = 10.
  await assertSucceeds(placePricingOrderTx(db, {
    orderId: 'order-pricing-sf-8-nocode',
    lines, deliveryFee: 30,
  }));
  const order = (await getDoc(doc(adminDb(), 'orders', 'order-pricing-sf-8-nocode'))).data();
  assert.equal(order.subtotal, 800);
  assert.equal(order.total, 800);
  assert.equal(order.amountDue, 830);
});

test('Pricing A: an order audit that does NOT cover the money fields is denied', async () => {
  const db = anonDb();
  const base = {
    productId: 'prod-4', productName: 'جراب موبايل',
    price: 300, qty: 1, stock: 10, reserved: 6, basePrice: 500,
    overrides: { saleSavings: 200, deliveryFee: 30, amountDue: 330 },
  };
  // Audit lists status/total/saleSavings/amountDue/items but not deliveryFee.
  await assertFails(rawOrderBatch(db, { ...base, orderId: 'order-pricing-audit-1', auditOmit: ['deliveryFee'] }));
  // Audit lists the money fields but not 'items' — the line carries
  // a base price, so the audit must cover 'items' too.
  await assertFails(rawOrderBatch(db, { ...base, orderId: 'order-pricing-audit-2', auditOmit: ['items'] }));
  for (const id of ['order-pricing-audit-1', 'order-pricing-audit-2']) {
    assert.equal((await getDoc(doc(adminDb(), 'orders', id))).exists(), false);
  }
  assert.equal((await getDoc(doc(adminDb(), 'inventory', 'prod-4'))).data().reserved, 6);
});

/* ---------- Pricing Phase A: attempt-doc shape check (§11 / M21) ---------- */

test('Pricing A: a valid attempt create + failure-field update passes', async () => {
  const db = anonDb();
  await assertSucceeds(setDoc(doc(db, 'analytics', 'attempts', 'items', 'att-pricing-1'), {
    startedAt: serverTimestamp(), ordered: false,
  }));
  await assertSucceeds(updateDoc(doc(db, 'analytics', 'attempts', 'items', 'att-pricing-1'), {
    contactName: 'اختبار', contactPhone: '01012345678', contactAddress: 'القاهرة',
    errorCode: 'PRICE_CHANGED',
    seenPrices: { 'prod-4': 300 }, seenBasePrices: { 'prod-4': 500 },
    seenTotal: 330, seenDeliveryFee: 30, clientOrderId: 'order-pricing-A',
  }));
  const data = (await getDoc(doc(adminDb(), 'analytics', 'attempts', 'items', 'att-pricing-1'))).data();
  assert.equal(data.errorCode, 'PRICE_CHANGED');
  assert.equal(data.seenPrices['prod-4'], 300);
  assert.equal(data.seenDeliveryFee, 30);
  assert.equal(data.clientOrderId, 'order-pricing-A');
});

test('Pricing A: an attempt failure update with FEE_UNSET + current values passes', async () => {
  // Phase C correction: the storefront throws FEE_UNSET when the fee
  // is missing, and recordAttemptFailure writes the current database
  // prices/fee alongside it — all four must be allowed, or that one
  // failure update is denied (silently, best-effort).
  const db = anonDb();
  await assertSucceeds(setDoc(doc(db, 'analytics', 'attempts', 'items', 'att-pricing-2'), {
    startedAt: serverTimestamp(), ordered: false,
  }));
  await assertSucceeds(updateDoc(doc(db, 'analytics', 'attempts', 'items', 'att-pricing-2'), {
    errorCode: 'FEE_UNSET',
    seenPrices: null, seenBasePrices: null, seenDeliveryFee: null,
    currentPrices: { 'prod-4': 300 }, currentBasePrices: { 'prod-4': 500 },
    currentFee: 30, clientOrderId: 'order-pricing-nofee',
  }));
  const data = (await getDoc(doc(adminDb(), 'analytics', 'attempts', 'items', 'att-pricing-2'))).data();
  assert.equal(data.errorCode, 'FEE_UNSET');
  assert.equal(data.currentPrices['prod-4'], 300);
  assert.equal(data.currentBasePrices['prod-4'], 500);
  assert.equal(data.currentFee, 30);
});

test('Pricing A: an attempt create with a BAD errorCode is denied', async () => {
  const db = anonDb();
  await assertFails(setDoc(doc(db, 'analytics', 'attempts', 'items', 'att-pricing-bad-code'), {
    startedAt: serverTimestamp(), ordered: false, errorCode: 'BOGUS_CODE',
  }));
  assert.equal((await getDoc(doc(adminDb(), 'analytics', 'attempts', 'items', 'att-pricing-bad-code'))).exists(), false);
});

test('Pricing A: an attempt create with an EXTRA field is denied', async () => {
  const db = anonDb();
  await assertFails(setDoc(doc(db, 'analytics', 'attempts', 'items', 'att-pricing-extra'), {
    startedAt: serverTimestamp(), ordered: false, fabricated: true,
  }));
  assert.equal((await getDoc(doc(adminDb(), 'analytics', 'attempts', 'items', 'att-pricing-extra'))).exists(), false);
});

test('Pricing A: an attempt create WITHOUT ordered is denied', async () => {
  const db = anonDb();
  await assertFails(setDoc(doc(db, 'analytics', 'attempts', 'items', 'att-pricing-no-ordered'), {
    startedAt: serverTimestamp(),
  }));
  assert.equal((await getDoc(doc(adminDb(), 'analytics', 'attempts', 'items', 'att-pricing-no-ordered'))).exists(), false);
});

test('Pricing A: an attempt update with a NON-MAP seenPrices is denied', async () => {
  const db = anonDb();
  await assertFails(updateDoc(doc(db, 'analytics', 'attempts', 'items', 'att-pricing-1'), {
    seenPrices: 'not-a-map',
  }));
  const data = (await getDoc(doc(adminDb(), 'analytics', 'attempts', 'items', 'att-pricing-1'))).data();
  assert.equal(data.seenPrices['prod-4'], 300);
});

/* ---------- Idempotency probe (rules-header verification) ----------
 * The header comment claims a retry AFTER a successful commit is
 * denied at the probe (anonymous get of an existing order). This
 * test pins the actual rule: the same get inside a transaction is
 * denied too, so placeOrderTx's "return the existing order" branch
 * is unreachable for anonymous retries — the header is correct. */
test('Pricing A: an anonymous transaction read of an EXISTING order is denied', async () => {
  const db = anonDb();
  await assertFails(runTransaction(db, async (tx) => {
    await tx.get(doc(db, 'orders', 'order-pricing-A'));
  }));
  // Control: the probe of a NON-EXISTENT id still works in a transaction.
  await assertSucceeds(runTransaction(db, async (tx) => {
    const snap = await tx.get(doc(db, 'orders', 'order-pricing-nope'));
    assert.equal(snap.exists(), false);
  }));
});

/* ---------- Incomplete orders + journey tracking (2026-11-27) ----
 * Checkout drafts, journey summaries, governorate list + deletion
 * config, exit/footer feedback sources, and the out-of-stock
 * per-line availability guard on orders. Canonical schemas:
 * docs/incomplete-orders-schema.md. */

function validDraft(id, overrides = {}) {
  return {
    sessionId: id, sessionToken: `tok-${id}`,
    name: 'أحمد', phone: '01001234567', phone2: null,
    governorate: null, detailedAddress: null,
    address: 'القاهرة — شارع النيل 5',
    cart: [{ productId: 'prod-1', qty: 1, priceAtDraft: 500, availability: 'ok', availableQty: 5 }],
    status: 'new', completeness: 75,
    orderId: null, mootOrderId: null,
    lastSyncAt: serverTimestamp(), createdAt: serverTimestamp(),
    schemaVersion: 1,
    ...overrides,
  };
}

function validJourney(id, overrides = {}) {
  return {
    sessionId: id, draftId: null, orderId: null,
    startedAt: serverTimestamp(), totalSecondsBand: '10-60s',
    products: [{ productId: 'prod-1', dwellBand: '10-60s', actions: ['view', 'add'] }],
    overflowCount: 0, updatedAt: serverTimestamp(), schemaVersion: 1,
    ...overrides,
  };
}

test('Incomplete orders: anonymous draft create with a valid token succeeds, admin can read it', async () => {
  const db = anonDb();
  await assertSucceeds(setDoc(doc(db, 'checkoutDrafts', 'draft-1'), validDraft('draft-1')));
  const snap = await getDoc(doc(adminDb(), 'checkoutDrafts', 'draft-1'));
  assert.equal(snap.exists(), true);
  assert.equal(snap.data().status, 'new');
  assert.equal(snap.data().phone, '01001234567');
});

test('Incomplete orders: anonymous draft create without a token fails', async () => {
  const db = anonDb();
  await assertFails(setDoc(doc(db, 'checkoutDrafts', 'draft-no-token'),
    validDraft('draft-no-token', { sessionToken: '' })));
});

test('Incomplete orders: anonymous draft create with a non-new status fails', async () => {
  const db = anonDb();
  await assertFails(setDoc(doc(db, 'checkoutDrafts', 'draft-bad-status'),
    validDraft('draft-bad-status', { status: 'contacted' })));
});

test('Incomplete orders: anonymous draft create with an invalid phone fails', async () => {
  const db = anonDb();
  await assertFails(setDoc(doc(db, 'checkoutDrafts', 'draft-bad-phone'),
    validDraft('draft-bad-phone', { phone: '01901234567' })));
  await assertFails(setDoc(doc(db, 'checkoutDrafts', 'draft-bad-phone2'),
    validDraft('draft-bad-phone2', { phone2: '12345' })));
});

test('Incomplete orders: anonymous draft update with the right token succeeds, wrong token fails', async () => {
  const db = anonDb();
  await assertSucceeds(setDoc(doc(db, 'checkoutDrafts', 'draft-2'), validDraft('draft-2')));
  await assertSucceeds(updateDoc(doc(db, 'checkoutDrafts', 'draft-2'), { name: 'أحمد محمد' }));
  const snap = await getDoc(doc(adminDb(), 'checkoutDrafts', 'draft-2'));
  assert.equal(snap.data().name, 'أحمد محمد');
  // A different token may not touch the draft at all.
  await assertFails(updateDoc(doc(db, 'checkoutDrafts', 'draft-2'), {
    name: 'متطفل', sessionToken: 'tok-someone-else',
  }));
  const after = await getDoc(doc(adminDb(), 'checkoutDrafts', 'draft-2'));
  assert.equal(after.data().name, 'أحمد محمد');
});

test('Incomplete orders: anonymous draft update may not change the token or the admin-owned fields', async () => {
  const db = anonDb();
  await assertSucceeds(setDoc(doc(db, 'checkoutDrafts', 'draft-3'), validDraft('draft-3')));
  await assertFails(updateDoc(doc(db, 'checkoutDrafts', 'draft-3'), { sessionToken: 'tok-new' }));
  await assertFails(updateDoc(doc(db, 'checkoutDrafts', 'draft-3'), { status: 'contacted' }));
  await assertFails(updateDoc(doc(db, 'checkoutDrafts', 'draft-3'), { orderId: 'order-x' }));
  await assertFails(updateDoc(doc(db, 'checkoutDrafts', 'draft-3'), { mootOrderId: 'order-y' }));
  const snap = await getDoc(doc(adminDb(), 'checkoutDrafts', 'draft-3'));
  assert.equal(snap.data().sessionToken, 'tok-draft-3');
  assert.equal(snap.data().status, 'new');
});

test('Incomplete orders: anonymous draft read and list are denied, admin read/list succeed', async () => {
  const db = anonDb();
  await assertFails(getDoc(doc(db, 'checkoutDrafts', 'draft-1')));
  await assertFails(getDocs(collection(db, 'checkoutDrafts')));
  const list = await getDocs(collection(adminDb(), 'checkoutDrafts'));
  assert.ok(list.docs.some((d) => d.id === 'draft-1'));
});

test('Incomplete orders: admin may update the status and delete with an audit', async () => {
  await assertSucceeds(setDoc(doc(anonDb(), 'checkoutDrafts', 'draft-4'), validDraft('draft-4')));
  await assertSucceeds(updateDoc(doc(adminDb(), 'checkoutDrafts', 'draft-4'), { status: 'contacted' }));
  const snap = await getDoc(doc(adminDb(), 'checkoutDrafts', 'draft-4'));
  assert.equal(snap.data().status, 'contacted');
  await assertSucceeds(deleteWithAudit(adminDb(), ADMIN_UID, 'checkoutDrafts', 'draft-4'));
  assert.equal((await getDoc(doc(adminDb(), 'checkoutDrafts', 'draft-4'))).exists(), false);
});

test('Journey: anonymous summary create succeeds; 21 entries and an invalid dwell band fail', async () => {
  const db = anonDb();
  await assertSucceeds(setDoc(doc(db, 'journeySummaries', 'journey-1'), validJourney('journey-1')));
  const tooMany = Array.from({ length: 21 }, (_, i) => ({
    productId: `prod-${i}`, dwellBand: '10-60s', actions: ['view'],
  }));
  await assertFails(setDoc(doc(db, 'journeySummaries', 'journey-many'),
    validJourney('journey-many', { products: tooMany })));
  await assertFails(setDoc(doc(db, 'journeySummaries', 'journey-bad-band'),
    validJourney('journey-bad-band', {
      products: [{ productId: 'prod-1', dwellBand: '5s', actions: ['view'] }],
    })));
});

test('Journey: anonymous update keeps the session id, admin read succeeds', async () => {
  const db = anonDb();
  await assertSucceeds(setDoc(doc(db, 'journeySummaries', 'journey-2'), validJourney('journey-2')));
  await assertSucceeds(updateDoc(doc(db, 'journeySummaries', 'journey-2'), { overflowCount: 2 }));
  await assertFails(updateDoc(doc(db, 'journeySummaries', 'journey-2'), { sessionId: 'other-session' }));
  await assertFails(getDoc(doc(db, 'journeySummaries', 'journey-2')));
  const snap = await getDoc(doc(adminDb(), 'journeySummaries', 'journey-2'));
  assert.equal(snap.data().overflowCount, 2);
});

test('Feedback: exit-feedback and footer-feedback may be anonymous (no name/phone); an unknown source fails', async () => {
  const db = anonDb();
  await assertSucceeds(setDoc(doc(collection(db, 'feedback')), {
    name: '', email: '', phone: '',
    message: 'خرجت من المتجر قبل ما أكمل الطلب',
    source: 'exit-feedback', createdAt: serverTimestamp(),
  }));
  await assertSucceeds(setDoc(doc(collection(db, 'feedback')), {
    name: '', email: '', phone: '',
    message: 'ملاحظة من رابط التذييل في أسفل الصفحة',
    source: 'footer-feedback', createdAt: serverTimestamp(),
  }));
  await assertFails(setDoc(doc(collection(db, 'feedback')), {
    name: 'أحمد', email: '', phone: '01001234567',
    message: 'رسالة بمصدر غير معروف تماماً',
    source: 'carrier-pigeon', createdAt: serverTimestamp(),
  }));
});

test('Governorates: public read succeeds, anonymous write fails, admin write is shape-checked', async () => {
  const snap = await getDoc(doc(anonDb(), 'storeSettings', 'governorates'));
  assert.equal(snap.exists(), true);
  assert.equal(snap.data().entries.length, 2);
  await assertFails(setDoc(doc(anonDb(), 'storeSettings', 'governorates'), {
    entries: [{ id: 'cairo', name: 'القاهرة', active: true }],
    updatedAt: serverTimestamp(), operationId: 'anon-gov',
  }));
  const entries27 = Array.from({ length: 27 }, (_, i) => ({
    id: `gov-${i}`, name: `محافظة ${i}`, active: i % 2 === 0,
  }));
  await assertSucceeds(auditedSet(adminDb(), ADMIN_UID, {
    collection: 'storeSettings', docId: 'governorates',
    data: { entries: entries27 }, operation: 'update',
  }));
  const entries28 = Array.from({ length: 28 }, (_, i) => ({
    id: `gov-${i}`, name: `محافظة ${i}`, active: true,
  }));
  await assertFails(auditedSet(adminDb(), ADMIN_UID, {
    collection: 'storeSettings', docId: 'governorates',
    data: { entries: entries28 }, operation: 'update',
  }));
  const after = await getDoc(doc(adminDb(), 'storeSettings', 'governorates'));
  assert.equal(after.data().entries.length, 27);
});

test('Deletion config: autoDeleteDays must be an int 0–365', async () => {
  await assertFails(auditedSet(adminDb(), ADMIN_UID, {
    collection: 'storeSettings', docId: 'deletion',
    data: { autoDeleteDays: 400 }, operation: 'create',
  }));
  await assertSucceeds(auditedSet(adminDb(), ADMIN_UID, {
    collection: 'storeSettings', docId: 'deletion',
    data: { autoDeleteDays: 30 }, operation: 'create',
  }));
  const snap = await getDoc(doc(adminDb(), 'storeSettings', 'deletion'));
  assert.equal(snap.data().autoDeleteDays, 30);
});

test('Out-of-stock: a 1-line order for more than stock minus reserved is denied (no reserve write in the batch)', async () => {
  const db = anonDb();
  // prod-oos-1: stock 2, reserved 0 — qty 3 must fail on the order
  // rule's own availability guard, not on the inventory write.
  await assertFails(rawOrderBatch(db, {
    orderId: 'order-oos-fail', productId: 'prod-oos-1', productName: 'منتج نفاد',
    price: 100, qty: 3, stock: 2, reserved: 0, skipInventory: true,
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'order-oos-fail'))).exists(), false);
});

test('Out-of-stock: a 1-line order for exactly the available quantity succeeds', async () => {
  const db = anonDb();
  await assertSucceeds(rawOrderBatch(db, {
    orderId: 'order-oos-ok', productId: 'prod-oos-1', productName: 'منتج نفاد',
    price: 100, qty: 2, stock: 2, reserved: 0, skipInventory: true,
  }));
  const snap = await getDoc(doc(adminDb(), 'orders', 'order-oos-ok'));
  assert.equal(snap.exists(), true);
  assert.equal(snap.data().total, 200);
});

test('Out-of-stock: a 4-line order with an over-stock line is NOT denied by the rules guard (guard skips >3 lines)', async () => {
  const db = anonDb();
  // prod-oos-1: stock 2, reserved 0 — qty 3 fails the guard on a
  // ≤3-line order (see 'order-oos-fail' above). With 4 lines the
  // guard is skipped: orderAvailabilityOk passes on size > 3 without
  // the per-line inventory gets, because a second get per line would
  // blow the 10-get budget and deny legitimate 4+-line orders
  // (firestore.rules orderAvailabilityOk + the budget note above it).
  // The client transaction's stock re-check + the inventory
  // reserved <= stock rule are the guards for these orders; this
  // batch writes no reserve, so the order create must succeed —
  // proving the >3-line skip, not just the absence of a denial.
  await assertSucceeds(rawOrderBatch(db, {
    orderId: 'order-oos-skip-4',
    lines: [
      { productId: 'prod-7', productName: 'منتج 7', price: 100, qty: 1 },
      { productId: 'prod-8', productName: 'منتج 8', price: 100, qty: 1 },
      { productId: 'prod-9', productName: 'منتج 9', price: 100, qty: 1 },
      { productId: 'prod-oos-1', productName: 'منتج نفاد', price: 100, qty: 3 },
    ],
    skipInventory: true,
  }));
  const snap = await getDoc(doc(adminDb(), 'orders', 'order-oos-skip-4'));
  assert.equal(snap.exists(), true);
  assert.equal(snap.data().items.length, 4);
  assert.equal(snap.data().total, 600);
});

test('Out-of-stock: the old-shape order still succeeds, and so does the new-money shape', async () => {
  const db = anonDb();
  await assertSucceeds(rawOrderBatch(db, {
    orderId: 'order-oos-old', productId: 'prod-oos-1', productName: 'منتج نفاد',
    price: 100, qty: 1, stock: 2, reserved: 0,
  }));
  await assertSucceeds(placePricingOrderTx(db, {
    orderId: 'order-oos-new',
    lines: [{ productId: 'prod-oos-1', qty: 1, basePrice: null }],
    deliveryFee: 30,
  }));
  const snap = await getDoc(doc(adminDb(), 'orders', 'order-oos-new'));
  assert.equal(snap.data().deliveryFee, 30);
  assert.equal(snap.data().amountDue, 130);
});

/* ---------- Templates bundle model (2026-11-27, spec entries 10/20)
 * EMULATOR-GATED like the rest of this file (see the header): the
 * Firestore emulator cannot run in this sandbox (Java loopback is
 * blocked), so these cases are WRITTEN, syntax-checked with
 * `node --check`, and NOT executed here — run them in CI / on a
 * machine with the emulator before deploying the rules.
 *
 * NOTE on the old swap expectation: no test in this file ever asserted
 * the previousTemplateId-swap rollback (the swap lived only in the
 * admin apps' rollbackTemplate). There is nothing to delete here; the
 * stack-walk behaviour is pinned by the rollback test below instead.
 *
 * State flow inside this section (tests run in file order, sharing the
 * seeded pointer + registry docs): reads -> boutique create + status
 * machine -> gallery approval-freeze (restored to active afterwards)
 * -> classic pin -> pointer denials -> pointer/rollback sequence ->
 * retired-rollback -> activation history -> previews -> homepage
 * endDate -> feedback extras -> orders templateId. */

const TPL_HASH_A = 'a'.repeat(64);
const TPL_HASH_B = 'b'.repeat(64);
const TPL_HASH_C = 'c'.repeat(64);
const TPL_HASH_D = 'd'.repeat(64);

/* A valid new-shape registry doc for `id` (approval included, so the
 * doc can go approved/active). */
function templateDoc(id, { nameAr, nameEn, hash, status, approval = true }) {
  const doc = {
    id, nameAr, nameEn,
    version: '1.0.0', shellMinVersion: '1.0.0', bundleHash: hash,
    status,
  };
  if (approval) {
    doc.approval = {
      approver: ADMIN_UID, timestamp: serverTimestamp(),
      shellVersion: '1.0.0', bundleHash: hash,
    };
  }
  return doc;
}

/* Write a template doc the way the admin app does (audited batch;
 * `status` is sensitive, so it is recorded in the audit entry). */
async function writeTemplate(db, id, data) {
  const sensitive = ('status' in data) ? { status: data.status } : {};
  return auditedSet(db, ADMIN_UID, {
    collection: 'templates', docId: id, data,
    operation: 'template_status', sensitive,
  });
}

function historyEntry(templateId, bundleHash) {
  return {
    templateId, bundleVersion: '1.0.0', bundleHash,
    at: Timestamp.now(), by: ADMIN_UID,
  };
}

function pointerData(templateId, bundleHash, previousTemplateId, history, extra = {}) {
  return {
    templateId, bundleVersion: '1.0.0', bundleHash,
    previousTemplateId, history, ...extra,
  };
}

/* Write the pointer the way the admin app does (audited batch). The
 * caller asserts success/failure — this helper only builds the write. */
async function writePointer(db, templateId, bundleHash, previousTemplateId, history, extra = {}) {
  return auditedSet(db, ADMIN_UID, {
    collection: 'storeSettings', docId: 'activeTemplate',
    data: pointerData(templateId, bundleHash, previousTemplateId, history, extra),
    operation: 'template_activate',
  });
}

async function readPointer() {
  return (await getDoc(doc(adminDb(), 'storeSettings', 'activeTemplate'))).data();
}

async function templateHash(id) {
  return (await getDoc(doc(adminDb(), 'templates', id))).data().bundleHash;
}

/* Bring an approved template to active (no-op when already active). */
async function ensureTemplateActive(db, id) {
  const snap = await getDoc(doc(adminDb(), 'templates', id));
  if (snap.data().status !== 'active') {
    assert.equal(snap.data().status, 'approved');
    await assertSucceeds(writeTemplate(db, id, { status: 'active' }));
  }
}

test('Templates (entry 20): anonymous reads an active registry doc, never a draft', async () => {
  const db = anonDb();
  await assertSucceeds(getDoc(doc(db, 'templates', 'classic')));
  await assertFails(getDoc(doc(db, 'templates', 'scroll')));
  await assertFails(getDocs(collection(db, 'templates')));
});

test('Templates (entry 20): registry create with a non-canonical status is denied', async () => {
  const db = adminDb();
  // 'boutique' is the one unseeded id: create it as 'validating', then
  // as 'awaiting-approval' — both are denied by the six-state enum.
  for (const badStatus of ['validating', 'awaiting-approval']) {
    await assertFails(writeTemplate(db, 'boutique', templateDoc(
      'boutique', { nameAr: 'الدكان', nameEn: 'Warm Boutique', hash: TPL_HASH_D, status: badStatus },
    )));
    assert.equal((await getDoc(doc(adminDb(), 'templates', 'boutique'))).exists(), false);
  }
  // The same doc as a draft creates fine.
  await assertSucceeds(writeTemplate(db, 'boutique', templateDoc(
    'boutique', { nameAr: 'الدكان', nameEn: 'Warm Boutique', hash: TPL_HASH_D, status: 'draft', approval: false },
  )));
  assert.equal((await getDoc(doc(adminDb(), 'templates', 'boutique'))).data().status, 'draft');
});

test('Templates (entry 20): status machine — draft→preview→approved→active→retired, skips denied', async () => {
  const db = adminDb();
  // boutique is a draft now (previous test). Skipping steps is denied.
  await assertFails(writeTemplate(db, 'boutique', { status: 'approved' }));
  await assertFails(writeTemplate(db, 'boutique', { status: 'active' }));
  // draft → preview passes.
  await assertSucceeds(writeTemplate(db, 'boutique', { status: 'preview' }));
  // preview → active is a skip (must be approved first) — denied.
  await assertFails(writeTemplate(db, 'boutique', { status: 'active' }));
  // preview → approved needs the approval record in the same write.
  await assertFails(writeTemplate(db, 'boutique', { status: 'approved' }));
  await assertSucceeds(writeTemplate(db, 'boutique', {
    status: 'approved',
    approval: { approver: ADMIN_UID, timestamp: serverTimestamp(), shellVersion: '1.0.0', bundleHash: TPL_HASH_D },
  }));
  // approved → active passes; active → draft (un-activating) is denied.
  await assertSucceeds(writeTemplate(db, 'boutique', { status: 'active' }));
  await assertFails(writeTemplate(db, 'boutique', { status: 'draft' }));
  await assertFails(writeTemplate(db, 'boutique', { status: 'preview' }));
  // active → retired passes; retired is terminal.
  await assertSucceeds(writeTemplate(db, 'boutique', { status: 'retired' }));
  await assertFails(writeTemplate(db, 'boutique', { status: 'draft' }));
  await assertFails(writeTemplate(db, 'boutique', { status: 'active' }));
});

test('Templates (entry 20): approval freezes the hash — changed hash with kept approval denied; re-approval path passes', async () => {
  const db = adminDb();
  // gallery is approved with approval.bundleHash == TPL_HASH_B.
  await assertFails(writeTemplate(db, 'gallery', { bundleHash: TPL_HASH_D }));
  await assertFails(writeTemplate(db, 'gallery', { bundleHash: TPL_HASH_D, status: 'draft' }));
  // The re-approval path: new hash + drop to draft + approval removed.
  await assertSucceeds(writeTemplate(db, 'gallery', {
    bundleHash: TPL_HASH_D, status: 'draft', approval: deleteField(),
  }));
  const after = (await getDoc(doc(adminDb(), 'templates', 'gallery'))).data();
  assert.equal(after.bundleHash, TPL_HASH_D);
  assert.equal(after.status, 'draft');
  assert.equal(after.approval, undefined);
  // ... and back up the machine with a fresh approval for the new hash,
  // so the later pointer tests find gallery active.
  await assertSucceeds(writeTemplate(db, 'gallery', { status: 'preview' }));
  await assertSucceeds(writeTemplate(db, 'gallery', {
    status: 'approved',
    approval: { approver: ADMIN_UID, timestamp: serverTimestamp(), shellVersion: '1.0.0', bundleHash: TPL_HASH_D },
  }));
  await assertSucceeds(writeTemplate(db, 'gallery', { status: 'active' }));
});

test('Templates (entry 20): approval accepts the admin app\'s \'at\' timestamp key as well as \'timestamp\'', async () => {
  const db = adminDb();
  // Entry 12's approveTemplate writes approval.at; the spec names the
  // key 'timestamp'. The rules accept exactly one of them (flagged in
  // the entry-10 report for the coordinator to normalise). Both spellings
  // approve here; carrying both at once is denied.
  await assertSucceeds(writeTemplate(db, 'gallery', {
    status: 'approved',
    approval: { approver: ADMIN_UID, at: Timestamp.now(), shellVersion: '1.0.0', bundleHash: TPL_HASH_D },
  }));
  await assertFails(writeTemplate(db, 'gallery', {
    status: 'approved',
    approval: { approver: ADMIN_UID, at: serverTimestamp(), timestamp: serverTimestamp(), shellVersion: '1.0.0', bundleHash: TPL_HASH_D },
  }));
  // Back to active with the spec-spelled approval, as the later pointer
  // tests expect gallery active with a valid approval.
  await assertSucceeds(writeTemplate(db, 'gallery', {
    status: 'active',
    approval: { approver: ADMIN_UID, timestamp: serverTimestamp(), shellVersion: '1.0.0', bundleHash: TPL_HASH_D },
  }));
});

test('Templates (entry 20): active → approved passes — the previous live template returns to standby with its approval kept', async () => {
  const db = adminDb();
  // gallery is active now (previous tests). The activation flow writes
  // the outgoing template back to approved in the same batch as the
  // pointer flip (entry 12) — the status machine must allow it.
  await assertSucceeds(writeTemplate(db, 'gallery', { status: 'approved' }));
  assert.equal((await getDoc(doc(adminDb(), 'templates', 'gallery'))).data().status, 'approved');
  await assertSucceeds(writeTemplate(db, 'gallery', { status: 'active' }));
});

test('Templates (entry 20): classic can never be deleted or retired', async () => {
  const db = adminDb();
  await assertFails(deleteWithAudit(db, ADMIN_UID, 'templates', 'classic'));
  assert.equal((await getDoc(doc(adminDb(), 'templates', 'classic'))).exists(), true);
  await assertFails(writeTemplate(db, 'classic', { status: 'retired' }));
  assert.equal((await getDoc(doc(adminDb(), 'templates', 'classic'))).data().status, 'active');
});

test('Templates (entry 20): pointer write to a non-active template is denied', async () => {
  const db = adminDb();
  const ptr = await readPointer();
  const base = [...ptr.history];
  // scroll is a draft; speclab is retired — neither may be pointed at.
  for (const target of ['scroll', 'speclab']) {
    const hash = await templateHash(target);
    await assertFails(writePointer(db, target, hash, ptr.templateId,
      [...base, historyEntry(target, hash)]));
  }
  assert.equal((await readPointer()).templateId, ptr.templateId);
});

test('Templates (entry 20): pointer write without bundleVersion/bundleHash is denied', async () => {
  const db = adminDb();
  // The pointer must be deleted first: a merge-write would keep the old
  // bundleVersion/bundleHash, so "missing" can only be tested on create.
  await assertSucceeds(deleteWithAudit(db, ADMIN_UID, 'storeSettings', 'activeTemplate'));
  const noVersion = pointerData('classic', TPL_HASH_C, 'classic',
    [historyEntry('classic', TPL_HASH_C)]);
  delete noVersion.bundleVersion;
  await assertFails(auditedSet(db, ADMIN_UID, {
    collection: 'storeSettings', docId: 'activeTemplate',
    data: noVersion, operation: 'template_activate',
  }));
  const noHash = pointerData('classic', TPL_HASH_C, 'classic',
    [historyEntry('classic', TPL_HASH_C)]);
  delete noHash.bundleHash;
  await assertFails(auditedSet(db, ADMIN_UID, {
    collection: 'storeSettings', docId: 'activeTemplate',
    data: noHash, operation: 'template_activate',
  }));
  // ... and the valid pointer recreates fine (the rollback test below
  // starts from this classic pointer).
  await assertSucceeds(writePointer(db, 'classic', TPL_HASH_C, 'classic',
    [historyEntry('classic', TPL_HASH_C)]));
  assert.equal((await readPointer()).templateId, 'classic');
});

test('Templates (entry 20): activation appends to the history stack; rollback restores the second-last entry; double-rollback walks backwards (no swap)', async () => {
  const db = adminDb();
  await ensureTemplateActive(db, 'bazaar');
  await ensureTemplateActive(db, 'gallery');
  const hashBazaar = await templateHash('bazaar');
  const hashGallery = await templateHash('gallery');
  // Start from classic (reset if a previous test left another live id).
  let ptr = await readPointer();
  if (ptr.templateId !== 'classic') {
    await assertSucceeds(writePointer(db, 'classic', TPL_HASH_C, ptr.templateId,
      [...ptr.history, historyEntry('classic', TPL_HASH_C)]));
    ptr = await readPointer();
  }
  assert.equal(ptr.templateId, 'classic');
  const n0 = ptr.history.length;
  // Activate bazaar: previousTemplateId records classic, history grows by 1.
  // The admin app also stamps activatedBy/activatedAt on the pointer
  // (entry 12) — allowed, never required — so this write carries them.
  await assertSucceeds(writePointer(db, 'bazaar', hashBazaar, 'classic',
    [...ptr.history, historyEntry('bazaar', hashBazaar)],
    { activatedBy: ADMIN_UID, activatedAt: serverTimestamp() }));
  ptr = await readPointer();
  assert.equal(ptr.templateId, 'bazaar');
  assert.equal(ptr.previousTemplateId, 'classic');
  assert.equal(ptr.activatedBy, ADMIN_UID);
  assert.equal(ptr.history.length, n0 + 1);
  assert.equal(ptr.history[ptr.history.length - 1].templateId, 'bazaar');
  // Activate gallery: history [.., classic, bazaar, gallery].
  await assertSucceeds(writePointer(db, 'gallery', hashGallery, 'bazaar',
    [...ptr.history, historyEntry('gallery', hashGallery)]));
  ptr = await readPointer();
  assert.equal(ptr.templateId, 'gallery');
  assert.equal(ptr.previousTemplateId, 'bazaar');
  assert.equal(ptr.history.length, n0 + 2);
  // Rollback restores the second-last entry (bazaar) — NOT a swap of
  // previousTemplateId: it appends a new entry, so the stack becomes
  // [.., classic, bazaar, gallery, bazaar].
  await assertSucceeds(writePointer(db, 'bazaar', hashBazaar, 'gallery',
    [...ptr.history, historyEntry('bazaar', hashBazaar)]));
  ptr = await readPointer();
  assert.equal(ptr.templateId, 'bazaar');
  assert.equal(ptr.previousTemplateId, 'gallery');
  assert.equal(ptr.history.length, n0 + 3);
  assert.equal(ptr.history[ptr.history.length - 2].templateId, 'gallery');
  // Rollback again walks one step further back — to gallery, not to
  // classic and not a ping-pong to the same template.
  await assertSucceeds(writePointer(db, 'gallery', hashGallery, 'bazaar',
    [...ptr.history, historyEntry('gallery', hashGallery)]));
  ptr = await readPointer();
  assert.equal(ptr.templateId, 'gallery');
  assert.equal(ptr.previousTemplateId, 'bazaar');
  assert.equal(ptr.history.length, n0 + 4);
  // A history rewrite (same length, reordered) is denied: append-only.
  const rewritten = [...ptr.history];
  rewritten[0] = historyEntry('classic', TPL_HASH_C);
  await assertFails(writePointer(db, 'gallery', hashGallery, 'bazaar', rewritten));
});

test('Templates (entry 20): rollback to a retired template is denied and classic is restored instead', async () => {
  const db = adminDb();
  const ptr = await readPointer();
  const hashRetired = await templateHash('speclab');
  await assertFails(writePointer(db, 'speclab', hashRetired, ptr.templateId,
    [...ptr.history, historyEntry('speclab', hashRetired)]));
  // The client restores classic instead (classic is active, so the
  // pointer write to it passes).
  await assertSucceeds(writePointer(db, 'classic', TPL_HASH_C, ptr.templateId,
    [...ptr.history, historyEntry('classic', TPL_HASH_C)]));
  assert.equal((await readPointer()).templateId, 'classic');
});

test('Templates (entry 20): activation history is append-only', async () => {
  const db = adminDb();
  const entry = {
    operationId: 'op-act-1',
    templateId: 'gallery', bundleVersion: '1.0.0', bundleHash: TPL_HASH_D,
    shellVersion: '1.0.0', approver: ADMIN_UID, at: serverTimestamp(), action: 'activate',
  };
  await assertSucceeds(setDoc(doc(db, 'templates', 'gallery', 'activations', 'op-act-1'), entry));
  // A second activation appends under its own operation id.
  await assertSucceeds(setDoc(doc(db, 'templates', 'gallery', 'activations', 'op-act-2'),
    { ...entry, operationId: 'op-act-2', action: 'rollback' }));
  // Update and delete are denied; a mismatched parent templateId or
  // operationId is denied.
  await assertFails(updateDoc(doc(db, 'templates', 'gallery', 'activations', 'op-act-1'), { action: 'retire' }));
  await assertFails(deleteDoc(doc(db, 'templates', 'gallery', 'activations', 'op-act-1')));
  await assertFails(setDoc(doc(db, 'templates', 'gallery', 'activations', 'op-act-3'),
    { ...entry, operationId: 'op-act-3', templateId: 'bazaar' }));
  await assertFails(setDoc(doc(db, 'templates', 'gallery', 'activations', 'op-act-3'),
    { ...entry, operationId: 'op-other', action: 'activate' }));
  await assertFails(setDoc(doc(db, 'templates', 'gallery', 'activations', 'op-act-4'),
    { ...entry, operationId: 'op-act-4', action: 'publish' }));
  // Anonymous cannot write (or read) the history.
  await assertFails(setDoc(doc(anonDb(), 'templates', 'gallery', 'activations', 'op-act-5'), entry));
  await assertFails(getDoc(doc(anonDb(), 'templates', 'gallery', 'activations', 'op-act-1')));
  const list = await getDocs(collection(adminDb(), 'templates', 'gallery', 'activations'));
  assert.equal(list.docs.length, 2);
});

test('Templates (entry 20): previews — anonymous get only, never anonymous list; admin issue/rotate/revoke', async () => {
  const db = adminDb();
  // Slug shape is the admin app's record (entry 12): templateId,
  // version, issuedAt, issuedBy, status open|revoked. Issue/revoke are
  // direct writes — the slug document itself is the record, no audit
  // entry — and rotation queries the open slugs, so admin list is
  // allowed while anonymous list stays denied.
  const preview = {
    templateId: 'bazaar', version: '1.0.0',
    issuedAt: serverTimestamp(), issuedBy: ADMIN_UID, status: 'open',
  };
  await assertSucceeds(setDoc(doc(db, 'previews', 'slug-1'), preview));
  // Anonymous get works; anonymous list and anonymous create do not.
  await assertSucceeds(getDoc(doc(anonDb(), 'previews', 'slug-1')));
  await assertFails(getDocs(collection(anonDb(), 'previews')));
  await assertFails(setDoc(doc(anonDb(), 'previews', 'slug-x'), preview));
  // A slug with a bad shape is denied even for an admin.
  await assertFails(setDoc(doc(db, 'previews', 'slug-bad'), { ...preview, status: 'pending' }));
  await assertFails(setDoc(doc(db, 'previews', 'slug-bad'), { ...preview, templateId: 'mall' }));
  // Rotate: issue a new slug, revoke the old one; the admin list query
  // rotation uses sees both.
  await assertSucceeds(setDoc(doc(db, 'previews', 'slug-2'), preview));
  await assertSucceeds(updateDoc(doc(db, 'previews', 'slug-1'), { status: 'revoked' }));
  assert.equal((await getDoc(doc(adminDb(), 'previews', 'slug-1'))).data().status, 'revoked');
  assert.equal((await getDoc(doc(adminDb(), 'previews', 'slug-2'))).data().status, 'open');
  const open = await getDocs(collection(adminDb(), 'previews'));
  assert.equal(open.docs.filter((s) => s.data().status === 'open').length, 1);
});

test('Templates (entry 20): homepage promo endDate must be a valid date-time', async () => {
  const db = adminDb();
  const banner = (endDate) => ({
    imageUrl: '', title: 'عرض', subtitle: '', linkType: 'none', linkId: '', endDate,
  });
  const writeHomepage = (banners) => auditedSet(db, ADMIN_UID, {
    collection: 'storeSettings', docId: 'homepage',
    data: { promoBanners: banners }, operation: 'homepage_save',
  });
  await assertSucceeds(writeHomepage([banner('2026-12-01T00:00:00+02:00')]));
  await assertSucceeds(writeHomepage([banner('2026-12-01T00:00:00Z')]));
  await assertSucceeds(writeHomepage([banner('')])); // no end date
  await assertSucceeds(writeHomepage([banner(Timestamp.fromMillis(Date.now() + 86400000))]));
  await assertFails(writeHomepage([banner('tomorrow')]));
  await assertFails(writeHomepage([banner('2026-13-45T99:99:99Z')]));
  await assertFails(writeHomepage([banner('2026-12-01')])); // date only, no time
});

test('Templates (entry 20): feedback with extra fields (templateId, viewport) is rejected; 6-field source shape still passes', async () => {
  const db = anonDb();
  const base = {
    name: 'أحمد', email: 'a@test.com', phone: '01012345678',
    message: 'شكوى تجريبية كافية الطول', createdAt: serverTimestamp(),
  };
  await assertFails(setDoc(doc(collection(db, 'feedback')), { ...base, templateId: 'bazaar' }));
  await assertFails(setDoc(doc(collection(db, 'feedback')), { ...base, viewport: '390x844' }));
  await assertFails(setDoc(doc(collection(db, 'feedback')), { ...base, templateId: 'bazaar', viewport: '390x844' }));
  // The tonight batch's 6th field is still allowed (D8: no templateId).
  await assertSucceeds(setDoc(doc(collection(db, 'feedback')), {
    name: '', email: '', phone: '', message: 'ملاحظة خروج كافية الطول',
    createdAt: serverTimestamp(), source: 'exit-feedback',
  }));
});

test('Templates (entry 20): orders reject a templateId field', async () => {
  const db = anonDb();
  await assertFails(rawOrderBatch(db, {
    orderId: 'order-tpl-reject', productId: 'prod-2', productName: 'شاحن سريع',
    price: 200, qty: 1, stock: 3, reserved: 0,
    overrides: { templateId: 'bazaar' },
  }));
  assert.equal((await getDoc(doc(adminDb(), 'orders', 'order-tpl-reject'))).exists(), false);
});
