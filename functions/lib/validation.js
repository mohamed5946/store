/* Shared server-side validation (design doc file 27, Technical Plan v1.4).
 *
 * The SINGLE implementation of price, stock, discount, and total
 * verification, used by both placeOrder and createManualOrder — so the
 * two order paths can never drift apart. Pure functions only: no
 * firebase-admin import here, so the unit tests run this exact code
 * against a fake Firestore. The only Firebase-shaped values are the
 * FieldValue sentinels, passed in by the caller (index.js) as plain
 * marker objects the fake understands too.
 */

const crypto = require('node:crypto');

/* Limits (v1.2 Decisions 12–14, carried into v1.4). */
const MAX_PRODUCTS_PER_ORDER = 10;
const MAX_QTY_PER_LINE = 20;
const RESERVATION_TTL_MS = 24 * 60 * 60 * 1000; /* 24 hours (Decision 13) */
const RATE_LIMITS = {
  placeOrder: { max: 20, windowMs: 15 * 60 * 1000, blockMs: 15 * 60 * 1000 },
  discount: { max: 10, windowMs: 15 * 60 * 1000, blockMs: 15 * 60 * 1000 },
  feedback: { max: 5, windowMs: 60 * 60 * 1000, blockMs: 15 * 60 * 1000 },
  feedbackStatus: { max: 10, windowMs: 60 * 60 * 1000, blockMs: 15 * 60 * 1000 },
  manualOrder: { max: 30, windowMs: 60 * 60 * 1000, blockMs: 15 * 60 * 1000 },
};

/* Structured error the callables return to the client. `code` is the
 * stable machine code the storefront/admin switch on; `details` carries
 * the values the client shows (never a fake success). */
class OrderError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.code = code;
    this.details = details;
  }
}

/* Merge duplicate lines by productId, summing quantities (T22). Keeps
 * first-seen order. Quantities stay as given; the cap is enforced by
 * validateOrderInput on the merged lines. */
function dedupeItems(items) {
  const merged = new Map();
  for (const line of items || []) {
    const id = String(line.productId || '');
    if (!id) continue;
    const qty = Math.floor(Number(line.qty) || 0);
    if (merged.has(id)) merged.get(id).qty += qty;
    else merged.set(id, { productId: id, qty });
  }
  return [...merged.values()];
}

/* Shape validation for an order request (storefront or manual). Returns
 * an error string, or null when the shape is valid. Prices/totals are
 * NOT validated here — the transaction recomputes them from the database
 * and ignores any client-supplied price/total/discount field. */
function validateOrderInput({ customer, items, discountCode }) {
  if (!customer || typeof customer !== 'object') return 'بيانات العميل ناقصة';
  if (!customer.name || String(customer.name).trim().length === 0) return 'اكتب الاسم';
  const digits = String(customer.phone || '').replace(/\D/g, '');
  if (digits.length < 10) return 'اكتب رقم موبايل صحيح';
  if (!customer.address || String(customer.address).trim().length === 0) return 'اكتب العنوان';
  if (!Array.isArray(items) || items.length === 0) return 'السلة فارغة';
  const distinct = new Set(items.map((l) => String(l.productId || ''))).size;
  if (distinct > MAX_PRODUCTS_PER_ORDER) return 'ORDER_TOO_LARGE';
  for (const line of items) {
    if (!line.productId || String(line.productId).trim() === '') return 'INVALID_INPUT';
    const qty = Number(line.qty);
    if (!Number.isInteger(qty) || qty < 1 || qty > MAX_QTY_PER_LINE) return 'INVALID_INPUT';
  }
  if (discountCode != null && String(discountCode).trim() === '') return 'INVALID_INPUT';
  return null;
}

/* Total from DATABASE prices minus the discount (computed server-side).
 * `lines` are [{ price, qty }] with trusted prices; `discount` is the
 * trusted discount record ({ percent }) or null. */
function computeTotal(lines, discount) {
  const subtotal = lines.reduce((s, l) => s + l.price * l.qty, 0);
  const percent = discount ? discount.percent : 0;
  const discountAmount = Math.round((subtotal * percent) / 100);
  return { subtotal, discountPercent: percent || null, discountAmount, total: subtotal - discountAmount };
}

