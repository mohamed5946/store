/* Phase 2 audit + feedback tests (design doc file 33: T14 function-side
 * audit, T19–T21 are the emulator rules tests in test/rules.test.js,
 * feedback T9/T13, export T24).
 *
 * Runs the REAL functions/lib code (createOrderTx, submitFeedbackTx,
 * getFeedbackStatus, buildReplyRecord, exportFirestore) against the
 * in-memory fake Firestore (functions/test/fake-firestore.js).
 * No network. Run from the repo root:
 *   node --test functions/test/audit.test.js
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');

const { createFakeFirestore } = require('./fake-firestore');
const { createOrderTx } = require('../lib/orders');
const {
  submitFeedbackTx, getFeedbackStatus, buildReplyRecord,
  isAllowedFeedbackTransition,
} = require('../lib/feedback');
const { exportFirestore } = require('../lib/sweep');

const NOW = 1793000000000; // fixed "now" (ms)

function seedStore(db) {
  db.seed('products/prod-1', { name: 'سماعة بلوتوث', price: 500, categoryId: 'cat-1', inStock: true });
  db.seed('inventory/prod-1', { productId: 'prod-1', stock: 5, reserved: 0, minStock: 5, costPrice: 300 });
}

function placeOrder(db, overrides = {}) {
  return createOrderTx(db, {
    clientOrderId: 'order-1',
    items: [{ productId: 'prod-1', qty: 2 }],
    discountCode: null,
    customer: { name: 'اختبار', phone: '01012345678', address: 'عنوان اختبار' },
    source: 'storefront',
    createdBy: null,
    shippingCompanyId: null,
    notes: null,
    seenPrices: { 'prod-1': 500 },
    seenTotal: 1000,
    serverTimestamp: () => NOW,
    ...overrides,
  });
}

function submitFeedback(db, overrides = {}) {
  return submitFeedbackTx(db, {
    submissionId: 'fb-1',
    type: 'complaint',
    category: 'delivery',
    title: 'الطلب اتأخر',
    message: 'فيه تأخير في الطلب عن المعاد المتفق عليه يومين كاملين',
    orderId: null,
    phone: '01012345678',
    source: 'storefront',
    createdBy: null,
    serverTimestamp: () => NOW,
    now: NOW,
    random: () => 0.5,
    ...overrides,
  });
}

/* ---------- function-side audit (T14) ---------- */

test('Phase 2 (T14): one audit entry per order, with the operationId as its doc id and the docIds index', async () => {
  const db = createFakeFirestore();
  seedStore(db);

  await placeOrder(db);

  const audits = db.all('audit/');
  assert.equal(audits.length, 1, 'exactly one audit entry per order');
  const entry = audits[0].data;
  assert.equal(entry.operationId, audits[0].id, 'the audit doc id IS the operationId');
  assert.equal(entry.actor, 'anonymous');
  assert.equal(entry.collection, 'orders');
  assert.equal(entry.docId, 'order-1');
  assert.equal(entry.operation, 'create');
  assert.deepEqual(entry.docIds, { 'orders/order-1': ['status', 'total'] });
  assert.equal(entry.documents.length, 1);
  assert.equal(entry.documents[0].collection, 'orders');
  assert.equal(entry.newValues.total, 1000);
  assert.equal(entry.timestamp, NOW);
  // No customer PII anywhere in the audit entry.
  assert.ok(!JSON.stringify(entry).includes('01012345678'), 'no customer phone in the audit entry');
  assert.ok(!JSON.stringify(entry).includes('اختبار'), 'no customer name in the audit entry');
  assert.ok(!JSON.stringify(entry).includes('عنوان اختبار'), 'no customer address in the audit entry');
});

test('Phase 2 (T14): an idempotent retry writes no second audit entry', async () => {
  const db = createFakeFirestore();
  seedStore(db);

  await placeOrder(db);
  await placeOrder(db); // same clientOrderId — returns the existing order
  assert.equal(db.all('audit/').length, 1);
});

test('Phase 2 (T14): a manual order is audited as the admin, without customer PII', async () => {
  const db = createFakeFirestore();
  seedStore(db);

  await placeOrder(db, {
    clientOrderId: 'order-manual-1',
    source: 'admin_manual',
    createdBy: 'admin-uid-1',
  });

  const audits = db.all('audit/');
  assert.equal(audits.length, 1);
  assert.equal(audits[0].data.actor, 'admin-uid-1');
  assert.equal(audits[0].data.operation, 'manual_order_create');
  assert.equal(audits[0].data.source, 'createManualOrder');
  assert.ok(!JSON.stringify(audits[0].data).includes('01012345678'));
});

