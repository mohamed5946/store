/* Store Admin Cloud Functions — the trusted backend (Technical Plan
 * v1.4, design doc files 25–27). Thin wiring only: the real logic lives
 * in lib/ (validation.js, orders.js, feedback.js, sweep.js) so the unit
 * tests run the exact code. Node.js 20, firebase-functions v2,
 * us-central1 (the default region the apps call).
 *
 * Deploy (after Blaze is enabled + Firebase CLI auth):
 *   firebase deploy --only functions
 * NOT deployed from this sandbox (no Firebase CLI auth here).
 */

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const admin = require('firebase-admin');

admin.initializeApp();
const db = admin.firestore();
const FieldValue = admin.firestore.FieldValue;

const {
  OrderError, validateOrderInput, clientIp, sha256hex,
  checkRateLimit, countFailedDiscountAttempt, discountBlocked,
} = require('./lib/validation');
const { createOrderTx } = require('./lib/orders');
const { submitFeedbackTx, getFeedbackStatus } = require('./lib/feedback');
const { sweepExpiredReservations, exportFirestore } = require('./lib/sweep');

/* Map a structured OrderError to the callable error the client reads:
 * e.code is the generic HttpsError code; e.details.code is the stable
 * machine code the storefront/admin switch on (PRICE_CHANGED, ...). */
const HTTPS_CODE = {
  INVALID_INPUT: 'invalid-argument',
  ORDER_TOO_LARGE: 'invalid-argument',
  PRICE_CHANGED: 'failed-precondition',
  TOTAL_CHANGED: 'failed-precondition',
  DISCOUNT_CHANGED: 'failed-precondition',
  DISCOUNT_USED: 'failed-precondition',
  DISCOUNT_INVALID: 'failed-precondition',
  INSUFFICIENT_STOCK: 'failed-precondition',
  RATE_LIMITED: 'resource-exhausted',
  BLOCKED: 'permission-denied',
  NOT_FOUND: 'not-found',
  PERMISSION_DENIED: 'permission-denied',
};

function toHttpsError(err) {
  if (err instanceof OrderError) {
    return new HttpsError(HTTPS_CODE[err.code] || 'internal', err.message, {
      code: err.code, ...err.details,
    });
  }
  return new HttpsError('internal', err.message || 'Internal error');
}

const serverTimestamp = () => FieldValue.serverTimestamp();
const ipKey = (req, suffix = '') => `ip:${sha256hex(clientIp(req))}${suffix}`;

/* ---------------- placeOrder (storefront) ---------------- */
exports.placeOrder = onCall(async (req) => {
  const data = req.data || {};
  try {
    const shapeError = validateOrderInput({
      customer: data.customer, items: data.items, discountCode: data.discountCode,
    });
    if (shapeError === 'ORDER_TOO_LARGE') {
      throw new OrderError('ORDER_TOO_LARGE', 'الطلب فيه منتجات أكتر من الحد المسموح', { maxProducts: 10 });
    }
    if (shapeError) throw new OrderError('INVALID_INPUT', shapeError);

    const now = Date.now();
    const limited = await checkRateLimit(db, { key: ipKey(req), kind: 'placeOrder', now });
    if (!limited.allowed) {
      throw new OrderError('RATE_LIMITED', 'محاولات كتير — حاول تاني بعد شوية', {
        retryAfterMs: limited.retryAfterMs,
      });
    }

    /* A blocked IP (10 failed code attempts) is rejected on the code
     * path before any discount work; ordering WITHOUT a code still works. */
    if (data.discountCode) {
      const blocked = await discountBlocked(db, { key: ipKey(req, ':discount'), now });
      if (blocked.blocked) {
        throw new OrderError('RATE_LIMITED', 'محاولات كتير على كود الخصم — حاول تاني بعد شوية', {
          retryAfterMs: blocked.retryAfterMs,
        });
      }
    }

    let result;
    try {
      result = await createOrderTx(db, {
        clientOrderId: data.clientOrderId,
        items: data.items,
        discountCode: data.discountCode || null,
        customer: data.customer,
        source: 'storefront',
        createdBy: null,
        shippingCompanyId: null,
        notes: null,
        seenPrices: data.seenPrices || null,
        seenTotal: data.seenTotal ?? null,
        serverTimestamp,
      });
    } catch (e) {
      /* A failed discount attempt counts toward the guessing limit
       * (failed attempts only — T18). */
      if (data.discountCode && e instanceof OrderError
        && (e.code === 'DISCOUNT_INVALID' || e.code === 'DISCOUNT_USED')) {
        await countFailedDiscountAttempt(db, { key: ipKey(req, ':discount'), now }).catch(() => {});
      }
      throw e;
    }
    return { order: result.order, created: result.created };
  } catch (e) {
    throw toHttpsError(e);
  }
});

