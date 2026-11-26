/* Feedback (Technical Plan v1.4 §8): submitFeedback + getFeedbackStatus.
 *
 * Pure logic taking a Firestore interface (real Admin SDK or the test
 * fake); no firebase-admin import here. The storefront form itself lands
 * in Phase 3 (index.html markup); the Flutter admin app calls
 * submitFeedback for manual (phone) complaints, and getFeedbackStatus
 * for the tracking-code lookup.
 */

const {
  OrderError, sha256hex, toMillis, suggestPriority,
  generateTrackingCode, normalizeMessage,
} = require('./validation');

const FEEDBACK_TYPES = ['complaint', 'suggestion'];
const FEEDBACK_CATEGORIES = ['order_issue', 'product_quality', 'delivery', 'website', 'pricing', 'other'];
const FEEDBACK_STATUSES = ['new', 'in_review', 'awaiting_customer', 'resolved', 'closed', 'rejected', 'spam'];
const FEEDBACK_TRANSITIONS = {
  new: ['in_review', 'rejected', 'spam'],
  in_review: ['awaiting_customer', 'resolved', 'rejected', 'spam'],
  awaiting_customer: ['resolved', 'in_review'],
  resolved: ['closed'],
  closed: [],
  rejected: [],
  spam: [],
};

function isAllowedFeedbackTransition(from, to) {
  return (FEEDBACK_TRANSITIONS[from] || []).includes(to);
}

/* Validate the submission shape. Returns an error string or null. */
function validateFeedbackInput({ type, category, title, message }) {
  if (!FEEDBACK_TYPES.includes(type)) return 'INVALID_INPUT';
  if (!FEEDBACK_CATEGORIES.includes(category)) return 'INVALID_INPUT';
  if (!title || String(title).trim().length === 0 || String(title).length > 100) return 'INVALID_INPUT';
  const msg = String(message || '').trim();
  if (msg.length < 10 || msg.length > 2000) return 'INVALID_INPUT';
  return null;
}

/* Submit feedback. Returns { trackingCode, duplicate, linked }.
 * duplicate:true means an identical submission (same phone + same
 * normalized message within 24h) already exists — the existing tracking
 * code is returned instead of creating a new record (v1.4 §8.10). */
async function submitFeedbackTx(db, opts) {
  const {
    submissionId, type, category, title, message, orderId, phone,
    source, createdBy, serverTimestamp, now, random,
  } = opts;

  const shapeError = validateFeedbackInput({ type, category, title, message });
  if (shapeError) throw new OrderError('INVALID_INPUT', shapeError);

  const normalizedPhone = phone ? String(phone).trim() : null;
  const normalized = normalizeMessage(message);

  /* Spam blocks (phone or IP-hash) — checked before any expensive work. */
  if (normalizedPhone) {
    const blockSnap = await db.collection('feedbackBlocks').doc(`phone:${normalizedPhone}`).get();
    if (blockSnap.exists && toMillis(blockSnap.data().blockedUntil) > now) {
      throw new OrderError('BLOCKED', 'تم حظر الإرسال من هذا الرقم مؤقتاً');
    }
  }

  /* Duplicate check: same phone + same normalized message within 24h.
   * Single-field query (phone only — no composite index needed), time
   * and message filtered in code. */
  if (normalizedPhone) {
    const dupSnap = await db.collection('feedback')
      .where('customerRef.phone', '==', normalizedPhone).limit(20).get();
    for (const doc of dupSnap.docs) {
      const data = doc.data();
      if (data._normalizedMessage !== normalized) continue;
      if (now - toMillis(data.createdAt) > 24 * 60 * 60 * 1000) continue;
      return { trackingCode: data.trackingCode, duplicate: true, linked: !!data.customerRef.linked };
    }
  }

  /* Verified link: orderId + phone must match the order's phone. A bad
   * link does not reject the submission — it is simply untrusted. */
  let linked = false;
  if (orderId && normalizedPhone) {
    const orderSnap = await db.collection('orders').doc(String(orderId)).get();
    if (orderSnap.exists) {
      const orderPhone = String(orderSnap.data().customerPhone || '').trim();
      linked = orderPhone !== '' && orderPhone === normalizedPhone;
    }
  }

  const trackingCode = generateTrackingCode(random);
  const record = {
    id: submissionId,
    trackingCode,
    type,
    category,
    title: String(title).trim(),
    message: String(message).trim(),
    _normalizedMessage: normalized,
    customerRef: { orderId: orderId || null, phone: normalizedPhone, linked },
    status: 'new',
    priority: suggestPriority(message),
    source: source || 'storefront',
    createdBy: createdBy || 'anonymous',
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    repliesCount: 0,
    lastReplyAt: null,
  };
  await db.collection('feedback').doc(submissionId).set(record);
  return { trackingCode, duplicate: false, linked };
}

/* Customer status lookup by tracking code + phone. Returns only
 * { status, lastReply } and only when both match — a mismatch returns
 * NOT_FOUND without saying which part failed (no enumeration). */
async function getFeedbackStatus(db, { trackingCode, phone }) {
  if (!trackingCode || !phone) throw new OrderError('NOT_FOUND', 'كود التتبع أو رقم الموبايل مش صحيح');
  const snap = await db.collection('feedback')
    .where('trackingCode', '==', String(trackingCode).trim()).limit(1).get();
  if (snap.docs.length === 0) throw new OrderError('NOT_FOUND', 'مفيش شكوى بالكود ده');
  const data = snap.docs[0].data();
  if (String(data.customerRef && data.customerRef.phone || '') !== String(phone).trim()) {
    throw new OrderError('NOT_FOUND', 'مفيش شكوى بالكود ده');
  }
  let lastReply = null;
  const repliesSnap = await db.collection('feedback').doc(snap.docs[0].id)
    .collection('replies').orderBy('createdAt', 'desc').limit(1).get();
  if (repliesSnap.docs.length > 0) {
    const reply = repliesSnap.docs[0].data();
    if (reply.visibleToCustomer !== false) lastReply = reply.text;
  }
  return { status: data.status, lastReply };
}

/* Admin reply (batched with the audit entry by the caller — this helper
 * builds the reply record; the Flutter app writes it via Backend).
 * Kept here so the reply shape is defined once. */
function buildReplyRecord({ adminUid, adminName, text, serverTimestamp }) {
  return {
    adminUid, adminName, text: String(text).trim(),
    createdAt: serverTimestamp(), visibleToCustomer: true,
  };
}

module.exports = {
  FEEDBACK_TYPES,
  FEEDBACK_CATEGORIES,
  FEEDBACK_STATUSES,
  FEEDBACK_TRANSITIONS,
  isAllowedFeedbackTransition,
  validateFeedbackInput,
  submitFeedbackTx,
  getFeedbackStatus,
  buildReplyRecord,
};