/* ---------- feedback (T9/T13) ---------- */

test('Phase 2 (T9): a submission gets a tracking code and a suggested priority', async () => {
  const db = createFakeFirestore();

  const res = await submitFeedback(db);
  assert.equal(res.duplicate, false);
  assert.equal(res.linked, false);
  assert.match(res.trackingCode, /^FB-[A-Z0-9]{6}$/);

  const records = db.all('feedback/');
  assert.equal(records.length, 1);
  assert.equal(records[0].data.trackingCode, res.trackingCode);
  assert.equal(records[0].data.status, 'new');
  assert.equal(records[0].data.priority, 'medium', 'the message mentions a delay');
  assert.equal(records[0].data.customerRef.phone, '01012345678');
  assert.equal(records[0].data.customerRef.linked, false);
});

test('Phase 2 (T9): a broken-product message is suggested high priority', async () => {
  const db = createFakeFirestore();

  const res = await submitFeedback(db, {
    submissionId: 'fb-2',
    title: 'المنتج مكسور',
    message: 'المنتج وصلني مكسور والتغليف تالف خالص',
  });
  assert.equal(res.duplicate, false);
  assert.equal(db.all('feedback/').find((d) => d.id === 'fb-2').data.priority, 'high');
});

test('Phase 2 (T9): an identical submission within 24h returns the existing tracking code, no new record', async () => {
  const db = createFakeFirestore();

  const first = await submitFeedback(db);
  const second = await submitFeedback(db, {
    submissionId: 'fb-2', // a new submission id, same phone + same message
    now: NOW + 60 * 60 * 1000, // one hour later
    serverTimestamp: () => NOW + 60 * 60 * 1000,
  });
  assert.equal(second.duplicate, true);
  assert.equal(second.trackingCode, first.trackingCode);
  assert.equal(db.all('feedback/').length, 1, 'no duplicate record created');

  // A different message is a new submission, not a duplicate.
  const third = await submitFeedback(db, {
    submissionId: 'fb-3',
    message: 'عندي اقتراح مختلف تماما عن المنتجات الجديدة',
    now: NOW + 2 * 60 * 60 * 1000,
    serverTimestamp: () => NOW + 2 * 60 * 60 * 1000,
  });
  assert.equal(third.duplicate, false);
  assert.equal(db.all('feedback/').length, 2);

  // The same message after 24h is a new submission again.
  const fourth = await submitFeedback(db, {
    submissionId: 'fb-4',
    now: NOW + 25 * 60 * 60 * 1000,
    serverTimestamp: () => NOW + 25 * 60 * 60 * 1000,
  });
  assert.equal(fourth.duplicate, false);
  assert.equal(db.all('feedback/').length, 3);
});

test('Phase 2 (T9): an order link is verified — matching phone links, a mismatch does not', async () => {
  const db = createFakeFirestore();
  seedStore(db);
  await placeOrder(db); // order-1, phone 01012345678

  const linked = await submitFeedback(db, {
    submissionId: 'fb-linked', orderId: 'order-1', phone: '01012345678',
  });
  assert.equal(linked.linked, true);

  const unlinked = await submitFeedback(db, {
    submissionId: 'fb-unlinked', orderId: 'order-1', phone: '01199999999',
    message: 'شكوى مختلفة تماما عن الطلب ده',
  });
  assert.equal(unlinked.linked, false);
  // The submission is still accepted — a bad link is untrusted, not rejected.
  assert.equal(unlinked.duplicate, false);
});

test('Phase 2 (T9): a blocked phone is refused before any record is created', async () => {
  const db = createFakeFirestore();
  db.seed('feedbackBlocks/phone:01012345678', {
    type: 'phone', value: '01012345678', blockedUntil: NOW + 60 * 60 * 1000, reason: 'spam',
  });

  await assert.rejects(submitFeedback(db), (e) => e.code === 'BLOCKED');
  assert.equal(db.all('feedback/').length, 0);
});

test('Phase 2 (T9): a too-short message and a bad type are refused', async () => {
  const db = createFakeFirestore();

  await assert.rejects(
    submitFeedback(db, { message: 'قصير' }),
    (e) => e.code === 'INVALID_INPUT',
  );
  await assert.rejects(
    submitFeedback(db, { type: 'rant' }),
    (e) => e.code === 'INVALID_INPUT',
  );
  assert.equal(db.all('feedback/').length, 0);
});

