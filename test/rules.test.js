/* Phase 2 Firestore rules tests (design doc file 36: T19–T21 + the
 * file-36 list — anonymous order creation denied, admin writes without
 * an audit entry denied, the audit entry's fields enforced, public
 * reads kept for the storefront's catalog only).
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
 * in build.yml — the Phase 2 file boundary does not include it — so
 * run it on a machine with the emulator before deploying the rules.
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
  serverTimestamp, collection, getDocs,
} = require('firebase/firestore');

const PROJECT_ID = 'demo-store-3384c';
const RULES_PATH = path.join(__dirname, '..', 'firestore.rules');
const ADMIN_UID = 'admin-uid';
const MANAGER_UID = 'manager-uid';

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
  // one order, one feedback record, the active-template pointer.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'admins', ADMIN_UID), { role: 'admin', name: 'Admin' });
    await setDoc(doc(db, 'admins', MANAGER_UID), { role: 'manager', name: 'Manager' });
    await setDoc(doc(db, 'products', 'prod-1'), {
      name: 'سماعة بلوتوث', price: 500, categoryId: 'cat-1', inStock: true,
    });
    await setDoc(doc(db, 'inventory', 'prod-1'), {
      productId: 'prod-1', stock: 5, reserved: 0, minStock: 5, costPrice: 300,
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
    await setDoc(doc(db, 'feedback', 'fb-1'), {
      id: 'fb-1', trackingCode: 'FB-AAAAAA', status: 'new',
      priority: 'low', customerRef: { phone: '01012345678', linked: false },
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

/* ---------- anonymous access (file 36) ---------- */

test('Phase 2 (T19): an anonymous order create is denied', async () => {
  const db = anonDb();
  await assertFails(setDoc(doc(db, 'orders', 'order-x'), {
    clientOrderId: 'order-x', status: 'new', total: 100,
  }));
});

test('Phase 2 (T19): an anonymous order read is denied', async () => {
  const db = anonDb();
  await assertFails(getDoc(doc(db, 'orders', 'order-1')));
});

test('Phase 2 (T19): the public catalog stays readable anonymously', async () => {
  const db = anonDb();
  await assertSucceeds(getDoc(doc(db, 'products', 'prod-1')));
  await assertSucceeds(getDoc(doc(db, 'storeSettings', 'activeTemplate')));
  await assertSucceeds(getDocs(collection(db, 'products')));
});

test('Phase 2 (T19): anonymous reads of inventory, discounts, feedback, and audit are denied', async () => {
  const db = anonDb();
  await assertFails(getDoc(doc(db, 'inventory', 'prod-1')));
  await assertFails(getDoc(doc(db, 'discounts', 'SAVE10')));
  await assertFails(getDoc(doc(db, 'feedback', 'fb-1')));
  await assertFails(getDoc(doc(db, 'audit', 'op-test-1')));
  await assertFails(getDoc(doc(db, 'rateLimits', 'ip:x')));
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

test('Phase 2: an illegal feedback transition is denied, a legal one passes', async () => {
  const db = adminDb();
  await assertFails(auditedSet(db, ADMIN_UID, {
    collection: 'feedback', docId: 'fb-1',
    data: { status: 'resolved' }, sensitive: { status: 'resolved' },
  }));
  await assertSucceeds(auditedSet(db, ADMIN_UID, {
    collection: 'feedback', docId: 'fb-1',
    data: { status: 'in_review' }, sensitive: { status: 'in_review' },
  }));
});

test('Phase 2: only an admin may set urgent priority — a manager is denied', async () => {
  const mdb = managerDb();
  await assertFails(auditedSet(mdb, MANAGER_UID, {
    collection: 'feedback', docId: 'fb-1',
    data: { priority: 'urgent' }, sensitive: {},
  }));
  const adb = adminDb();
  await assertSucceeds(auditedSet(adb, ADMIN_UID, {
    collection: 'feedback', docId: 'fb-1',
    data: { priority: 'urgent' }, sensitive: {},
  }));
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