/* Compare what the client displayed (seenPrices/seenTotal) with the
 * database. Returns null when everything matches, else the structured
 * error (PRICE_CHANGED / TOTAL_CHANGED) with the current values so the
 * client re-renders and asks for a fresh confirm. `seenPrices` is
 * { productId: price }; either field may be absent (older clients). */
function checkSeenPrices({ seenPrices, seenTotal, dbPrices, computed }) {
  /* The client displays the PRE-DISCOUNT total: it cannot know the
   * discount percent (the code's percent lives server-side), so the
   * seen-total check compares against the subtotal whenever a discount
   * was applied, and against the total otherwise. Without this, ANY
   * valid discount code would always fail with TOTAL_CHANGED. */
  const displayedTotal = computed.discountPercent ? computed.subtotal : computed.total;
  if (seenPrices && typeof seenPrices === 'object') {
    const currentPrices = {};
    for (const [id, price] of Object.entries(dbPrices)) {
      currentPrices[id] = price;
      if (seenPrices[id] !== undefined && Number(seenPrices[id]) !== price) {
        return {
          error: new OrderError('PRICE_CHANGED', 'اتغير سعر منتج من اللي شفتهم', {
            currentPrices, currentTotal: displayedTotal,
          }),
        };
      }
    }
  }
  if (seenTotal !== undefined && seenTotal !== null && Number(seenTotal) !== displayedTotal) {
    return {
      error: new OrderError('TOTAL_CHANGED', 'اتغير الإجمالي', {
        currentPrices: dbPrices, currentTotal: displayedTotal,
      }),
    };
  }
  return null;
}

/* SHA-256 hex — rate-limit keys and IP hashes. No raw IP is ever stored. */
function sha256hex(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

/* Client IP from a callable request (Express rawRequest). Trusts the
 * first x-forwarded-for entry (the Functions framework sets it), then
 * the socket address. Returns 'unknown' when nothing is available. */
function clientIp(req) {
  const raw = req && req.rawRequest;
  if (!raw) return 'unknown';
  const forwarded = raw.headers && raw.headers['x-forwarded-for'];
  if (forwarded) return String(forwarded).split(',')[0].trim();
  if (raw.ip) return String(raw.ip);
  if (raw.socket && raw.socket.remoteAddress) return String(raw.socket.remoteAddress);
  return 'unknown';
}

/* Rate-limit check + increment, in ONE transaction on the rateLimits doc
 * (so concurrent calls serialize and the count is exact). `db` is the
 * Firestore interface (real or fake); `now` is ms since epoch (injected
 * for tests). Returns { allowed: true } or { allowed: false,
 * retryAfterMs }. The block applies to the abuse path only — the caller
 * decides what a blocked IP may still do. Counts failed attempts only
 * for the 'discount' kind: the caller increments that kind only when a
 * code attempt fails (see checkDiscountAttempt). */
async function checkRateLimit(db, { key, kind, now }) {
  const rule = RATE_LIMITS[kind];
  const ref = db.collection('rateLimits').doc(key);
  let outcome;
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.exists ? snap.data() : null;
    if (data && data.blockedUntil && toMillis(data.blockedUntil) > now) {
      outcome = { allowed: false, retryAfterMs: toMillis(data.blockedUntil) - now };
      return;
    }
    const windowStart = data && data.windowStart ? toMillis(data.windowStart) : now;
    const count = data ? data.count || 0 : 0;
    const inWindow = data && now - windowStart < rule.windowMs;
    const current = inWindow ? count : 0;
    if (current >= rule.max) {
      tx.set(ref, {
        keyHash: key, kind, count: current, windowStart: inWindow ? windowStart : now,
        blockedUntil: now + rule.blockMs, lastAttempt: now,
      }, { merge: true });
      outcome = { allowed: false, retryAfterMs: rule.blockMs };
      return;
    }
    tx.set(ref, {
      keyHash: key, kind, count: current + 1,
      windowStart: inWindow ? windowStart : now,
      blockedUntil: null, lastAttempt: now,
    }, { merge: true });
    outcome = { allowed: true };
  });
  return outcome;
}