test('Phase 2 (T13): getFeedbackStatus returns only status + last reply, and only on an exact match', async () => {
  const db = createFakeFirestore();
  const { trackingCode } = await submitFeedback(db);
  // A visible admin reply on the record.
  db.seed(`feedback/fb-1/replies/reply-1`, {
    adminUid: 'admin-1', adminName: 'Admin', text: 'بنعتذر، هنبعت بديل بكرة',
    createdAt: NOW + 1000, visibleToCustomer: true,
  });

  const res = await getFeedbackStatus(db, { trackingCode, phone: '01012345678' });
  assert.deepEqual(Object.keys(res).sort(), ['lastReply', 'status']);
  assert.equal(res.status, 'new');
  assert.equal(res.lastReply, 'بنعتذر، هنبعت بديل بكرة');

  // Wrong phone: NOT_FOUND, without saying which part failed.
  await assert.rejects(
    getFeedbackStatus(db, { trackingCode, phone: '01100000000' }),
    (e) => e.code === 'NOT_FOUND',
  );
  // Wrong code: the same NOT_FOUND (no enumeration).
  await assert.rejects(
    getFeedbackStatus(db, { trackingCode: 'FB-XXXXXX', phone: '01012345678' }),
    (e) => e.code === 'NOT_FOUND',
  );
});

test('Phase 2: the feedback state machine allows exactly the legal transitions', () => {
  assert.equal(isAllowedFeedbackTransition('new', 'in_review'), true);
  assert.equal(isAllowedFeedbackTransition('new', 'spam'), true);
  assert.equal(isAllowedFeedbackTransition('new', 'resolved'), false);
  assert.equal(isAllowedFeedbackTransition('in_review', 'awaiting_customer'), true);
  assert.equal(isAllowedFeedbackTransition('in_review', 'resolved'), true);
  assert.equal(isAllowedFeedbackTransition('awaiting_customer', 'resolved'), true);
  assert.equal(isAllowedFeedbackTransition('awaiting_customer', 'spam'), false);
  assert.equal(isAllowedFeedbackTransition('resolved', 'closed'), true);
  assert.equal(isAllowedFeedbackTransition('resolved', 'in_review'), false);
  assert.equal(isAllowedFeedbackTransition('closed', 'in_review'), false);
  assert.equal(isAllowedFeedbackTransition('spam', 'new'), false);
});

test('Phase 2: buildReplyRecord shapes a visible admin reply', () => {
  const reply = buildReplyRecord({
    adminUid: 'admin-1', adminName: 'Admin', text: '  تم الحل  ', serverTimestamp: () => NOW,
  });
  assert.deepEqual(reply, {
    adminUid: 'admin-1', adminName: 'Admin', text: 'تم الحل',
    createdAt: NOW, visibleToCustomer: true,
  });
});

/* ---------- scheduled export (T24) ---------- */

test('Phase 2 (T24): a successful export writes a health ok record', async () => {
  const db = createFakeFirestore();
  let calledUrl = null;
  const fetchImpl = async (url, opts) => {
    calledUrl = url;
    assert.equal(opts.method, 'POST');
    assert.ok(opts.headers.Authorization.startsWith('Bearer '));
    assert.ok(JSON.parse(opts.body).outputUriPrefix.startsWith('gs://store-3384c-backups/firestore-exports/'));
    return { ok: true, json: async () => ({ name: 'projects/store-3384c/operations/abc' }) };
  };

  const res = await exportFirestore(db, {
    projectId: 'store-3384c', bucket: 'store-3384c-backups', now: NOW,
    serverTimestamp: () => NOW, fetchImpl, getAccessToken: async () => 'token-123',
  });
  assert.equal(res.status, 'ok');
  assert.ok(calledUrl.includes('firestore.googleapis.com/v1/projects/store-3384c/databases/(default):exportDocuments'));
  const health = db.all('health/').find((d) => d.id === 'firestore-export');
  assert.equal(health.data.status, 'ok');
  assert.equal(health.data.check, 'firestore-export');
});

test('Phase 2 (T24): a failed export writes a health degraded record instead of failing silently', async () => {
  const db = createFakeFirestore();
  const fetchImpl = async () => ({ ok: false, status: 403, text: async () => 'permission denied' });

  const res = await exportFirestore(db, {
    projectId: 'store-3384c', bucket: 'store-3384c-backups', now: NOW,
    serverTimestamp: () => NOW, fetchImpl, getAccessToken: async () => 'token-123',
  });
  assert.equal(res.status, 'degraded');
  assert.ok(res.detail.includes('403'));
  const health = db.all('health/').find((d) => d.id === 'firestore-export');
  assert.equal(health.data.status, 'degraded');
  assert.ok(health.data.detail.includes('403'));
});