/* ---------------- createManualOrder (admin apps) ---------------- */
exports.createManualOrder = onCall(async (req) => {
  const data = req.data || {};
  try {
    if (!req.auth) throw new OrderError('PERMISSION_DENIED', 'لازم تسجيل الدخول');
    const uid = req.auth.uid;
    const adminSnap = await db.collection('admins').doc(uid).get();
    const adminDoc = adminSnap.exists ? adminSnap.data() : null;
    const role = adminDoc && adminDoc.role;
    const perms = (adminDoc && adminDoc.permissions) || {};
    /* Admins have all permissions by default; managers need the explicit
     * orders_create_manual flag (v1.4 §7.4). The UI hiding the button is
     * not security — this check runs server-side on every call. */
    const allowed = role === 'admin'
      || (role === 'manager' && perms.orders_create_manual === true);
    if (!allowed) throw new OrderError('PERMISSION_DENIED', 'مفيش صلاحية لإنشاء طلب يدوي');

    const now = Date.now();
    const limited = await checkRateLimit(db, { key: `uid:${uid}`, kind: 'manualOrder', now });
    if (!limited.allowed) {
      throw new OrderError('RATE_LIMITED', 'محاولات كتير — حاول تاني بعد شوية', {
        retryAfterMs: limited.retryAfterMs,
      });
    }

    const result = await createOrderTx(db, {
      clientOrderId: data.clientOrderId,
      items: data.items,
      discountCode: data.discountCode || null,
      customer: data.customer,
      source: 'admin_manual',
      createdBy: uid,
      shippingCompanyId: data.shippingCompanyId || null,
      notes: data.notes || null,
      seenPrices: data.seenPrices || null,
      seenTotal: data.seenTotal ?? null,
      serverTimestamp,
    });
    return { order: result.order, created: result.created };
  } catch (e) {
    throw toHttpsError(e);
  }
});

/* ---------------- submitFeedback (storefront + admin apps) ---------------- */
exports.submitFeedback = onCall(async (req) => {
  const data = req.data || {};
  try {
    const now = Date.now();
    const limited = await checkRateLimit(db, { key: ipKey(req, ':feedback'), kind: 'feedback', now });
    if (!limited.allowed) {
      throw new OrderError('RATE_LIMITED', 'محاولات كتير — حاول تاني بعد شوية', {
        retryAfterMs: limited.retryAfterMs,
      });
    }
    const result = await submitFeedbackTx(db, {
      submissionId: data.submissionId,
      type: data.type,
      category: data.category,
      title: data.title,
      message: data.message,
      orderId: data.orderId || null,
      phone: data.phone || null,
      source: req.auth ? 'admin_manual' : 'storefront',
      createdBy: req.auth ? req.auth.uid : 'anonymous',
      serverTimestamp,
      now,
    });
    return result;
  } catch (e) {
    throw toHttpsError(e);
  }
});

/* ---------------- getFeedbackStatus (customer lookup) ---------------- */
exports.getFeedbackStatus = onCall(async (req) => {
  const data = req.data || {};
  try {
    const now = Date.now();
    const limited = await checkRateLimit(db, { key: ipKey(req, ':feedbackStatus'), kind: 'feedbackStatus', now });
    if (!limited.allowed) {
      throw new OrderError('RATE_LIMITED', 'محاولات كتير — حاول تاني بعد شوية', {
        retryAfterMs: limited.retryAfterMs,
      });
    }
    return await getFeedbackStatus(db, {
      trackingCode: data.trackingCode, phone: data.phone,
    });
  } catch (e) {
    throw toHttpsError(e);
  }
});

/* ---------------- sweepExpiredReservations (hourly) ---------------- */
exports.sweepExpiredReservations = onSchedule(
  { schedule: 'every 60 minutes', timeZone: 'Africa/Cairo' },
  async () => {
    const result = await sweepExpiredReservations(db, {
      now: Date.now(), serverTimestamp,
    });
    console.log(`sweep: released ${result.released} of ${result.checked} new orders`);
    return result;
  },
);

/* ---------------- scheduledFirestoreExport (weekly) ---------------- */
exports.scheduledFirestoreExport = onSchedule(
  { schedule: 'every monday 03:00', timeZone: 'Africa/Cairo' },
  async () => {
    const app = admin.app();
    const projectId = app.options.projectId;
    const bucket = app.options.storageBucket || `${projectId}.appspot.com`;
    const credential = app.options.credential;
    const result = await exportFirestore(db, {
      projectId,
      bucket,
      now: Date.now(),
      serverTimestamp,
      fetchImpl: fetch,
      getAccessToken: async () => {
        const token = await credential.getAccessToken();
        return token.access_token;
      },
    });
    console.log(`export: ${result.status} — ${result.detail}`);
    return result;
  },
);