/* A failed discount-code attempt counts toward the 'discount' limit
 * (T18: only FAILED attempts count). Called only when a code was given
 * and rejected. A successful code use does not count. */
async function countFailedDiscountAttempt(db, { key, now }) {
  const rule = RATE_LIMITS.discount;
  const ref = db.collection('rateLimits').doc(key);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.exists ? snap.data() : null;
    const windowStart = data && data.windowStart ? toMillis(data.windowStart) : now;
    const count = data ? data.count || 0 : 0;
    const inWindow = data && now - windowStart < rule.windowMs;
    const current = inWindow ? count : 0;
    if (current + 1 >= rule.max) {
      tx.set(ref, {
        keyHash: key, kind: 'discount', count: current + 1,
        windowStart: inWindow ? windowStart : now,
        blockedUntil: now + rule.blockMs, lastAttempt: now,
      }, { merge: true });
    } else {
      tx.set(ref, {
        keyHash: key, kind: 'discount', count: current + 1,
        windowStart: inWindow ? windowStart : now,
        blockedUntil: null, lastAttempt: now,
      }, { merge: true });
    }
  });
}

/* Discount-block pre-check: has this IP already hit the failed-code
 * limit? Used before validating a code so a blocked IP is rejected fast
 * (T18). Returns { blocked, retryAfterMs }. */
async function discountBlocked(db, { key, now }) {
  const snap = await db.collection('rateLimits').doc(key).get();
  const data = snap.exists ? snap.data() : null;
  if (!data || data.kind !== 'discount') return { blocked: false };
  if (data.blockedUntil && toMillis(data.blockedUntil) > now) {
    return { blocked: true, retryAfterMs: toMillis(data.blockedUntil) - now };
  }
  return { blocked: false };
}

/* Milliseconds from a Firestore Timestamp, a Date, an ISO string, or a
 * plain number (the fake Firestore stores serverTimestamp() as ms). */
function toMillis(value) {
  if (value == null) return 0;
  if (typeof value === 'number') return value;
  if (typeof value === 'string') return Date.parse(value) || 0;
  if (typeof value.toMillis === 'function') return value.toMillis();
  if (value instanceof Date) return value.getTime();
  if (typeof value.seconds === 'number') return value.seconds * 1000;
  return 0;
}

/* Feedback: keyword-based priority SUGGESTION (v1.4 §8.4) — a suggestion
 * the admin confirms or changes, never an auto-set. Arabic + English
 * keywords; 'urgent' is never suggested (admin-only). */
function suggestPriority(message) {
  const text = String(message || '').toLowerCase();
  const high = ['استرجاع', 'استرداد', 'مكسور', 'تالف', 'غلط', 'موصلش', 'لم يصل', 'ناقص', 'خربان',
    'refund', 'broken', 'wrong order', 'never arrived', 'damaged', 'missing'];
  if (high.some((k) => text.includes(k))) return 'high';
  const medium = ['تأخير', 'متأخر', 'بطيء', 'بطئ', 'late', 'delay', 'slow'];
  if (medium.some((k) => text.includes(k))) return 'medium';
  return 'low';
}

/* Tracking code: FB-XXXXXX (6 chars, no look-alike confusion: no 0/O/1/I). */
function generateTrackingCode(random = Math.random) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let code = '';
  for (let i = 0; i < 6; i++) code += alphabet[Math.floor(random() * alphabet.length)];
  return `FB-${code}`;
}

/* Duplicate-detection normalization: trimmed, lowercased, collapsed
 * whitespace (v1.4 §8.10). */
function normalizeMessage(message) {
  return String(message || '').trim().toLowerCase().replace(/\s+/g, ' ');
}

module.exports = {
  MAX_PRODUCTS_PER_ORDER,
  MAX_QTY_PER_LINE,
  RESERVATION_TTL_MS,
  RATE_LIMITS,
  OrderError,
  dedupeItems,
  validateOrderInput,
  computeTotal,
  checkSeenPrices,
  sha256hex,
  clientIp,
  checkRateLimit,
  countFailedDiscountAttempt,
  discountBlocked,
  toMillis,
  suggestPriority,
  generateTrackingCode,
  normalizeMessage,
};
