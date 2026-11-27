/* Faithful restore of the user-supplied glass storefront design, rewired to
 * the store's real Firestore backend. The LOOK is the original exactly:
 * teal accent #3f7f8c + sage #8fb8b0 (and dark variants), earbuds hero
 * illustration, original hero copy, Tajawal + Inter, glass surfaces.
 *
 * DESIGN DOC — storeSettings/design is read ONLY for announcementBar and
 * section toggles. The accentColor field is DELIBERATELY IGNORED in this
 * version: the look is fixed teal per the owner's explicit restore decision,
 * not re-themed from the doc. (The app's design editor for announcement /
 * sections still applies; accent edits there have no effect here.)
 *
 * APP-EDITABLE FIELDS (all optional; every one falls back to the ORIGINAL
 * look/text when missing or empty — the page then renders EXACTLY like the
 * faithful restore). A future admin-app build implements the editor for
 * these; the field names below are the contract it must write.
 * - storeSettings/settings.logoImageUrl (string, default ""): brand logo
 *   mark image shown in the topbar next to the brand name. When set to a
 *   non-empty URL it replaces the pulse SVG mark (same 40x40 box, radius
 *   14px, object-fit contain). When empty/missing the pulse SVG renders.
 * - storeSettings/homepage.heroImageUrl (string, default ""): hero image
 *   shown inside the hero card. When set it fills the card's visual area
 *   (object-fit cover, card radius); the earbuds SVG and its two float
 *   chips are hidden with it (the chips carry earbuds-specific claims).
 *   When empty/missing the original earbuds SVG + chips render exactly.
 * - storeSettings/homepage.heroTitle (string): hero headline first line.
 *   Default (when missing/empty): "نبض التكنولوجيا" (the original line).
 * - storeSettings/homepage.heroAccent (string): hero headline accent
 *   second line, keeps its accent color class. Default: "في كل تفصيلة".
 * - storeSettings/homepage.heroSubtitle (string): hero paragraph below
 *   the headline. Default: the original tech subcopy, verbatim.
 * All five fields accept any string; only non-empty (after trim) values
 * override. Field URLs are the store's own Cloudinary uploads (f_auto,
 * q_auto applied via deliveryUrl; non-Cloudinary links pass through).
 *
 * TEMPLATES (Phase 3): the storefront renders the active template
 * (storeSettings/activeTemplate -> templates/{id}). The template is
 * declarative JSON only — tokens (CSS variables), grid (rows x
 * columns), section toggles. No template code runs here. When no
 * pointer/template exists, the bundled templates/classic.json is
 * used, then the built-in classic below — so the launch site renders
 * exactly like today.
 *
 * FROZEN RULES (never weaken these):
 * - 2-step Cash-on-Delivery checkout ONLY: info -> review -> order doc.
 * - Checkout DRAFTS (incomplete orders, 2026-11-27, author decision):
 *   the form syncs to the server as the customer types — local first
 *   on every keystroke, server sync after 10s idle / field exit /
 *   page hide, only once a complete valid Egyptian mobile exists —
 *   with NO consent line and NO opt-out. The author decided the
 *   details are sent as typed, because a customer whose connection
 *   drops cannot consent, and a customer who never returns cannot be
 *   asked. The analytics/attempts contact write below still happens
 *   ONLY after the info step completes with valid data.
 * - The order doc is created EXACTLY ONCE, before the journey animation.
 *   On failure the real error shows and NO animation plays (never fake).
 * - Analytics are anonymous (random localStorage id, heartbeat, funnel).
 * - No invented stats or product claims anywhere.
 */

import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js';
import {
  getFirestore, collection, query, orderBy, getDocs, doc, getDoc,
  setDoc, updateDoc, serverTimestamp, arrayUnion, runTransaction,
  writeBatch,
} from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js';

const app = initializeApp(window.STORE_FIREBASE_CONFIG);
const db = getFirestore(app);

/* Shell version (templates spec Section 2): defined in exactly one
 * place here, mirrored as data-shell-version on <html> in
 * index.html. MAJOR when a behaviour is removed or a slot/hook is
 * renamed; MINOR when a behaviour or slot is added; PATCH for shell
 * fixes that change no contract. A bundle whose shellMinVersion is
 * newer than this fails the gateway and falls back to classic. */
const SHELL_VERSION = '1.0.0';

/* ---------- anonymous session + funnel ---------- */
let sessionId = localStorage.getItem('store_session_id');
if (!sessionId) {
  sessionId = 's_' + Math.random().toString(36).slice(2) + Date.now().toString(36);
  localStorage.setItem('store_session_id', sessionId);
}
const sessionStart = Date.now();
const sessionRef = doc(db, 'analytics', 'sessions', 'items', sessionId);
const stepsSeen = new Set(['home']);
async function recordStep(step) {
  if (stepsSeen.has(step)) return;
  stepsSeen.add(step);
  try { await updateDoc(sessionRef, { steps: arrayUnion(step) }); } catch (_) {}
}
/* ---------- template observability + heartbeat (templates) ------
 * Session stamping order (spec M23): the session setDoc used to fire
 * at module load, BEFORE bundle resolution, so templateId could not
 * be stamped at creation. The write is now DEFERRED until after
 * bundle resolution (writeSessionDoc, called from loadActiveTemplate
 * on every path incl. fallback) — templateId + version are stamped
 * at creation. Cost: the same 1 session write per visit, just later;
 * the +1 write the spec's M15 table counts is the template_loaded
 * stamp folded into this same write (no separate document).
 * Heartbeat: only while the tab is visible AND the visitor is
 * active (pointer/key/scroll in the last 60s), capped at 60 beats
 * per session. For feed templates the interval lengthens to 60s
 * after the first 5 minutes. It stops once the funnel is recorded
 * (order attempt created) and resumes only on cart/checkout
 * activity. High-frequency telemetry (scroll, countdown ticks, card
 * entrances, sampled image errors) is counted IN MEMORY and flushed
 * as ONE aggregated update per session on pagehide — at most 1
 * write/session. NO GA4 is added by this feature. */
let sessionDocWritten = false;
let sessionTemplateId = 'classic';
let sessionTemplateVersion = '1.0.0';
/* Bundle state is declared here (not in the template section below)
 * because heartbeatIntervalMs() reads it during module evaluation. */
let activeBundleManifest = null; // non-null only for a loaded bundle
let heartbeatBeats = 0;
let funnelRecorded = false;
let lastActivityAt = Date.now();
let serverTimeOffsetMs = 0; // server clock minus device clock, ms
let telemetryCounts = {};
let telemetryFlushed = false;
function countTelemetry(name, n) {
  telemetryCounts[name] = (telemetryCounts[name] || 0) + (n || 1);
}
async function writeSessionDoc(extra) {
  if (sessionDocWritten && !extra) return;
  sessionDocWritten = true;
  try {
    await setDoc(sessionRef, {
      startedAt: serverTimestamp(), lastSeenAt: serverTimestamp(),
      durationMs: 0, steps: ['home'],
      templateId: sessionTemplateId, templateVersion: sessionTemplateVersion,
      shellVersion: SHELL_VERSION,
      ...(extra || {}),
    }, { merge: true });
  } catch (_) {}
}
/* Named template events (ids only, NEVER PII): stamped onto the
 * session doc (one update each, rare paths only) and counted in the
 * in-memory telemetry. A denied write never breaks the store. */
async function recordTemplateEvent(name, fields) {
  countTelemetry('event_' + name, 1);
  try {
    await updateDoc(sessionRef, {
      ['last_' + name]: serverTimestamp(),
      templateId: sessionTemplateId, templateVersion: sessionTemplateVersion,
      ...(fields || {}),
    });
  } catch (_) {}
}
function flushTelemetry() {
  if (telemetryFlushed) return;
  telemetryFlushed = true;
  const counts = telemetryCounts;
  if (Object.keys(counts).length === 0) return;
  try {
    updateDoc(sessionRef, { telemetryCounts: counts, telemetryFlushedAt: serverTimestamp() }).catch(() => {});
  } catch (_) {}
}
function noteActivity() { lastActivityAt = Date.now(); }
['pointerdown', 'keydown', 'scroll', 'wheel', 'touchstart'].forEach((ev) => {
  window.addEventListener(ev, noteActivity, { passive: true });
});
function heartbeatIntervalMs() {
  // Feed templates keep visitors scrolling 2-3x longer: after the
  // first 5 minutes the interval lengthens to 60s.
  const feedMode = activeBundleManifest && Array.isArray(activeBundleManifest.behaviours)
    && activeBundleManifest.behaviours.includes('feed');
  if (feedMode && Date.now() - sessionStart > 5 * 60 * 1000) return 60000;
  return 30000;
}
async function heartbeat() {
  if (!sessionDocWritten) return;
  if (document.hidden) return;
  if (Date.now() - lastActivityAt > 60000) return; // visitor idle
  if (heartbeatBeats >= 60) return; // cap: 60 beats/session
  if (funnelRecorded) return; // stopped once the funnel is recorded
  heartbeatBeats += 1;
  try {
    await updateDoc(sessionRef, { lastSeenAt: serverTimestamp(), durationMs: Date.now() - sessionStart });
  } catch (_) {}
}
function scheduleHeartbeat() { setTimeout(async () => { await heartbeat(); scheduleHeartbeat(); }, heartbeatIntervalMs()); }
scheduleHeartbeat();
window.addEventListener('pagehide', () => { flushTelemetry(); heartbeat(); });
/* Sampled image errors (1-in-10, templateId + product id only): the
 * product id comes from the closest [data-id] / [data-product-id]. */
document.addEventListener('error', (e) => {
  const t = e.target;
  if (!t || t.tagName !== 'IMG') return;
  if (Math.random() >= 0.1) return;
  const holder = t.closest ? t.closest('[data-id], [data-product-id]') : null;
  const pid = holder ? (holder.dataset.id || holder.dataset.productId || '') : '';
  countTelemetry('image_error', 1);
  recordTemplateEvent('image_error', { productId: pid || null });
}, true);

/* PURE-HELPERS-BEGIN — incomplete orders (2026-11-27).
 * Self-contained pure helpers (no DOM, no Firebase, no top-level
 * side effects) shared by the storefront code below and by the Node
 * unit tests (test/storefront_draft_test.js extracts exactly this
 * block — keep it dependency-free and keep the markers intact). The
 * canonical schemas live in docs/incomplete-orders-schema.md. */
const GOVERNORATES_27 = [
  { id: 'cairo', name: 'القاهرة' }, { id: 'giza', name: 'الجيزة' },
  { id: 'alexandria', name: 'الإسكندرية' }, { id: 'dakahlia', name: 'الدقهلية' },
  { id: 'red-sea', name: 'البحر الأحمر' }, { id: 'beheira', name: 'البحيرة' },
  { id: 'fayoum', name: 'الفيوم' }, { id: 'gharbia', name: 'الغربية' },
  { id: 'ismailia', name: 'الإسماعيلية' }, { id: 'menofia', name: 'المنوفية' },
  { id: 'minya', name: 'المنيا' }, { id: 'qalyubia', name: 'القليوبية' },
  { id: 'new-valley', name: 'الوادي الجديد' }, { id: 'suez', name: 'السويس' },
  { id: 'asyut', name: 'أسيوط' }, { id: 'sohag', name: 'سوهاج' },
  { id: 'qena', name: 'قنا' }, { id: 'luxor', name: 'الأقصر' },
  { id: 'aswan', name: 'أسوان' }, { id: 'sharqia', name: 'الشرقية' },
  { id: 'port-said', name: 'بورسعيد' }, { id: 'damietta', name: 'دمياط' },
  { id: 'kafr-el-sheikh', name: 'كفر الشيخ' }, { id: 'beni-suef', name: 'بني سويف' },
  { id: 'matrouh', name: 'مطروح' }, { id: 'north-sinai', name: 'شمال سيناء' },
  { id: 'south-sinai', name: 'جنوب سيناء' },
];
const EGYPTIAN_MOBILE_RE = /^01[0125][0-9]{8}$/;
/* Digits only; a leading +20 / 20 country code is folded back to
 * the local 01… form, so pasted international numbers validate. */
function normalizeEgyptianMobile(phone) {
  const digits = String(phone || '').replace(/\D/g, '');
  if (digits.length === 12 && digits.startsWith('20')) return '0' + digits.slice(2);
  return digits;
}
function isValidEgyptianMobile(phone) {
  return EGYPTIAN_MOBILE_RE.test(normalizeEgyptianMobile(phone));
}
/* Visible seconds -> stored dwell band token (ASCII). 9s -> '<10s';
 * 10s and 60s -> '10-60s'; 61s -> '>60s'. Hidden-tab time is never
 * passed in (the caller excludes it). */
function dwellBand(visibleSeconds) {
  const s = Number(visibleSeconds) || 0;
  if (s < 10) return '<10s';
  if (s <= 60) return '10-60s';
  return '>60s';
}
/* One cart line's availability from live inventory: available is
 * (stock - reserved), clamped at 0 by the caller. ok: qty fits;
 * out: nothing available; short: some available, less than qty. */
function lineAvailability(availableQty, qty) {
  const avail = Math.max(0, Math.floor(Number(availableQty) || 0));
  const q = Math.max(0, Math.floor(Number(qty) || 0));
  if (avail <= 0) return { state: 'out', availableQty: 0 };
  if (q <= avail) return { state: 'ok', availableQty: avail };
  return { state: 'short', availableQty: avail };
}
/* Draft completeness 0–100: 25 points each for name, a valid phone,
 * a non-empty cart, and an address (governorate + detailed, or the
 * combined field). */
function draftTriageScore(parts) {
  const p = parts || {};
  let score = 0;
  if (p.name) score += 25;
  if (p.phone) score += 25;
  if (p.cart) score += 25;
  if (p.address) score += 25;
  return score;
}
/* Governorate list resolution: a missing/unreadable document falls
 * back to the full hardcoded 27 so checkout never breaks; a
 * document with zero active entries is the "not set up" state, not
 * an empty dropdown. */
function governorateFallback(docData) {
  const entries = docData && Array.isArray(docData.entries) ? docData.entries : null;
  if (!entries) return { entries: GOVERNORATES_27.map((g) => ({ id: g.id, name: g.name })), fromFallback: true, notSetUp: false };
  const active = entries
    .filter((e) => e && e.active === true && typeof e.id === 'string' && e.id && typeof e.name === 'string' && e.name)
    .map((e) => ({ id: e.id, name: e.name }));
  if (active.length === 0) return { entries: [], fromFallback: false, notSetUp: true };
  return { entries: active, fromFallback: false, notSetUp: false };
}
/* Draft server-sync gate: null when a sync may run, else the reason
 * ('throttle' — a sync ran less than 30s ago; 'cap' — 20 server
 * saves already used in this session). Pure, so the tests assert it
 * without a clock or Firestore. */
function draftSyncBlockReason(state) {
  const s = state || {};
  const now = Number(s.nowMs) || 0;
  if (Number(s.savesUsed) >= 20) return 'cap';
  if (s.lastSyncAtMs != null && now - Number(s.lastSyncAtMs) < 30000) return 'throttle';
  return null;
}
/* Checkout is blocked before the details step when any cart line is
 * unorderable (state 'out' or 'short'). `lineStates` is an array of
 * availability state strings. */
function cartHasUnorderableLine(lineStates) {
  return (lineStates || []).some((st) => st !== 'ok');
}
if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    GOVERNORATES_27, EGYPTIAN_MOBILE_RE, normalizeEgyptianMobile,
    isValidEgyptianMobile, dwellBand, lineAvailability,
    draftTriageScore, governorateFallback, draftSyncBlockReason,
    cartHasUnorderableLine,
  };
}
/* PURE-HELPERS-END */

/* ---------- incomplete orders: session token, GA4, quota ---------- */
/* One stable draft/session token per browser (localStorage
 * `sp-draft-token`, alongside the existing `store_session_id`). The
 * draft document's ID is the session ID and the document stores the
 * token; the rules allow anonymous create only with a token and
 * anonymous update only when the incoming token equals the stored
 * one. A second tab shares storage and token (last save wins); a
 * second device has a different token and creates a second draft,
 * deduped by phone in the admin list. */
let sessionToken = null;
try { sessionToken = localStorage.getItem('sp-draft-token'); } catch (_) {}
if (!sessionToken) {
  sessionToken = 't_' + Math.random().toString(36).slice(2) + Date.now().toString(36);
  try { localStorage.setItem('sp-draft-token', sessionToken); } catch (_) {}
}
/* GA4 (visits + aggregate journeys): the gtag.js loader runs only
 * when a measurement ID exists in firebase-config.js
 * (window.STORE_GA4_ID). It is injected from here — not as an inline
 * snippet — because the page CSP has no 'unsafe-inline'. While the
 * ID is empty, no GA4 call is made anywhere and the storefront
 * works exactly as before; visits/journeys field testing waits on
 * Mohamed creating the GA4 property and pasting the ID. */
function loadGA4() {
  const id = window.STORE_GA4_ID;
  if (!id || typeof document === 'undefined' || window.gtag) return;
  try {
    const s = document.createElement('script');
    s.async = true;
    s.src = 'https://www.googletagmanager.com/gtag/js?id=' + encodeURIComponent(id);
    document.head.appendChild(s);
    window.dataLayer = window.dataLayer || [];
    window.gtag = function () { window.dataLayer.push(arguments); };
    window.gtag('js', new Date());
    window.gtag('config', id, { anonymize_ip: true });
  } catch (_) { /* analytics must never break the store */ }
}
function gaEvent(name, params) {
  try {
    if (!window.STORE_GA4_ID || typeof window.gtag !== 'function') return;
    window.gtag('event', name, params || {});
  } catch (_) {}
}
/* Quota cut-off (manual flip by Mohamed in admin): 'none' (normal),
 * 'journeys' (journey-summary writes stop), 'drafts' (draft sync
 * pauses too — the local copy keeps working). Order writes are never
 * cut. Read once per session at boot. */
let quotaCutoff = 'none';
async function loadQuota() {
  try {
    const snap = await getDoc(doc(db, 'storeSettings', 'quota'));
    const d = snap.exists() ? snap.data() : {};
    if (typeof d.cutoffLevel === 'string') quotaCutoff = d.cutoffLevel;
  } catch (_) { /* unknown quota means normal operation */ }
}

/* ---------- incomplete orders: governorates ---------- */
let governoratesCache = null; // {entries, fromFallback, notSetUp, at}
async function loadGovernorates(force) {
  const now = Date.now();
  if (!force && governoratesCache && now - governoratesCache.at < 5 * 60 * 1000) return governoratesCache;
  try {
    const snap = await getDoc(doc(db, 'storeSettings', 'governorates'));
    governoratesCache = governorateFallback(snap.exists() ? snap.data() : null);
  } catch (_) {
    governoratesCache = governorateFallback(null);
  }
  governoratesCache.at = now;
  return governoratesCache;
}
function governorateName(id) {
  const list = (governoratesCache && governoratesCache.entries) || GOVERNORATES_27;
  const g = list.find((x) => x.id === id);
  return g ? g.name : '';
}

/* ---------- incomplete orders: live availability [OOS] ---------- */
/* Availability is computed per cart line from live inventory, not
 * from the cached products.inStock boolean — one inventory read per
 * distinct product, cached at most 60 seconds per tab (the same
 * pattern as refreshCartPrices). A missing inventory doc means zero
 * available. */
const inventoryCache = {}; // productId -> {stock, reserved, at}
const lineAvailabilityMap = {}; // productId -> {state, availableQty}
async function getProductAvailability(productId) {
  const now = Date.now();
  const cached = inventoryCache[productId];
  if (cached && now - cached.at < 60000) return cached;
  let entry = { stock: 0, reserved: 0, at: now };
  try {
    const snap = await getDoc(doc(db, 'inventory', productId));
    if (snap.exists()) {
      const d = snap.data();
      entry = { stock: Number(d.stock) || 0, reserved: Number(d.reserved) || 0, at: now };
    }
  } catch (_) { /* keep zero availability on a failed read */ }
  inventoryCache[productId] = entry;
  return entry;
}
async function refreshCartAvailability() {
  const lines = cartLines();
  if (lines.length === 0) return;
  let changed = false;
  for (const { p, qty } of lines) {
    const inv = await getProductAvailability(p.id);
    const next = lineAvailability(Math.max(0, inv.stock - inv.reserved), qty);
    const prev = lineAvailabilityMap[p.id];
    if (!prev || prev.state !== next.state || prev.availableQty !== next.availableQty) {
      lineAvailabilityMap[p.id] = next;
      changed = true;
    }
  }
  if (changed) renderCart();
}

/* ---------- incomplete orders: checkout draft autosave ---------- */
/* Local first: every keystroke saves to localStorage instantly
 * ('sp-draft'), so a refresh or a closed tab restores the form with
 * zero server writes. Server sync runs only when the data changed,
 * after 10 seconds idle, on field exit, and on page hide — at most
 * one sync per 30 seconds and at most 20 server saves per draft per
 * session — and only once a complete valid Egyptian mobile exists
 * (before that the draft stays local-only). Sync never blocks the
 * final submit; a failed write retries once in the background and
 * never shows an error to the customer. */
const draftSync = { lastSyncAtMs: 0, savesUsed: 0, timer: null, lastSentJson: '', serverCreated: false };
try { draftSync.serverCreated = localStorage.getItem('sp-draft-synced') === '1'; } catch (_) {}
function readLocalDraft() {
  try {
    const raw = localStorage.getItem('sp-draft');
    if (!raw) return null;
    const d = JSON.parse(raw);
    return (d && typeof d === 'object') ? d : null;
  } catch (_) { return null; }
}
function readDraftForm() {
  const local = readLocalDraft() || {};
  const val = (id) => { const el = document.getElementById(id); return el ? el.value : undefined; };
  return {
    name: val('fName') ?? local.name ?? '',
    phone: val('fPhone') ?? local.phone ?? '',
    phone2: val('fPhone2') ?? local.phone2 ?? '',
    governorate: val('fGov') ?? local.governorate ?? '',
    detailedAddress: val('fAddr') ?? local.detailedAddress ?? '',
    address: local.address ?? '',
  };
}
function saveDraftLocal() {
  try {
    const form = readDraftForm();
    const cartSnapshot = cartLines().map((l) => ({ productId: l.p.id, qty: l.qty, price: Number(l.p.price) || 0 }));
    localStorage.setItem('sp-draft', JSON.stringify({ ...form, cart: cartSnapshot, savedAt: Date.now() }));
  } catch (_) { /* storage unavailable — restore just won't happen */ }
}
function clearLocalDraft() {
  try {
    localStorage.removeItem('sp-draft');
    localStorage.removeItem('sp-draft-synced');
  } catch (_) {}
  draftSync.serverCreated = false;
  draftSync.lastSentJson = '';
  draftSync.savesUsed = 0;
}
function draftPayload() {
  const form = readDraftForm();
  const phone = normalizeEgyptianMobile(form.phone);
  const phone2 = normalizeEgyptianMobile(form.phone2);
  const govName = governorateName(form.governorate);
  const address = (form.detailedAddress && govName)
    ? govName + ' — ' + form.detailedAddress
    : (form.detailedAddress || form.address || '');
  const lines = cartLines().map((l) => {
    const av = lineAvailabilityMap[l.p.id] || { state: 'ok', availableQty: 0 };
    return { productId: l.p.id, qty: l.qty, priceAtDraft: Number(l.p.price) || 0, availability: av.state, availableQty: av.availableQty };
  });
  const payload = {
    sessionId, sessionToken,
    name: String(form.name || '').slice(0, 100),
    phone,
    phone2: phone2 || null,
    governorate: form.governorate || null,
    detailedAddress: form.detailedAddress ? String(form.detailedAddress).slice(0, 500) : null,
    address: String(address).slice(0, 500),
    cart: lines,
    completeness: draftTriageScore({
      name: !!String(form.name || '').trim(),
      phone: isValidEgyptianMobile(phone),
      cart: lines.length > 0,
      address: !!String(address).trim(),
    }),
    lastSyncAt: serverTimestamp(),
    schemaVersion: 1,
  };
  if (!draftSync.serverCreated) {
    payload.status = 'new';
    payload.orderId = null;
    payload.mootOrderId = null;
    payload.createdAt = serverTimestamp();
  }
  return payload;
}
async function syncDraftToServer() {
  // Preview mode must NOT pollute the admin's incomplete-orders
  // list: a preview visit is Mohamed judging a template, not a
  // customer abandoning a checkout. The attempt/analytics doc may
  // stay (journey tracking is preview-safe); the checkout draft
  // never syncs while ?preview= is active. Narrow guard only —
  // local autosave (saveDraftLocal) keeps working in preview.
  if (isPreviewMode) return;
  if (quotaCutoff === 'drafts') return; // manual cut-off: local copy keeps working
  const form = readDraftForm();
  const phone = normalizeEgyptianMobile(form.phone);
  /* Escalation: the draft syncs to the server only once a complete
   * valid Egyptian mobile exists — or once it already lives on the
   * server (a later edit back to an invalid number still syncs). */
  if (!isValidEgyptianMobile(phone) && !draftSync.serverCreated) return;
  const payload = draftPayload();
  const comparable = JSON.stringify({ ...payload, lastSyncAt: null, createdAt: null });
  if (comparable === draftSync.lastSentJson) return; // nothing changed
  const blocked = draftSyncBlockReason({
    lastSyncAtMs: draftSync.lastSyncAtMs, savesUsed: draftSync.savesUsed, nowMs: Date.now(),
  });
  if (blocked) return;
  try {
    await setDoc(doc(db, 'checkoutDrafts', sessionId), payload, { merge: true });
  } catch (e) {
    /* A denied partial write usually means the server doc is gone
     * (deleted by the admin / count cap) while this browser still
     * thinks it exists — retry once with the full create shape. */
    if (!draftSync.serverCreated) throw e;
    draftSync.serverCreated = false;
    try {
      const full = draftPayload();
      await setDoc(doc(db, 'checkoutDrafts', sessionId), full, { merge: true });
      draftSync.serverCreated = true;
      try { localStorage.setItem('sp-draft-synced', '1'); } catch (_) {}
    } catch (_) { return; }
  }
  draftSync.lastSyncAtMs = Date.now();
  draftSync.savesUsed += 1;
  draftSync.lastSentJson = comparable;
  if (!draftSync.serverCreated) {
    draftSync.serverCreated = true;
    try { localStorage.setItem('sp-draft-synced', '1'); } catch (_) {}
  }
}
function scheduleDraftSync() {
  clearTimeout(draftSync.timer);
  draftSync.timer = setTimeout(() => { syncDraftToServer().catch(() => {}); }, 10000);
}
function onDraftFieldInput() {
  saveDraftLocal();
  scheduleDraftSync();
}
window.addEventListener('pagehide', () => { syncDraftToServer().catch(() => {}); });

/* ---------- incomplete orders: customer journey ---------- */
/* Every visitor is tracked, including anonymous ones. Events are
 * buffered in the browser and flushed at intent milestones (product
 * view, add to cart, checkout start) and best-effort on page hide;
 * a crash between flushes loses only the tail. Dwell is recorded in
 * bands only, and the visible timer runs only while the tab is
 * visible. The summary is capped at 20 product entries; the 21st
 * product is counted in overflowCount, never stored. GA4 events
 * fire from the same milestones, alongside — never instead. */
const journey = {
  entries: {}, order: [], startedAt: Date.now(),
  viewed: false, checkoutStarted: false,
  currentView: null, hiddenSince: null, serverCreated: false, orderId: null,
};
function journeyEntry(productId) {
  if (!journey.entries[productId]) {
    journey.entries[productId] = { productId, dwellMs: 0, actions: [] };
    journey.order.push(productId);
  }
  return journey.entries[productId];
}
function journeyAddAction(productId, action) {
  const e = journeyEntry(productId);
  if (!e.actions.includes(action)) e.actions.push(action);
  if (e.actions.length > 10) e.actions = e.actions.slice(0, 10);
}
function journeyEndView() {
  const v = journey.currentView;
  if (!v) return;
  const now = Date.now();
  const visibleMs = Math.max(0, now - v.start - (v.hiddenMs || 0));
  journeyEntry(v.productId).dwellMs += visibleMs;
  journey.currentView = null;
}
function journeyStartView(productId) {
  journeyEndView();
  journey.currentView = { productId, start: Date.now(), hiddenMs: 0 };
}
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    if (journey.currentView && journey.hiddenSince == null) journey.hiddenSince = Date.now();
  } else if (journey.hiddenSince != null) {
    if (journey.currentView) journey.currentView.hiddenMs += Date.now() - journey.hiddenSince;
    journey.hiddenSince = null;
  }
});
async function flushJourney() {
  if (quotaCutoff === 'journeys' || quotaCutoff === 'drafts') return;
  if (journey.order.length === 0 && !journey.checkoutStarted) return;
  journeyEndView();
  const kept = journey.order.slice(0, 20);
  const products = kept.map((id) => {
    const e = journey.entries[id];
    return { productId: id, dwellBand: dwellBand(Math.floor(e.dwellMs / 1000)), actions: e.actions.slice() };
  });
  const totalMs = Object.values(journey.entries).reduce((s, e) => s + (e.dwellMs || 0), 0);
  const payload = {
    sessionId,
    draftId: draftSync.serverCreated ? sessionId : null,
    orderId: journey.orderId,
    totalSecondsBand: dwellBand(Math.floor(totalMs / 1000)),
    products,
    overflowCount: Math.max(0, journey.order.length - 20),
    updatedAt: serverTimestamp(),
    schemaVersion: 1,
  };
  if (!journey.serverCreated) payload.startedAt = serverTimestamp();
  try {
    await setDoc(doc(db, 'journeySummaries', sessionId), payload, { merge: true });
    journey.serverCreated = true;
  } catch (_) { /* best-effort: a failed flush loses only the tail */ }
}
function journeyNoteView(productId) {
  journey.viewed = true;
  journeyAddAction(productId, 'view');
  journeyStartView(productId);
  gaEvent('view_item', { items: [{ id: productId }] });
  flushJourney().catch(() => {});
}
function journeyNoteAdd(productId) {
  journeyAddAction(productId, 'add_to_cart');
  gaEvent('add_to_cart', { items: [{ id: productId }] });
  flushJourney().catch(() => {});
}
function journeyNoteCheckoutStart() {
  journey.checkoutStarted = true;
  gaEvent('begin_checkout', {});
  flushJourney().catch(() => {});
}
window.addEventListener('pagehide', () => { flushJourney().catch(() => {}); });

/* ---------- incomplete orders: targeted exit feedback ---------- */
/* Desktop mouse-leave only, once per session, only when the visitor
 * showed real intent (item in cart, viewed a product, or started
 * checkout). Never blocks leaving; a failed write fails silently.
 * Phones get the footer link instead (no working mobile trigger). */
let exitFeedbackShown = false;
try { exitFeedbackShown = sessionStorage.getItem('sp-exit-shown') === '1'; } catch (_) {}
function maybeShowExitFeedback() {
  if (exitFeedbackShown) return;
  try {
    if (typeof matchMedia !== 'undefined' && matchMedia('(pointer: fine)').matches === false) return;
  } catch (_) {}
  const intent = Object.keys(cart).length > 0 || journey.viewed || journey.checkoutStarted;
  if (!intent) return;
  exitFeedbackShown = true;
  try { sessionStorage.setItem('sp-exit-shown', '1'); } catch (_) {}
  const overlay = document.createElement('div');
  overlay.className = 'exit-popup';
  overlay.innerHTML = `<div class="exit-popup-card" role="dialog" aria-label="ليه ماشي؟"><h3>قبل ما تمشي… ليه؟</h3><p>قولّنا إيه اللي معجبكش أو إيه اللي ناقص — ردك بيساعدنا نحسّن المتجر.</p><textarea id="exitFbMsg" rows="3" placeholder="اكتب ملاحظتك هنا"></textarea><p class="form-err" id="exitFbErr" hidden></p><div style="display:flex;gap:8px;margin-top:12px"><button class="btn btn-primary" id="exitFbSend" style="flex:1">إرسال</button><button class="btn btn-ghost" id="exitFbClose">إغلاق</button></div></div>`;
  document.body.appendChild(overlay);
  const close = () => overlay.remove();
  overlay.querySelector('#exitFbClose').addEventListener('click', close);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
  overlay.querySelector('#exitFbSend').addEventListener('click', async () => {
    const msg = (overlay.querySelector('#exitFbMsg').value || '').trim();
    if (msg.length < 10) {
      const err = overlay.querySelector('#exitFbErr');
      err.hidden = false;
      err.textContent = 'اكتب رسالتك (10 حروف على الأقل)';
      return;
    }
    try {
      await setDoc(doc(collection(db, 'feedback')), {
        name: '', email: '', phone: '', message: msg,
        source: 'exit-feedback', createdAt: serverTimestamp(),
      });
    } catch (_) { /* fails silently, never interrupts leaving */ }
    close();
  });
}
if (typeof document !== 'undefined' && document.documentElement) {
  document.documentElement.addEventListener('mouseleave', () => { maybeShowExitFeedback(); });
}

/* ---------- state ---------- */
let categories = [];
let products = [];
let homepage = {};
let design = {};
let searchQuery = '';
let filter = 'all';
/* Price filter (min/max, EGP) + sort by price. Null bounds mean "no
 * limit"; 'none' keeps the catalog's own order. */
let priceMin = null;
let priceMax = null;
let sortMode = 'none';
/* WhatsApp ordering (storeSettings/settings): off by default; the
 * number defaults to the store's WhatsApp line. */
let whatsappOrderEnabled = false;
let whatsappNumber = '201557887719';
let cart = JSON.parse(localStorage.getItem('sp-cart') || '{}');
let attemptId = null;
let clientOrderId = localStorage.getItem('sp-checkout') || null;
function newClientOrderId() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID();
  return 'o_' + Math.random().toString(36).slice(2) + Date.now().toString(36);
}
let ordering = false;
let theme = localStorage.getItem('sp-theme') || 'light';
/* Delivery fee (storeSettings/settings.deliveryFee, int >= 0).
 * null = the settings doc has NO fee field: missing means FREE
 * (fee-default-free, Mohamed's decision 2026-11-27) — the pricing
 * helper treats it as 0, exactly like an explicit fee of 0.
 * freeDeliveryThreshold is the D3 admin setting (see the
 * pricing-helper note); null = no waiver. Both ride the existing
 * boot settings read — no new reads. */
let deliveryFee = null;
let freeDeliveryThreshold = null;
/* The canonical pricing of the current cart, through the one helper:
 * cart lines + the fee state. */
function currentPricing() {
  return computePricing(
    cartLines().map((l) => ({ price: Number(l.p.price), basePrice: l.p.basePrice ?? null, qty: l.qty })),
    { deliveryFee, freeDeliveryThreshold });
}
/* True when the catalog load failed at boot — renderProducts shows an
 * error UI with a retry instead of an empty grid (the silent catches
 * used to swallow this with zero signal). */
let bootFailed = false;

/* ---------- active template: bundle loader (templates, shell 1.0.0) ----------
 * The storefront is a frozen trusted shell + a swappable template
 * skin. A template is a file BUNDLE on Firebase Hosting
 * (/templates/{id}/{version}/...), named by the Firestore pointer
 * (storeSettings/activeTemplate: templateId + bundleVersion +
 * bundleHash + previousTemplateId) and overridden only by
 * ?preview=<slug>. No template runs JavaScript, so no template can
 * read the cart, the checkout form, or customer contact data.
 * Load unit: the manifest carries the expected bundle hash; ANY
 * failed file (404, hash mismatch, timeout) fails the WHOLE bundle
 * to classic — a bundle never renders partially. 10-second total
 * timeout for manifest + all files. On ANY bundle failure the
 * bundled classic renders with 0 Firestore reads and a named
 * template_fallback event (reason + templateId) is recorded — never
 * a blank page, never a silent fallback.
 * Classic renders via the existing v1 path (applyTemplate with
 * classic tokens + the fixed-DOM renderers); the built-in
 * CLASSIC_TEMPLATE is the last-resort fallback only. */
let activeTemplateId = 'classic';
let activeTemplateVersion = '1.0.0';
let activeBundleFiles = null;
let bundleHeroActive = false; // a non-classic bundle's hero wins
let isPreviewMode = false;
let previewSlug = null;
let previewMotionOverride = 'full'; // preview-only toggle, default full
let bundleVerdicts = new Map(); // `${id}@${version}` -> gateway report (per session)
let saleWindowMissingLogged = false;
let serverTimeCaptured = false;
let templateSections = {};
let templateGrid = { columns: null, rows: null, minColumnWidthPx: 250 };
let gridExpanded = false;
const TEMPLATE_TOKEN_KEYS = new Set(['bg', 'bg2', 'surface', 'surfaceStrong', 'border', 'text', 'textSoft', 'accent', 'accent2', 'warm', 'radius']);
const TEMPLATE_SECTION_KEYS = new Set(['hero', 'promos', 'featured', 'delivery', 'contact']);
const TEMPLATE_CSS_VARS = { bg: '--bg', bg2: '--bg-2', surface: '--surface', surfaceStrong: '--surface-strong', border: '--border', text: '--text', textSoft: '--text-soft', accent: '--accent', accent2: '--accent-2', warm: '--warm', radius: '--radius' };
/* Built-in launch template (same values as templates/classic.json
 * and the admin app's classic definition): the current live site,
 * verbatim — tokens are styles.css :root, grid nulls reproduce the
 * current auto-fill behaviour exactly. */
const CLASSIC_TEMPLATE = {
  id: 'classic',
  name: 'التصميم الحالي',
  schemaVersion: 1,
  status: 'active',
  grid: { columns: null, rows: null, minColumnWidthPx: 250 },
  tokens: {
    bg: '#f4f6f8', bg2: '#eaeff3',
    surface: 'rgba(255, 255, 255, 0.55)',
    surfaceStrong: 'rgba(255, 255, 255, 0.82)',
    border: 'rgba(20, 30, 45, 0.08)',
    text: '#1b2430', textSoft: '#5b6878',
    accent: '#3f7f8c', accent2: '#8fb8b0', warm: '#c9a57a',
    radius: '24px',
  },
  sections: { hero: true, promos: true, featured: true, delivery: true, contact: true },
};

const $ = (s, el = document) => el.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = (n) => `${Number(n || 0).toLocaleString('ar-EG')} ج.م`;

/* ---------- canonical pricing (pricing-bundle Technical Plan §8) ----------
 * ONE helper implements every money rule; no inline arithmetic at
 * display sites and none inside placeOrderTx — the transaction MUST
 * call computePricing for all totals. All money is integer EGP.
 * - per-line saving = (basePrice - price) x qty, exact, never rounded.
 * - displayed % = round((basePrice - price) x 100 / basePrice), halves
 *   up; display-only, derived at render, never stored, never a total.
 * - % badge SUPPRESSED when the rounded % x base != the exact saving
 *   (e.g. base 199 -> 149: 25% x 199 = 49.75 != 50, so no badge, only
 *   "وفّر 50"). A customer multiplying a displayed % by the base must
 *   never find a 1 EGP discrepancy.
 * - Y = amountDue, Z = baseSubtotal + deliveryFee, X = saleSavings.
 *   cartTotal() is the products subtotal; the fee appears only in
 *   amountDue.
 * - Free-delivery threshold (decision D3): when the order's `total`
 *   reaches the admin setting, the fee is waived (effective fee 0,
 *   stored as deliveryFee 0). The spec names no settings field for
 *   the threshold; this build reads `storeSettings/settings
 *   .freeDeliveryThreshold` (int > 0; absent/null = no waiver).
 *   The admin apps must write that exact field, or the waiver never
 *   triggers — fail-closed, never a hardcoded threshold.
 */
/* PRICING-HELPER-BEGIN */
function roundHalfUp(x) { return Math.floor(x + 0.5); }
function isOnSale(p) {
  return !!p && p.basePrice != null && Number(p.basePrice) > Number(p.price);
}
/* Rounded display % for one product, or null when there is no sale
 * or when the badge must be suppressed (rounded % x base != saving). */
function salePercent(p) {
  if (!isOnSale(p)) return null;
  const base = Number(p.basePrice);
  const saving = base - Number(p.price);
  const pct = roundHalfUp((saving * 100) / base);
  if (pct * base !== saving * 100) return null;
  return pct;
}
/* Real max discount % across the loaded catalogue, or null when
 * nothing is on sale. The bazaar "up to X%" claim is filled from
 * this — never a hardcoded number. Rounded like every other
 * displayed % (roundHalfUp), but clamped down when the rounded
 * figure would exceed the true max ratio, so "up to X%" is always
 * reached by a real product; a sub-half-percent max is no claim
 * at all (null hides the line). */
function maxDiscountPct(list) {
  let best = null;
  for (const p of list || []) {
    if (!isOnSale(p)) continue;
    const base = Number(p.basePrice);
    const ratio = (base - Number(p.price)) / base;
    if (best == null || ratio > best) best = ratio;
  }
  if (best == null) return null;
  let pct = roundHalfUp(best * 100);
  if (pct / 100 > best) pct -= 1;
  if (pct <= 0) return null;
  return pct;
}
/* lines: [{ price, basePrice (int|null), qty }].
 * opts: { deliveryFee (int|null — null means the settings doc has
 *   no fee field: missing means FREE, treated as 0 — fee-default-free
 *   2026-11-27), freeDeliveryThreshold (int|null) }.
 * Returns every figure the storefront, review, transaction and
 * WhatsApp quote share — one computation, no divergent copies. */
function computePricing(lines, opts) {
  const o = opts || {};
  let baseSubtotal = 0;
  let subtotal = 0;
  let saleSavings = 0;
  const perLine = [];
  for (const l of lines || []) {
    const price = Number(l.price) || 0;
    const qty = Number(l.qty) || 0;
    const base = (l.basePrice != null && Number(l.basePrice) > price) ? Number(l.basePrice) : null;
    const lineSaving = base != null ? (base - price) * qty : 0;
    baseSubtotal += (base != null ? base : price) * qty;
    subtotal += price * qty;
    saleSavings += lineSaving;
    perLine.push({ saving: lineSaving, pct: base != null ? salePercent({ price, basePrice: base }) : null });
  }
  const total = subtotal;
  const feeUnset = !(Number.isInteger(o.deliveryFee) && o.deliveryFee >= 0);
  const threshold = (Number.isInteger(o.freeDeliveryThreshold) && o.freeDeliveryThreshold > 0)
    ? o.freeDeliveryThreshold : null;
  const feeWaived = !feeUnset && threshold != null && total >= threshold;
  // Missing fee = free (fee-default-free 2026-11-27): the effective
  // fee is 0, so amountDue / insteadOf are always numbers — never
  // null — and the fee line reads free, exactly as for fee 0.
  // feeUnset stays in the return as "the fee field was absent" for
  // display callers; it no longer blocks anything.
  const deliveryFee = feeUnset ? 0 : (feeWaived ? 0 : o.deliveryFee);
  const amountDue = total + deliveryFee;
  return {
    perLine,
    baseSubtotal,
    subtotal,
    saleSavings,
    total,
    deliveryFee,
    feeUnset,
    feeWaived,
    amountDue,
    savingTotal: saleSavings,
    insteadOf: baseSubtotal + deliveryFee,
  };
}
/* Fee line text. Browsing surfaces say "توصيل", the review modal
 * (the confirm-order step) says "شحن" — one term per screen, never
 * mixed. Fee 0 reads free; an unset fee (null) reads free too —
 * missing means free (fee-default-free 2026-11-27). */
function feeLineText(effectiveFee, screen) {
  if (effectiveFee == null || effectiveFee === 0) return screen === 'review' ? 'الشحن مجانًا' : 'التوصيل مجاني';
  return screen === 'review' ? `الشحن: ${money(effectiveFee)}` : `التوصيل: ${money(effectiveFee)}`;
}
/* PRICING-HELPER-END */
/* Sale display fragments shared by productCard / featuredCard /
 * openProduct / cart lines. No inline money math at the call sites. */
function salePriceHtml(p) {
  if (!isOnSale(p)) return `<span class="price">${money(p.price)}</span>`;
  const pct = salePercent(p);
  return `<span class="price sale"><span class="price-now">${money(p.price)}</span>`
    + `<s class="price-base">${money(p.basePrice)}</s>`
    + (pct !== null ? `<span class="pct-badge">${pct.toLocaleString('ar-EG')}٪</span>` : '')
    + `</span>`;
}
function saveLineHtml(p, qty) {
  if (!isOnSale(p)) return '';
  const saving = (Number(p.basePrice) - Number(p.price)) * (qty || 1);
  return `<div class="save-line">وفّر ${money(saving)}</div>`;
}

/* Cloudinary auto-optimization: every Cloudinary image is served with
 * f_auto,q_auto so the storefront loads fast. Pasted links pass through. */
function deliveryUrl(u) {
  if (!u || !u.includes('res.cloudinary.com') || u.includes('f_auto')) return u;
  return u.replace('/upload/', '/upload/f_auto,q_auto/');
}
function coverUrl(p) {
  const imgs = p.images || [];
  if (imgs.length > 0 && imgs[0].url) return deliveryUrl(imgs[0].url);
  if (p.imageUrl) return deliveryUrl(p.imageUrl);
  return '';
}
function productImages(p) {
  const imgs = (p.images || []).filter((i) => i && i.url).map((i) => deliveryUrl(i.url));
  if (imgs.length === 0 && p.imageUrl) imgs.push(deliveryUrl(p.imageUrl));
  return imgs;
}
function initialOf(name) { return (name || '?').trim().charAt(0); }
function catCount(id) { return products.filter((p) => p.categoryId === id).length; }
function sectionOn(key) {
  // The template's section toggles win; the design doc is the
  // fallback; default true.
  if (Object.prototype.hasOwnProperty.call(templateSections, key)) return templateSections[key] !== false;
  const s = (design && design.sections && typeof design.sections === 'object') ? design.sections : {};
  return s[key] !== false; // default true
}

/* Template validation gateway (client side — mirrors the admin
 * app's gateway in lib/services/templates_service.dart). A template
 * that fails any check is never applied. */
function _isSafeCssValue(key, value) {
  if (typeof value !== 'string') return false;
  const v = value.trim();
  if (!v) return false;
  if (v.includes('url(') || v.includes('expression') || v.includes('javascript:') ||
      v.includes(';') || v.includes('"') || v.includes("'") || v.includes('<') || v.includes('>')) return false;
  if (key === 'radius') {
    const m = /^(\d+)px$/.exec(v);
    if (!m) return false;
    const n = Number(m[1]);
    return n >= 0 && n <= 64;
  }
  if (/^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(v)) return true;
  const rgba = /^rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([0-9.]+)\s*\)$/.exec(v);
  if (rgba) {
    const r = Number(rgba[1]); const g = Number(rgba[2]); const b = Number(rgba[3]); const a = Number(rgba[4]);
    return r <= 255 && g <= 255 && b <= 255 && a >= 0 && a <= 1;
  }
  return false;
}
function validateTemplateBody(body) {
  const failed = [];
  if (!body || typeof body !== 'object') return { passed: false, failed: ['template'] };
  if (body.schemaVersion !== 1) failed.push('schemaVersion');
  const grid = body.grid || {};
  if (grid.columns != null && (!Number.isInteger(grid.columns) || grid.columns < 1 || grid.columns > 12)) failed.push('grid.columns');
  if (grid.rows != null && (!Number.isInteger(grid.rows) || grid.rows < 1 || grid.rows > 20)) failed.push('grid.rows');
  if (grid.minColumnWidthPx != null && (!Number.isInteger(grid.minColumnWidthPx) || grid.minColumnWidthPx < 120 || grid.minColumnWidthPx > 600)) failed.push('grid.minColumnWidthPx');
  const tokens = body.tokens || {};
  for (const [key, value] of Object.entries(tokens)) {
    if (!TEMPLATE_TOKEN_KEYS.has(key) || !_isSafeCssValue(key, value)) failed.push('tokens.' + key);
  }
  const sections = body.sections || {};
  for (const [key, value] of Object.entries(sections)) {
    if (!TEMPLATE_SECTION_KEYS.has(key) || typeof value !== 'boolean') failed.push('sections.' + key);
  }
  return { passed: failed.length === 0, failed };
}
async function loadClassicTemplateFile() {
  if (typeof fetch !== 'function') return null;
  try {
    const res = await fetch('templates/classic.json', { cache: 'no-store' });
    if (!res || !res.ok) return null;
    return await res.json();
  } catch (_) { return null; }
}
/* Fetch with a shared deadline: every bundle fetch (manifest +
 * sections + styles + tokens) shares ONE 10-second budget. */
function bundleFetch(url, controller) {
  return fetch(url, { signal: controller.signal, cache: 'default' });
}
async function fetchBundleFiles(templateId, version, manifest, controller) {
  const base = `templates/${templateId}/${version}/`;
  const files = {};
  const wanted = [];
  for (const s of (manifest.sections || [])) wanted.push('sections/' + s + '.html');
  wanted.push('styles.css', 'tokens.json');
  const texts = await Promise.all(wanted.map(async (rel) => {
    const res = await bundleFetch(base + rel, controller);
    if (!res || !res.ok) throw new Error('bundle_file_failed:' + rel + ':' + (res ? res.status : 'no-response'));
    return [rel, await res.text()];
  }));
  for (const [rel, text] of texts) files[rel] = text;
  return files;
}
/* Render the classic v1 path and stamp the session. Used for the
 * classic pointer AND for every bundle failure (0 Firestore reads
 * on the fallback path itself — classic.json is an HTTP asset). */
async function renderClassicFallback(reason, templateId) {
  activeBundleManifest = null;
  activeBundleFiles = null;
  bundleHeroActive = false;
  activeTemplateId = 'classic';
  activeTemplateVersion = '1.0.0';
  sessionTemplateId = 'classic';
  sessionTemplateVersion = '1.0.0';
  let body = await loadClassicTemplateFile();
  if (!body || !validateTemplateBody(body).passed) body = CLASSIC_TEMPLATE;
  applyTemplate(body);
  await writeSessionDoc();
  if (reason) {
    await recordTemplateEvent('template_fallback', { reason, failedTemplateId: templateId || null });
  }
  return 'classic';
}
/* Preview resolution: ?preview=<slug> overrides the live pointer.
 * 1 Firestore read, preview visits only (anonymous get only).
 * Revoked / unknown slug -> plain "preview closed" state with NO
 * store content. */
async function resolvePreviewSlug(slug) {
  try {
    const snap = await getDoc(doc(db, 'previews', slug));
    if (!snap.exists()) return { status: 'closed' };
    const d = snap.data() || {};
    if (d.status === 'revoked') return { status: 'closed' };
    if (typeof d.templateId !== 'string' || !d.templateId) return { status: 'closed' };
    return { status: 'open', templateId: d.templateId, version: (typeof d.version === 'string' && d.version) ? d.version : '1.0.0' };
  } catch (_) {
    return { status: 'closed' };
  }
}
function addNoindexMeta() {
  // Preview renders are never indexed.
  if (!document.querySelector('meta[name="robots"][content*="noindex"]')) {
    const meta = document.createElement('meta');
    meta.name = 'robots';
    meta.content = 'noindex';
    document.head.appendChild(meta);
  }
}
function showPreviewClosed() {
  document.body.classList.add('preview-closed');
  addNoindexMeta();
  const stamp = document.getElementById('previewStamp');
  if (stamp) {
    stamp.hidden = false;
    stamp.innerHTML = '<strong>المعاينة مغلقة</strong><span>انتهت صلاحية رابط المعاينة ده.</span>';
  }
  sessionTemplateId = 'preview-closed';
  sessionTemplateVersion = '1.0.0';
  writeSessionDoc();
}
function showPreviewStamp(templateId, version) {
  const stamp = document.getElementById('previewStamp');
  if (!stamp) return;
  stamp.hidden = false;
  stamp.innerHTML = `<strong>معاينة</strong><span>قالب ${esc(templateId)} — نسخة للمراجعة فقط، مفيش طلبات هتتنشاء هنا.</span>`
    + `<span class="preview-motion"><button type="button" data-motion="full" class="${previewMotionOverride === 'full' ? 'on' : ''}">حركة كاملة</button>`
    + `<button type="button" data-motion="calm" class="${previewMotionOverride === 'calm' ? 'on' : ''}">حركة هادية</button></span>`;
  stamp.querySelectorAll('[data-motion]').forEach((b) => b.addEventListener('click', () => {
    previewMotionOverride = b.dataset.motion;
    document.documentElement.dataset.previewMotion = previewMotionOverride;
    applyMotionProfile('preview_override:' + previewMotionOverride);
    recordTemplateEvent('template_preview_motion', { motion: previewMotionOverride });
    showPreviewStamp(templateId, version);
  }));
  // Preview renders are never indexed.
  addNoindexMeta();
}
/* Motion profile: lively downgrades to calm when the device reports
 * prefers-reduced-motion, when the first bundle render exceeds
 * 2.5s, or when the watchdog fires render_blank_detected. The
 * downgrade is recorded with a motion_downgraded event. */
function applyMotionProfile(reason) {
  const motion = (activeBundleManifest && activeBundleManifest.motion) || 'calm';
  const reduced = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
  const overrideCalm = isPreviewMode && previewMotionOverride === 'calm';
  const downgrade = motion === 'lively' && (reduced || overrideCalm);
  const effective = downgrade ? 'calm' : motion;
  document.documentElement.dataset.motion = effective;
  if (downgrade && reason) {
    recordTemplateEvent('motion_downgraded', { reason, from: 'lively', to: 'calm' });
  }
  return effective;
}
function maybeDowngradeMotion(reason) {
  if (!activeBundleManifest || activeBundleManifest.motion !== 'lively') return;
  if (document.documentElement.dataset.motion === 'calm') return;
  document.documentElement.dataset.motion = 'calm';
  recordTemplateEvent('motion_downgraded', { reason, from: 'lively', to: 'calm' });
}
async function loadActiveTemplate() {
  const loadStartedAt = Date.now();
  const gateway = (typeof window !== 'undefined') ? window.BundleGateway : null;
  try {
    // Preview override first: ?preview=<slug>.
    const params = new URLSearchParams(window.location.search);
    const slug = params.get('preview');
    let pointer = null;
    let preview = null;
    if (slug) {
      isPreviewMode = true;
      previewSlug = slug;
      preview = await resolvePreviewSlug(slug);
      if (preview.status !== 'open') {
        showPreviewClosed();
        return 'preview-closed';
      }
    }
    // Pointer (tolerant read — missing bundleVersion/bundleHash
    // means "classic, version 1", not a failure).
    const ptrSnap = await getDoc(doc(db, 'storeSettings', 'activeTemplate'));
    pointer = ptrSnap.exists() ? (ptrSnap.data() || {}) : {};
    let resolved;
    if (preview) {
      resolved = { templateId: preview.templateId, version: preview.version, bundleHash: null, previousTemplateId: null, isLegacy: false };
    } else if (gateway) {
      resolved = gateway.resolvePointer(pointer);
    } else {
      resolved = { templateId: (pointer.templateId || 'classic'), version: '1.0.0', bundleHash: pointer.bundleHash || null, previousTemplateId: pointer.previousTemplateId || null, isLegacy: true };
    }
    // Registry document: the expected bundle hash (read at boot —
    // one of the 5 boot reads). A missing registry doc for a
    // non-classic pointer fails the bundle to classic.
    let expectedHash = resolved.bundleHash;
    if (resolved.templateId !== 'classic') {
      try {
        const regSnap = await getDoc(doc(db, 'templates', resolved.templateId));
        if (regSnap.exists() && regSnap.data() && typeof regSnap.data().bundleHash === 'string') {
          expectedHash = regSnap.data().bundleHash;
        } else if (!expectedHash) {
          return renderClassicFallback('registry_missing', resolved.templateId);
        }
      } catch (_) {
        if (!expectedHash) return renderClassicFallback('registry_read_failed', resolved.templateId);
      }
    }
    // Classic: the existing v1 path (applyTemplate + fixed-DOM
    // renderers). No bundle fetch, no gateway run.
    if (resolved.templateId === 'classic') {
      activeTemplateId = 'classic';
      activeTemplateVersion = '1.0.0';
      sessionTemplateId = 'classic';
      sessionTemplateVersion = '1.0.0';
      let body = await loadClassicTemplateFile();
      if (!body || !validateTemplateBody(body).passed) body = CLASSIC_TEMPLATE;
      applyTemplate(body);
      // template_loaded is stamped ON the session doc (same write),
      // not a separate document — 1 write per visit, as budgeted.
      await writeSessionDoc({ templateLoadedAt: serverTimestamp() });
      countTelemetry('event_template_loaded', 1);
      return 'classic';
    }
    // Bundle path: fetch manifest + files under one 10s deadline.
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), 10000);
    let manifestText = '';
    let manifest = null;
    let files = null;
    try {
      const res = await bundleFetch(`templates/${resolved.templateId}/${resolved.version}/manifest.json`, controller);
      if (!res || !res.ok) throw new Error('bundle_manifest_failed:' + (res ? res.status : 'no-response'));
      manifestText = await res.text();
      manifest = JSON.parse(manifestText);
      files = await fetchBundleFiles(resolved.templateId, resolved.version, manifest, controller);
    } catch (e) {
      clearTimeout(deadline);
      const reason = (e && e.name === 'AbortError') ? 'bundle_timeout' : ((e && e.message) || 'bundle_fetch_failed');
      return renderClassicFallback(reason, resolved.templateId);
    }
    clearTimeout(deadline);
    files['manifest.json'] = manifestText;
    // Fast structural check (gateway). Verdict cached in memory per
    // bundle version per session.
    const verdictKey = resolved.templateId + '@' + resolved.version;
    let report = bundleVerdicts.get(verdictKey);
    if (!report) {
      if (!gateway) {
        return renderClassicFallback('gateway_unavailable', resolved.templateId);
      }
      report = await gateway.validateBundle(files, manifest, {
        pointerTemplateId: resolved.templateId,
        pointerVersion: resolved.version,
        expectedHash,
        shellVersion: SHELL_VERSION,
      });
      bundleVerdicts.set(verdictKey, report);
    }
    if (!report.passed) {
      return renderClassicFallback('gateway_failed:' + (report.failed[0] || 'unknown'), resolved.templateId);
    }
    // Success: stamp the session FIRST (templateId at creation),
    // then inject.
    activeTemplateId = resolved.templateId;
    activeTemplateVersion = resolved.version;
    activeBundleManifest = manifest;
    activeBundleFiles = files;
    bundleHeroActive = true;
    sessionTemplateId = resolved.templateId;
    sessionTemplateVersion = resolved.version;
    await writeSessionDoc({ templateLoadedAt: serverTimestamp() });
    countTelemetry('event_template_loaded', 1);
    if (isPreviewMode) {
      showPreviewStamp(resolved.templateId, resolved.version);
      await recordTemplateEvent('template_preview_opened', { templateId: resolved.templateId, version: resolved.version });
    }
    injectBundle(manifest, files);
    const firstRenderMs = Date.now() - loadStartedAt;
    if (firstRenderMs > 2500) maybeDowngradeMotion('first_render_slow:' + firstRenderMs + 'ms');
    applyMotionProfile();
    return 'bundle';
  } catch (e) {
    return renderClassicFallback('loader_error:' + ((e && e.message) || 'unknown'), null);
  }
}
function applyTemplate(body) {
  const tokens = (body && body.tokens && typeof body.tokens === 'object') ? body.tokens : {};
  const root = document.documentElement;
  for (const [key, cssVar] of Object.entries(TEMPLATE_CSS_VARS)) {
    const v = tokens[key];
    if (typeof v === 'string' && v.trim() && _isSafeCssValue(key, v)) {
      root.style.setProperty(cssVar, v.trim());
    }
  }
  templateSections = (body && body.sections && typeof body.sections === 'object') ? body.sections : {};
  const grid = (body && body.grid && typeof body.grid === 'object') ? body.grid : {};
  templateGrid = {
    columns: (Number.isInteger(grid.columns) && grid.columns >= 1 && grid.columns <= 12) ? grid.columns : null,
    rows: (Number.isInteger(grid.rows) && grid.rows >= 1 && grid.rows <= 20) ? grid.rows : null,
    minColumnWidthPx: (Number.isInteger(grid.minColumnWidthPx) && grid.minColumnWidthPx >= 120 && grid.minColumnWidthPx <= 600) ? grid.minColumnWidthPx : 250,
  };
  gridExpanded = false;
  activeTemplateId = (body && typeof body.id === 'string' && body.id) || 'classic';
  activeTemplateVersion = '1.0.0';
  activeBundleManifest = null;
  activeBundleFiles = null;
  bundleHeroActive = false;
  document.body.classList.remove('bundle-header');
}

/* ---------- bundle injection: slot contract ONLY ----------------
 * A bundle supplies markup templates; the shell supplies live data
 * and behaviour. The ONLY interface is the slot/action vocabulary
 * in gateway-rules.json. No renderer queries bundle markup by id.
 * The shell topbar (brand / search / theme / cart) stays: it is
 * shell-owned chrome, and the bundle's header section (a hero
 * section whose first element carries data-section="header")
 * renders inside the hero mount as the template's header band.
 * The feedback form is shell-owned too: if a bundle contact
 * section carries no form, the live form is re-attached after
 * injection so the complaint surface never disappears. */
const TOKEN_CSS_VARS = { bg: '--bg', bg2: '--bg-2', surface: '--surface', surfaceStrong: '--surface-strong', border: '--border', text: '--text', textSoft: '--text-soft', accent: '--accent', accent2: '--accent-2', warm: '--warm', radius: '--radius', font: '--font' };
function applyBundleTokens(tokensJson) {
  let tokens = null;
  try { tokens = JSON.parse(tokensJson); } catch (_) { return; }
  if (!tokens || typeof tokens !== 'object') return;
  const root = document.documentElement;
  const applySet = (set) => {
    if (!set || typeof set !== 'object') return;
    for (const [key, cssVar] of Object.entries(TOKEN_CSS_VARS)) {
      const v = set[key];
      if (typeof v !== 'string' || !v.trim()) continue;
      if (key === 'font') {
        // Font stack: plain family list, no url()/script content.
        if (!/[<>;]/.test(v) && !/url\(|javascript:/i.test(v)) root.style.setProperty(cssVar, v.trim());
      } else if (_isSafeCssValue(key, v)) {
        root.style.setProperty(cssVar, v.trim());
      }
    }
  };
  applySet(tokens.light);
  // Dark tokens live under [data-theme="dark"] so the toggle keeps
  // working for variant templates; light-only hides the toggle.
  if (tokens.dark && typeof tokens.dark === 'object') {
    let style = document.getElementById('bundleTokensDark');
    if (!style) {
      style = document.createElement('style');
      style.id = 'bundleTokensDark';
      document.head.appendChild(style);
    }
    const decls = Object.entries(TOKEN_CSS_VARS)
      .filter(([key]) => typeof tokens.dark[key] === 'string' && tokens.dark[key].trim())
      .map(([key, cssVar]) => `${cssVar}: ${tokens.dark[key].trim()};`).join(' ');
    style.textContent = `[data-theme="dark"] { ${decls} }`;
  }
  if (activeBundleManifest && activeBundleManifest.dark === 'light-only') {
    const toggle = document.getElementById('themeToggle');
    if (toggle) toggle.style.display = 'none';
  }
}
function mountEl(name) { return document.querySelector(`[data-mount="${name}"]`); }
function injectBundle(manifest, files) {
  // Bundle CSS (scoped to browsing surfaces by the gateway's
  // forbidden-selector check) + tokens for transactional surfaces.
  let style = document.getElementById('bundleStyles');
  if (!style) {
    style = document.createElement('style');
    style.id = 'bundleStyles';
    document.head.appendChild(style);
  }
  style.textContent = files['styles.css'] || '';
  if (files['tokens.json']) applyBundleTokens(files['tokens.json']);
  // Cart / modal layout variants (shell-owned, picked by manifest).
  document.body.dataset.cartLayout = (manifest.cartLayout === 'bottom-sheet') ? 'bottom-sheet' : 'drawer';
  document.body.dataset.modalLayout = (manifest.modalLayout === 'sheet') ? 'sheet' : 'default';
  // Keep the feedback form: stash it before the contact mount is
  // replaced, re-attach it after injection if the bundle has none.
  const fbCard = document.querySelector('#contact .contact-card');
  const fbFormNode = fbCard ? fbCard.cloneNode(true) : null;
  for (const name of (manifest.sections || [])) {
    const mount = mountEl(name);
    if (!mount) continue;
    // Preserve nested mounts: the products mount lives inside the
    // featured section in the shell DOM. Detach nested mounts before
    // replacing innerHTML, then re-append them (order-independent:
    // works whether featured or products is injected first).
    const nested = [...mount.querySelectorAll('[data-mount]')].filter((el) => el !== mount);
    nested.forEach((el) => el.remove());
    mount.innerHTML = files['sections/' + name + '.html'] || '';
    nested.forEach((el) => mount.appendChild(el));
    mount.hidden = false;
    mount.style.display = '';
  }
  // Sections the manifest does NOT list stay hidden.
  for (const name of ['hero', 'marquee', 'categories', 'featured', 'offers', 'products', 'delivery', 'contact', 'about']) {
    if (!(manifest.sections || []).includes(name)) {
      const mount = mountEl(name);
      if (mount) mount.style.display = 'none';
    }
  }
  if (fbFormNode) {
    const contact = mountEl('contact');
    if (contact && !contact.querySelector('#fbForm')) contact.appendChild(fbFormNode);
  }
  // Bundle header yields the shell topbar: when the bundle's hero
  // carries a data-section="header" WITH its own cart entry
  // (data-action="open-cart"), the shell topbar's nav row hides so
  // the visitor does not see two headers. The cart stays reachable
  // (the bundle header opens it); the search bar stays reachable
  // through the bundle's search action. If the bundle header has NO
  // cart entry, the shell topbar stays — the cart must always be
  // openable (D1-5). Known gap: the theme toggle lives in the shell
  // topbar, so dark-variant templates lose it when their header
  // yields the bar — flagged to the coordinator (bundle headers
  // need a theme hook, or the shell keeps a floating toggle).
  const bundleHeader = mountEl('hero') ? mountEl('hero').querySelector('[data-section="header"]') : null;
  const bundleHasCart = !!(bundleHeader && bundleHeader.querySelector('[data-action="open-cart"]'));
  document.body.classList.toggle('bundle-header', !!bundleHeader && bundleHasCart);
  fillBundleSlots();
  renderBundleProducts();
  bindBundleBehaviours(manifest);
  observeReveals();
  checkRenderBlank();
}
/* Repeat unit for a slot template: the slot element itself when it
 * is a card-like element, else its closest ancestor that is still a
 * single-child chain inside the mount. */
function repeatUnit(el, mount) {
  let node = el;
  while (node.parentElement && node.parentElement !== mount
    && node.parentElement.children.length === 1) {
    node = node.parentElement;
  }
  return node;
}
function fillSlotText(scope, slot, text) {
  scope.querySelectorAll(`[data-slot="${slot}"]`).forEach((el) => {
    if (el.tagName === 'IMG') return;
    el.textContent = text;
  });
}
function fillSlotImage(scope, slot, url, alt) {
  scope.querySelectorAll(`[data-slot="${slot}"]`).forEach((el) => {
    if (!url) {
      // No image: hide the slot instead of setting an empty src
      // (an <img src=""> fires an error event and shows a broken
      // icon). The card still renders with name + price.
      if (el.tagName === 'IMG') el.style.display = 'none';
      return;
    }
    if (el.tagName === 'IMG') { el.src = url; if (alt) el.alt = alt; }
    else el.style.backgroundImage = `url("${url}")`;
  });
}
function fillProductInto(scope, p) {
  fillSlotText(scope, 'product-name', p.name || '');
  const priceEl = scope.querySelector('[data-slot="product-price"]');
  if (priceEl) priceEl.innerHTML = salePriceHtml(p);
  const oldEl = scope.querySelector('[data-slot="product-old-price"]');
  if (oldEl) {
    if (isOnSale(p)) oldEl.textContent = money(p.basePrice);
    // 2026-11-27 (price-row fix): hide ONLY the old-price element.
    // Hiding oldEl.parentElement hid the whole .bz-price-row div,
    // which also holds the [data-slot="product-price"] span — so a
    // non-sale product showed NO price in every bundle template's
    // cards (classic is unaffected: its own renderers). The price
    // span is filled by salePriceHtml above and must stay visible.
    else oldEl.style.display = 'none';
  }
  fillSlotImage(scope, 'product-image', coverUrl(p), p.name || '');
  // Honesty: a sale badge on a full-price product is an invented
  // claim. When the product is NOT on sale, hide badge-like
  // descendants: a class token that IS off/pct/discount/badge or
  // ends in -off/-pct/-discount/-badge (e.g. bz-off). Bundles must
  // not use those tokens on non-sale elements.
  if (!isOnSale(p)) {
    scope.querySelectorAll('*').forEach((el) => {
      const tokens = (el.className && typeof el.className === 'string') ? el.className.split(/\s+/) : [];
      const isBadge = tokens.some((t) => ['off', 'pct', 'discount', 'badge'].includes(t)
        || t.endsWith('-off') || t.endsWith('-pct') || t.endsWith('-discount') || t.endsWith('-badge')
        || t.endsWith('_off') || t.endsWith('_pct') || t.endsWith('_discount') || t.endsWith('_badge'));
      if (isBadge) el.style.display = 'none';
    });
  }
  scope.querySelectorAll('[data-action="add-to-cart"], [data-action="open-product"], [data-action="toggle-compare"]').forEach((el) => {
    el.dataset.productId = p.id;
  });
}
function fillBundleSlots() {
  const brandName = window.__brandName || 'المتجر';
  const brandTag = window.__brandTag || 'تسوق';
  document.querySelectorAll('[data-slot="brand-name"]').forEach((el) => { el.textContent = brandName; });
  document.querySelectorAll('[data-slot="brand-tagline"]').forEach((el) => { el.textContent = brandTag; });
  document.querySelectorAll('[data-slot="whatsapp-number"]').forEach((el) => { el.textContent = whatsappNumber || ''; });
  // COD line (pinned source): this is the same line the classic/v1
  // template renders — byte-identical to the og:description in
  // storefront/index.html ("الدفع عند الاستلام — ادفع لما طلبك
  // يوصلك"). There is no settings field for it; every bundle's
  // cod-message slot is filled from this one shell line.
  document.querySelectorAll('[data-slot="cod-message"]').forEach((el) => { el.textContent = 'الدفع عند الاستلام — ادفع لما طلبك يوصلك'; });
  const logoUrl = window.__logoImageUrl;
  if (logoUrl) document.querySelectorAll('[data-slot="brand-logo"]').forEach((el) => {
    if (el.tagName === 'IMG') el.src = deliveryUrl(logoUrl);
  });
  else document.querySelectorAll('[data-slot="brand-logo"]').forEach((el) => {
    // No logo configured: hide the slot instead of an empty box.
    if (el.tagName === 'IMG') el.style.display = 'none';
  });
  // Delivery fee slot (Scroll trust card): fee 0 -> "التوصيل مجاني";
  // a missing fee field reads free too (fee-default-free).
  document.querySelectorAll('[data-slot="delivery-fee"]').forEach((el) => {
    el.textContent = feeLineText(deliveryFee, 'browse');
  });
  // Max-discount claim (Bazaar): the real max sale % from the
  // loaded catalogue — never a hardcoded number. No sale product
  // hides the containing line entirely (same hide-when-absent rule
  // as the other slots); a sale re-shows it, so the pre-catalog
  // hide at injection is undone by the re-fill after load.
  const maxPct = maxDiscountPct(products);
  document.querySelectorAll('[data-slot="max-discount-pct"]').forEach((el) => {
    const line = el.parentElement;
    if (maxPct == null) {
      if (line) line.style.display = 'none';
      return;
    }
    el.textContent = maxPct + '%';
    if (line) line.style.display = '';
  });
  // Categories: repeat the category-name unit per category. An
  // empty list leaves the template in place (injection runs before
  // the catalog loads; renderBundleData fills it afterwards).
  const catMount = mountEl('categories');
  if (catMount && categories.length > 0) {
    const nameEl = catMount.querySelector('[data-slot="category-name"]');
    if (nameEl) {
      const unit = repeatUnit(nameEl, catMount);
      const parent = unit.parentElement;
      parent.innerHTML = '';
      for (const c of categories) {
        const clone = unit.cloneNode(true);
        fillSlotText(clone, 'category-name', c.name || '');
        fillSlotImage(clone, 'category-image', '', c.name || '');
        clone.querySelectorAll('[data-action="select-category"]').forEach((el) => { el.dataset.category = c.id; });
        clone.dataset.category = c.id;
        parent.appendChild(clone);
      }
    }
  }
  // Featured spot: repeat per featured product (first 3 max).
  const featMount = mountEl('featured');
  if (featMount && products.length > 0) {
    const spotEl = featMount.querySelector('[data-slot="featured-spot"]');
    if (spotEl) {
      const unit = repeatUnit(spotEl, featMount);
      const parent = unit.parentElement;
      const featured = products.filter((x) => x.featured === true).slice(0, 3);
      const list = featured.length > 0 ? featured : products.slice(0, 1);
      parent.innerHTML = '';
      for (const p of list) {
        const clone = unit.cloneNode(true);
        fillProductInto(clone, p);
        clone.dataset.productId = p.id;
        parent.appendChild(clone);
      }
    }
  }
  // Promo banners: repeat the promo-banner unit per banner.
  const offersMount = mountEl('offers');
  if (offersMount) {
    const bannerEl = offersMount.querySelector('[data-slot="promo-banner"]');
    const hp0 = homepage || {};
    const banners0 = Array.isArray(hp0.promoBanners)
      ? hp0.promoBanners.filter((b) => b && (b.title || b.imageUrl)) : [];
    if (bannerEl && banners0.length > 0) {
      const unit = repeatUnit(bannerEl, offersMount);
      const parent = unit.parentElement;
      const hp = homepage || {};
      const banners = Array.isArray(hp.promoBanners)
        ? hp.promoBanners.filter((b) => b && (b.title || b.imageUrl)) : [];
      parent.innerHTML = '';
      for (const b of banners) {
        const clone = unit.cloneNode(true);
        fillSlotText(clone, 'promo-banner', b.title || '');
        parent.appendChild(clone);
      }
    }
  }
  // Deal rails / any non-products mount carrying a product-card
  // template: repeat it per deal product (on-sale first, cap 8).
  // An EMPTY product-card slot is filled with a clone of the
  // products section's card template; a slot WITH inner slots is
  // filled in place. Idempotent across re-renders: previous clones
  // are removed, the template node is kept and hidden.
  fillRailCards();
}
/* Repeat product-card templates outside the products mount (deal
 * rails, etc.). See fillBundleSlots for the contract. */
function fillRailCards() {
  if (products.length === 0) return;
  const dealProducts = [...products.filter(isOnSale), ...products.filter((p) => !isOnSale(p))].slice(0, 8);
  const productsMount = mountEl('products');
  const productsTpl = productsMount ? productsMount.querySelector('[data-slot="product-card"]') : null;
  for (const name of ['hero', 'marquee', 'categories', 'featured', 'offers', 'delivery', 'contact', 'about']) {
    const mount = mountEl(name);
    if (!mount) continue;
    const cardTpl = mount.querySelector('[data-slot="product-card"]');
    if (!cardTpl) continue;
    if (cardTpl.closest('[data-slot="featured-spot"]')) continue; // handled by the spot repeat
    const templateNode = cardTpl.closest('[data-bundle-card-tpl]') || cardTpl;
    if (!templateNode.hasAttribute('data-bundle-card-tpl')) {
      templateNode.setAttribute('data-bundle-card-tpl', '');
      templateNode.style.display = 'none';
    }
    mount.querySelectorAll('[data-bundle-card]').forEach((el) => el.remove());
    const parent = templateNode.parentElement;
    for (const p of dealProducts) {
      const clone = templateNode.cloneNode(true);
      clone.removeAttribute('data-bundle-card-tpl');
      clone.style.display = '';
      clone.setAttribute('data-bundle-card', '');
      clone.dataset.productId = p.id;
      clone.dataset.id = p.id;
      if (clone.querySelector('[data-slot="product-name"], [data-slot="product-price"], [data-slot="product-image"]')) {
        fillProductInto(clone, p);
      } else if (productsTpl) {
        const inner = productsTpl.cloneNode(true);
        inner.removeAttribute('data-bundle-card-tpl');
        inner.style.display = '';
        fillProductInto(inner, p);
        clone.appendChild(inner);
      } else {
        const wrap = document.createElement('div');
        wrap.innerHTML = productCard(p);
        const card = wrap.firstElementChild;
        if (card) clone.appendChild(card);
      }
      parent.appendChild(clone);
    }
  }
}
/* Bundle products render (slot contract only). When the products
 * section carries a product-card template it is cloned per visible
 * product; otherwise the shell's productCard() fills a grid inside
 * the mount. Feed mode: snap layout, cap 12 + "show more", trust
 * card every 4 products, pulsing buy button. */
let feedExpanded = false;
const compareSet = new Set();
function renderBundleProducts() {
  const mount = mountEl('products');
  if (!mount) return;
  const isFeed = !!(activeBundleManifest && Array.isArray(activeBundleManifest.behaviours)
    && activeBundleManifest.behaviours.includes('feed'));
  mount.classList.toggle('feed-mode', isFeed);
  const list = visibleProducts();
  const cardTpl = mount.querySelector('[data-slot="product-card"]');
  // A previous render's clones are removed; the template node itself
  // is kept (marked) so re-renders can clone it again.
  let templateNode = null;
  if (cardTpl) {
    templateNode = cardTpl.closest('[data-bundle-card-tpl]') || cardTpl;
    if (!templateNode.hasAttribute('data-bundle-card-tpl')) {
      templateNode.setAttribute('data-bundle-card-tpl', '');
      templateNode.style.display = 'none';
    }
  }
  mount.querySelectorAll('[data-bundle-card]').forEach((el) => el.remove());
  let shown = list;
  let capped = 0;
  if (isFeed && !feedExpanded && list.length > 12) {
    shown = list.slice(0, 12);
    capped = list.length - 12;
  }
  const frag = document.createDocumentFragment();
  shown.forEach((p, i) => {
    let card;
    if (templateNode) {
      card = templateNode.cloneNode(true);
      card.removeAttribute('data-bundle-card-tpl');
      card.style.display = '';
      card.setAttribute('data-bundle-card', '');
      card.dataset.productId = p.id;
      card.dataset.id = p.id;
      fillProductInto(card, p);
      if (isFeed) card.querySelectorAll('[data-action="add-to-cart"]').forEach((b) => b.classList.add('pulse-buy'));
    } else {
      const wrap = document.createElement('div');
      wrap.innerHTML = productCard(p);
      card = wrap.firstElementChild;
      card.setAttribute('data-bundle-card', '');
      if (isFeed) card.querySelectorAll('[data-add]').forEach((b) => b.classList.add('pulse-buy'));
    }
    frag.appendChild(card);
    // Trust-moment card every 4 products (shell-inserted, real fee);
    // a missing fee reads free (fee-default-free).
    if (isFeed && (i + 1) % 4 === 0) {
      const trust = document.createElement('div');
      trust.className = 'trust-card';
      trust.setAttribute('data-trust-card', '');
      trust.innerHTML = `<strong>${deliveryFee == null || deliveryFee === 0 ? 'التوصيل مجاني' : 'التوصيل: ' + esc(money(deliveryFee))}</strong><span>الدفع عند الاستلام</span>`;
      frag.appendChild(trust);
    }
  });
  // Keep the template node in place; append cards after it.
  if (templateNode && templateNode.parentElement === mount) mount.appendChild(frag);
  else if (templateNode) { templateNode.parentElement.appendChild(frag); }
  else mount.appendChild(frag);
  let more = mount.querySelector('[data-feed-more]');
  if (more) more.remove();
  if (capped > 0) {
    more = document.createElement('button');
    more.className = 'btn btn-ghost';
    more.setAttribute('data-feed-more', '');
    more.textContent = `عرض المزيد (${capped} منتج)`;
    more.addEventListener('click', () => { feedExpanded = true; renderBundleProducts(); });
    mount.appendChild(more);
  } else if (isFeed && feedExpanded) {
    more = document.createElement('button');
    more.className = 'btn btn-ghost';
    more.setAttribute('data-feed-more', '');
    more.textContent = 'عرض أقل';
    more.addEventListener('click', () => { feedExpanded = false; renderBundleProducts(); });
    mount.appendChild(more);
  }
  renderComparisonStrip();
  observeReveals();
}
/* Comparison strip (Spec Lab): selected products side by side. */
function renderComparisonStrip() {
  const strip = document.querySelector('[data-compare-strip]');
  if (!strip) return;
  const selected = [...compareSet].map((id) => products.find((p) => p.id === id)).filter(Boolean);
  if (selected.length === 0) { strip.innerHTML = ''; strip.style.display = 'none'; return; }
  strip.style.display = '';
  strip.innerHTML = selected.map((p) => `
    <div class="compare-card" data-product-id="${p.id}">
      <strong>${esc(p.name)}</strong>
      <span>${money(p.price)}</span>
      ${p.description ? `<small>${esc(p.description)}</small>` : ''}
      <button class="btn btn-ghost" data-action="toggle-compare" data-product-id="${p.id}">إزالة</button>
    </div>`).join('');
}
/* Whitelisted behaviours, implemented ONCE in the shell and enabled
 * by manifest naming. Composed from primitives where possible:
 * timer (countdown), scroll-snap container (feed), Intersection-
 * Observer reveal (shared), class-toggle (grid/list, compare). */
let countdownTimer = null;
let countdownExpired = false;
function startCountdownStrip() {
  if (countdownTimer) { clearInterval(countdownTimer); countdownTimer = null; }
  // The shell OWNS the strip: when the manifest enables
  // countdown-strip but no section carries the marker, the shell
  // creates the strip at the top of the offers mount (else hero).
  // A bundle that carries its own marker gets it ticked in place.
  let strip = document.querySelector('[data-behaviour="countdown-strip"]');
  if (!strip) {
    const host = mountEl('offers') || mountEl('hero');
    if (!host) return;
    strip = document.createElement('div');
    strip.setAttribute('data-behaviour', 'countdown-strip');
    strip.innerHTML = '<span data-countdown-text></span>';
    host.prepend(strip);
  }
  if (countdownExpired) { strip.style.display = 'none'; return; }
  const hp = homepage || {};
  const banners = Array.isArray(hp.promoBanners) ? hp.promoBanners : [];
  const banner = banners.find((b) => b && b.endDate);
  if (!banner) {
    // No real sale window: no countdown, ever. Logged once/session.
    strip.style.display = 'none';
    if (!saleWindowMissingLogged) {
      saleWindowMissingLogged = true;
      recordTemplateEvent('sale_window_missing', { templateId: activeTemplateId });
    }
    return;
  }
  const endMs = Date.parse(banner.endDate);
  if (!Number.isFinite(endMs)) {
    strip.style.display = 'none';
    return;
  }
  const tick = () => {
    // Pinned to serverTimestamp-derived time captured at boot —
    // NEVER the device clock alone.
    const nowMs = Date.now() + serverTimeOffsetMs;
    const left = endMs - nowMs;
    if (left <= 0) {
      clearInterval(countdownTimer);
      countdownTimer = null;
      strip.style.display = 'none';
      if (!countdownExpired) {
        countdownExpired = true;
        recordTemplateEvent('sale_window_expired', { templateId: activeTemplateId });
      }
      return;
    }
    const d = Math.floor(left / 86400000);
    const h = Math.floor((left % 86400000) / 3600000);
    const m = Math.floor((left % 3600000) / 60000);
    const s = Math.floor((left % 60000) / 1000);
    const text = (d > 0 ? d + ' يوم ' : '') + String(h).padStart(2, '0') + ':' + String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
    const target = strip.querySelector('[data-countdown-text]') || strip;
    if (target === strip) {
      const span = strip.querySelector('.countdown-text');
      if (span) span.textContent = text; else strip.dataset.countdownText = text;
    } else target.textContent = text;
    countTelemetry('countdown_tick', 1);
  };
  strip.style.display = '';
  tick();
  countdownTimer = setInterval(tick, 1000);
}
let crossfadeTimer = null;
function startHeroCrossfade() {
  if (crossfadeTimer) { clearInterval(crossfadeTimer); crossfadeTimer = null; }
  const hero = document.querySelector('[data-behaviour="hero-crossfade"]');
  if (!hero) return;
  const featured = products.filter((x) => x.featured === true);
  const list = featured.length > 0 ? featured : products.slice(0, 3);
  if (list.length <= 1) return;
  let idx = 0;
  crossfadeTimer = setInterval(() => {
    idx = (idx + 1) % list.length;
    const p = list[idx];
    hero.classList.add('crossfade-out');
    setTimeout(() => {
      fillProductInto(hero, p);
      hero.classList.remove('crossfade-out');
    }, 350);
  }, 4000);
}
function bindBundleBehaviours(manifest) {
  const behaviours = Array.isArray(manifest.behaviours) ? manifest.behaviours : [];
  if (behaviours.includes('countdown-strip')) {
    // Server time: read the session doc's serverTimestamp back once
    // (+1 read, countdown visits only) so the countdown is pinned
    // to server time, never the device clock.
    if (!serverTimeCaptured) {
      serverTimeCaptured = true;
      getDoc(sessionRef).then((snap) => {
        if (snap.exists() && snap.data()) {
          const started = snap.data().startedAt;
          const ms = toMillis(started);
          if (ms > 0) serverTimeOffsetMs = ms - sessionStart;
        }
      }).catch(() => {}).finally(() => startCountdownStrip());
    } else {
      startCountdownStrip();
    }
  }
  if (behaviours.includes('hero-crossfade')) startHeroCrossfade();
}
/* Bundle data-action hooks (delegated; the bundle binds no events
 * itself — it has no JavaScript). */
document.addEventListener('click', (e) => {
  const t = e.target.closest('[data-action]');
  if (!t) return;
  const action = t.dataset.action;
  const holder = t.closest('[data-product-id]') || t.closest('[data-id]');
  const pid = t.dataset.productId || (holder ? (holder.dataset.productId || holder.dataset.id) : '') || '';
  if (action === 'add-to-cart' && pid) { addToCart(pid); return; }
  if (action === 'open-cart') { openCart(true); return; }
  if (action === 'open-product' && pid) { openProduct(pid); return; }
  if (action === 'select-category') {
    filter = t.dataset.category || 'all';
    gridExpanded = false; feedExpanded = false;
    if (activeBundleManifest) renderBundleProducts(); else { renderPills(); renderProducts(); }
    refreshCatalog();
    recordStep('category');
    return;
  }
  if (action === 'search') {
    const bar = document.getElementById('searchBar');
    if (bar) { bar.classList.add('open'); document.getElementById('searchInput')?.focus(); }
    return;
  }
  if (action === 'toggle-grid-list') {
    const mount = mountEl('products');
    if (mount) mount.classList.toggle('list-mode');
    return;
  }
  if (action === 'filter-chip') {
    filter = t.dataset.filter || t.dataset.category || 'all';
    document.querySelectorAll('[data-action="filter-chip"]').forEach((c) => c.classList.toggle('active', c === t));
    gridExpanded = false; feedExpanded = false;
    if (activeBundleManifest) renderBundleProducts(); else renderProducts();
    return;
  }
  if (action === 'toggle-compare' && pid) {
    if (compareSet.has(pid)) compareSet.delete(pid); else compareSet.add(pid);
    renderComparisonStrip();
    return;
  }
});
/* Bundle data render (non-classic path): slot filling + watchdog.
 * The fixed-DOM renderers (renderAll) run ONLY on the classic path. */
function renderBundleData() {
  fillBundleSlots();
  renderBundleProducts();
  bindBundleBehaviours(activeBundleManifest || {});
  observeReveals();
  checkRenderBlank();
}
/* Render-health watchdog: the product grid rendered empty while
 * products exist. Also fires the motion downgrade. */
function checkRenderBlank() {
  if (bootFailed) return;
  // A bundle render counts when its cards exist ([data-bundle-card]);
  // the classic render counts .product cards.
  if (products.length > 0 && !document.querySelector('.product, [data-bundle-card]')) {
    recordTemplateEvent('render_blank_detected', { templateId: activeTemplateId });
    maybeDowngradeMotion('render_blank_detected');
  }
}

/* ---------- brand + design application ---------- */
function applyBrand() {
  const name = window.__brandName || 'المتجر';
  const tag = window.__brandTag || 'تسوق';
  // Null-safe: a bundle may replace mounts that carry these ids
  // (e.g. #aboutTitle lives in the about mount).
  const setText = (id, v) => { const el = document.getElementById(id); if (el) el.textContent = v; };
  setText('brandName', name);
  setText('brandTag', tag);
  setText('footerBrand', name);
  setText('footerTag', 'الدفع عند الاستلام — ادفع لما طلبك يوصلك');
  setText('copyBrand', name);
  setText('aboutTitle', `لماذا ${name}؟`);
  document.title = name;
}
function applyDesign() {
  const d = (design && typeof design === 'object') ? design : {};
  // Announcement bar: shown ONLY when enabled with non-empty text.
  const ab = d.announcementBar || {};
  const bar = $('#announce');
  if (ab.enabled === true && ab.text) { bar.textContent = ab.text; bar.hidden = false; }
  else { bar.hidden = true; }
  // Section toggles (accentColor deliberately ignored — fixed teal look).
  const hero = document.querySelector('.hero');
  if (hero) hero.style.display = sectionOn('hero') ? '' : 'none';
  $('#offers').style.display = sectionOn('promos') ? '' : 'none';
  $('#featuredSpot').style.display = sectionOn('featured') ? '' : 'none';
  $('#delivery').style.display = sectionOn('delivery') ? '' : 'none';
  const contact = $('#contact');
  if (contact) contact.style.display = sectionOn('contact') ? '' : 'none';
}

/* ---------- app-editable brand mark + hero (see header contract) ---------- */
function applyLogoMark() {
  const url = window.__logoImageUrl;
  if (!url) return; // unset: keep the original pulse SVG exactly as in the HTML
  const mark = $('#brandMark');
  if (!mark) return;
  mark.innerHTML = `<img src="${esc(deliveryUrl(url))}" alt="" />`;
}
function applyHero() {
  const hp = homepage || {};
  // Bundle hero wins (spec M42): when a bundle is active the
  // homepage hero fields are IGNORED — the shell does not read them
  // for bundle renders. Classic still renders them.
  if (!bundleHeroActive) {
    const setText = (id, v) => {
      if (typeof v === 'string' && v.trim()) {
        const el = document.getElementById(id);
        if (el) el.textContent = v.trim();
      }
    };
    setText('heroTitleLine', hp.heroTitle);
    setText('heroAccentLine', hp.heroAccent);
    setText('heroSubtitle', hp.heroSubtitle);
  }
  // Hero image: only when set. Otherwise the original earbuds SVG + chips
  // stay exactly as in the HTML (nothing here touches them).
  // Null-safe: a bundle hero has no #heroMedia / #heroEarbuds.
  const imgUrl = (typeof hp.heroImageUrl === 'string' && hp.heroImageUrl.trim())
    ? deliveryUrl(hp.heroImageUrl.trim()) : '';
  if (!imgUrl) return;
  const media = $('#heroMedia');
  if (!media) return;
  media.innerHTML = `<img src="${esc(imgUrl)}" alt="" />`;
  media.hidden = false;
  const svg = $('#heroEarbuds');
  if (svg) svg.hidden = true;
  // The float chip carries an earbuds-specific claim ("65W"), so it
  // hides with the earbuds visual and returns with it. (The ★ 4.9
  // chip was removed at the classic freeze, D11 honesty gate.)
  document.querySelectorAll('.hero-card .float-chip').forEach((c) => { c.hidden = true; });
}

/* ---------- render: live data into the original markup ---------- */
function renderMarquee() {
  const names = categories.map((c) => c.name).filter(Boolean);
  const sec = $('#marqueeSection');
  if (names.length === 0) { sec.style.display = 'none'; return; }
  sec.style.display = '';
  const spans = names.map((n) => `<span>${esc(n)}</span>`).join('');
  $('#marqueeTrack').innerHTML = spans + spans; // duplicated for the loop
}
function renderStats() {
  $('#heroStats').innerHTML = `
    <li><strong data-count="${products.length}">0</strong><span>منتج</span></li>
    <li><strong data-count="${categories.length}">0</strong><span>قسم</span></li>
    <li><strong>كاش</strong><span>الدفع عند الاستلام</span></li>`;
  animateCounters();
  const about = $('#aboutCatalog');
  if (about) about.textContent = `${products.length} منتج في ${categories.length} قسم — بتتحدث من البرنامج.`;
}
function renderCategories() {
  $('#categoriesGrid').innerHTML = categories.map((c) => `
    <a class="cat-card reveal" href="#featured" data-cat="${c.id}">
      <span class="ico">${esc(initialOf(c.name))}</span>
      <h3>${esc(c.name)}</h3>
      <p>تسوق منتجات القسم</p>
      <div class="count">${catCount(c.id)} منتج</div>
    </a>`).join('');
}
function renderPills() {
  const all = [{ id: 'all', name: 'الكل' }, ...categories];
  $('#filterPills').innerHTML = all.map((c) => `
    <button class="pill ${filter === c.id ? 'active' : ''}" data-filter="${c.id}" role="tab">${esc(c.name)}</button>`).join('');
}
function productCard(p) {
  const cover = coverUrl(p);
  const visual = cover
    ? `<img src="${esc(cover)}" alt="${esc(p.name)}" loading="lazy" />`
    : esc(initialOf(p.name));
  return `
  <article class="product" data-id="${p.id}">
    <div class="product-visual">${visual}</div>
    <div class="product-body">
      <h3>${esc(p.name)}</h3>
      ${p.description ? `<p class="desc">${esc(p.description)}</p>` : ''}
      <div class="price-row">
        ${salePriceHtml(p)}
        <button class="add-btn" data-add="${p.id}" aria-label="أضف للسلة">+</button>
      </div>
      ${saveLineHtml(p, 1)}
    </div>
  </article>`;
}
function visibleProducts() {
  const inRange = (p) => {
    /* Price filter evaluates BOTH dimensions (§1/N4): a product is
     * included when either its charged price or its base price falls
     * in the range, so a sale item never vanishes from its
     * base-price range. Sort still follows `price` (what the
     * customer pays). */
    if (priceMin === null && priceMax === null) return true;
    const lo = priceMin === null || Number(p.price) >= priceMin || (p.basePrice != null && Number(p.basePrice) >= priceMin);
    const hi = priceMax === null || Number(p.price) <= priceMax || (p.basePrice != null && Number(p.basePrice) <= priceMax);
    return lo && hi;
  };
  const list = products.filter((p) =>
    (filter === 'all' || p.categoryId === filter) &&
    (searchQuery === '' || (p.name || '').toLowerCase().includes(searchQuery)) &&
    inRange(p));
  if (sortMode === 'price-asc') list.sort((a, b) => Number(a.price) - Number(b.price));
  else if (sortMode === 'price-desc') list.sort((a, b) => Number(b.price) - Number(a.price));
  return list;
}
function renderProducts() {
  if (bootFailed) {
    $('#productsGrid').innerHTML = `
      <div class="glass" style="grid-column:1/-1;text-align:center;padding:32px 16px">
        <h3>تعذر تحميل المنتجات</h3>
        <p style="color:var(--text-soft)">مفيش اتصال بقاعدة البيانات — اتأكد من الإنترنت وحاول تاني.</p>
        <button class="btn btn-primary" id="bootRetry">حاول تاني</button>
      </div>`;
    $('#bootRetry').addEventListener('click', () => { bootFailed = false; boot(); });
    return;
  }
  const grid = $('#productsGrid');
  // Per-template grid: fixed columns replace the stylesheet's
  // auto-fill; null columns keep the auto-fill exactly (launch
  // default). Rows cap the initially visible products (rows x
  // columns) with a "show more" button; null rows show everything.
  if (templateGrid.columns) {
    grid.style.gridTemplateColumns = `repeat(${templateGrid.columns}, 1fr)`;
  } else {
    grid.style.gridTemplateColumns = '';
  }
  const list = visibleProducts();
  let shown = list;
  let capped = 0;
  if (templateGrid.rows && !gridExpanded) {
    // Auto-fill has no fixed column count: estimate 4 per row at the
    // 250px minimum inside the 1180px container.
    const perRow = templateGrid.columns || 4;
    const cap = templateGrid.rows * perRow;
    if (list.length > cap) { shown = list.slice(0, cap); capped = list.length - cap; }
  }
  grid.innerHTML = shown.map(productCard).join('');
  const moreWrap = $('#gridMoreWrap');
  if (moreWrap) {
    if (capped > 0) {
      moreWrap.innerHTML = `<button class="btn btn-ghost" id="gridMoreBtn">عرض المزيد (${capped} منتج)</button>`;
      $('#gridMoreBtn').addEventListener('click', () => { gridExpanded = true; renderProducts(); });
    } else if (gridExpanded && templateGrid.rows) {
      moreWrap.innerHTML = `<button class="btn btn-ghost" id="gridLessBtn">عرض أقل</button>`;
      $('#gridLessBtn').addEventListener('click', () => { gridExpanded = false; renderProducts(); });
    } else {
      moreWrap.innerHTML = '';
    }
  }
  observeReveals();
}
function featuredCard(p, eyebrow) {
  const cover = coverUrl(p);
  return `
    <div class="glass featured-card reveal in">
      ${cover ? `<div class="featured-media"><img src="${esc(cover)}" alt="${esc(p.name)}" loading="lazy" /></div>` : ''}
      <div class="featured-body">
        <span class="eyebrow">${esc(eyebrow)}</span>
        <h3>${esc(p.name)}</h3>
        ${p.description ? `<p>${esc(p.description)}</p>` : ''}
        ${salePriceHtml(p)}
        ${saveLineHtml(p, 1)}
        <div class="hero-cta">
          <button class="btn btn-primary" data-add="${p.id}">أضف للسلة</button>
          <button class="btn btn-ghost" data-open="${p.id}">التفاصيل</button>
        </div>
      </div>
    </div>`;
}
function renderFeatured() {
  const spot = $('#featuredSpot');
  if (!sectionOn('featured')) { spot.innerHTML = ''; return; }
  const hp = homepage || {};
  /* All products flagged featured, in their own section, shown first.
   * Fallback when none are flagged: the old featuredProductId /
   * first-product behaviour. */
  const featured = products.filter((x) => x.featured === true);
  if (featured.length > 0) {
    spot.innerHTML = featured.map((p) => featuredCard(p, 'منتج مميز')).join('');
    return;
  }
  let p = products.find((x) => x.id === hp.featuredProductId);
  if (!p) p = products[0];
  if (!p) { spot.innerHTML = ''; return; }
  spot.innerHTML = featuredCard(p, 'منتج الشهر');
}
/* Promo product carousel: per-product image index, kept across re-renders
 * so an arrow tap is never reset by a data refresh. */
const promoCarouselIdx = {};
function stepPromoCarousel(id, dir) {
  const prod = products.find((x) => x.id === id);
  const imgs = prod ? productImages(prod) : [];
  if (imgs.length <= 1) return;
  const next = ((promoCarouselIdx[id] || 0) + dir + imgs.length) % imgs.length;
  promoCarouselIdx[id] = next;
  document.querySelectorAll('[data-carousel-img]').forEach((im) => {
    if (im.dataset.carouselImg === id) im.src = imgs[next];
  });
}
function attachPromoCarouselSwipe(wrap) {
  wrap.querySelectorAll('.promo-carousel[data-carousel-prod]').forEach((c) => {
    let x0 = null;
    c.addEventListener('touchstart', (e) => { x0 = e.changedTouches[0].clientX; }, { passive: true });
    c.addEventListener('touchend', (e) => {
      if (x0 === null) return;
      const dx = e.changedTouches[0].clientX - x0; x0 = null;
      if (Math.abs(dx) < 40) return;
      stepPromoCarousel(c.dataset.carouselProd, dx < 0 ? 1 : -1);
    }, { passive: true });
  });
}
function renderPromos() {
  const wrap = $('#promoWrap');
  const hp = homepage || {};
  let banners = Array.isArray(hp.promoBanners) ? hp.promoBanners.filter((b) => b && (b.title || b.imageUrl)) : [];
  if (banners.length === 0) {
    // Fallback: build promo cards from the first products (never a fake code).
    banners = products.slice(0, 2).map((p) => ({ imageUrl: coverUrl(p), title: p.name, subtitle: money(p.price), linkType: 'product', linkId: p.id }));
  }
  if (banners.length === 0) { $('#offers').style.display = 'none'; return; }
  wrap.innerHTML = banners.map((b) => {
    const action = (b.linkType === 'product' && b.linkId)
      ? `<button class="btn btn-primary" data-open="${b.linkId}">اطلب الآن</button>`
      : (b.linkType === 'category' && b.linkId)
        ? `<button class="btn btn-primary" data-cat-link="${b.linkId}">اطلب الآن</button>`
        : `<a href="#featured" class="btn btn-primary">اطلب الآن</a>`;
    // Product-linked offer: show the product's real images INSTEAD of the
    // decorative gradient orb — carousel when >1 image, orb fallback when 0.
    // Banners that do not resolve to a product keep the old rendering.
    const prod = (b.linkType === 'product' && b.linkId)
      ? products.find((x) => x.id === b.linkId) : null;
    const imgs = prod ? productImages(prod) : [];
    let visual;
    if (imgs.length > 0) {
      const idx = Math.min(promoCarouselIdx[prod.id] || 0, imgs.length - 1);
      promoCarouselIdx[prod.id] = idx;
      const arrows = imgs.length > 1
        ? `<button class="carousel-arrow carousel-next" data-carousel="${esc(prod.id)}" data-dir="1" aria-label="الصورة التالية">›</button>`
          + `<button class="carousel-arrow carousel-prev" data-carousel="${esc(prod.id)}" data-dir="-1" aria-label="الصورة السابقة">‹</button>`
        : '';
      visual = `<div class="promo-carousel" data-carousel-prod="${esc(prod.id)}"><img class="promo-carousel-img" data-carousel-img="${esc(prod.id)}" src="${esc(imgs[idx])}" alt="" loading="lazy" />${arrows}</div>`;
    } else {
      const img = b.imageUrl ? `<img class="promo-img" src="${esc(deliveryUrl(b.imageUrl))}" alt="" loading="lazy" />` : '';
      visual = `${img}<div class="promo-orb" aria-hidden="true"></div>`;
    }
    return `
    <div class="promo glass reveal in">
      <div>
        <span class="eyebrow">عرض</span>
        <h2>${esc(b.title || '')}</h2>
        ${b.subtitle ? `<p>${esc(b.subtitle)}</p>` : ''}
        ${action}
      </div>
      ${visual}
    </div>`;
  }).join('');
  attachPromoCarouselSwipe(wrap);
}
function renderDelivery() {
  const wrap = $('#deliveryWrap');
  if (!sectionOn('delivery')) { wrap.innerHTML = ''; return; }
  const hp = homepage || {};
  const d = hp.deliveryBanner || {};
  const title = d.title || 'الدفع عند الاستلام';
  const subtitle = d.subtitle || 'ادفع كاش لما طلبك يوصلك لحد البيت — من غير أي دفع أونلاين';
  const img = d.imageUrl ? `<img class="delivery-img" src="${esc(deliveryUrl(d.imageUrl))}" alt="" loading="lazy" />` : '';
  wrap.innerHTML = `
    <div class="glass delivery-band reveal in">
      <h2>${esc(title)}</h2>
      <p>${esc(subtitle)}</p>
      ${img}
    </div>`;
}
function renderAll() {
  renderMarquee();
  renderStats();
  renderCategories();
  renderPills();
  renderFeatured();
  renderProducts();
  renderPromos();
  renderDelivery();
  observeReveals();
}

/* ---------- cart ---------- */
function cartLines() {
  return Object.entries(cart).map(([id, qty]) => ({ p: products.find((x) => x.id === id), qty })).filter((x) => x.p);
}
function cartTotal() { return cartLines().reduce((s, i) => s + i.qty * i.p.price, 0); }
function renderCart() {
  const items = cartLines();
  const count = items.reduce((s, i) => s + i.qty, 0);
  /* [OOS] Every line carries its live availability (from
   * lineAvailabilityMap, refreshed from inventory on open / add /
   * qty change). An unorderable line stays visible and in the cart,
   * with a red line under it — and the checkout button is disabled
   * with the early blocking message BEFORE the details step. */
  const cartLineStates = items.map(({ p }) => (lineAvailabilityMap[p.id] || { state: 'ok' }).state);
  const cartBlocked = cartHasUnorderableLine(cartLineStates);
  $('#cartItems').innerHTML = items.length ? items.map(({ p, qty }) => {
    const cover = coverUrl(p);
    const thumb = cover ? `<img src="${esc(cover)}" alt="" loading="lazy" />` : esc(initialOf(p.name));
    const av = lineAvailabilityMap[p.id];
    const oosLine = !av || av.state === 'ok' ? ''
      : av.state === 'out'
        ? '<div class="oos-line">المنتج خلص من المخزون</div>'
        : `<div class="oos-line">المتاح من المنتج ده ${av.availableQty} بس — قلل الكمية</div>`;
    return `
    <div class="cart-line${oosLine ? ' oos' : ''}">
      <div class="cart-thumb">${thumb}</div>
      <div>
        <h4>${esc(p.name)}</h4>
        ${oosLine}
        ${saveLineHtml(p, qty)}
        <div class="qty">
          <button data-dec="${p.id}" aria-label="-">−</button>
          <span>${qty}</span>
          <button data-inc="${p.id}" aria-label="+">+</button>
        </div>
      </div>
      <div>
        <strong>${money(p.price * qty)}</strong>
        <div><button style="font-size:12px;color:var(--text-soft)" data-remove="${p.id}">إزالة</button></div>
      </div>
    </div>`;
  }).join('') : '<p class="cart-empty">السلة فارغة حالياً</p>';
  /* Breakdown under the total (fee line from the first render):
   * subtotal is the products total; savings, fee and amount due are
   * their own lines. With no sale items there is no "وفّرت" line;
   * with the fee unset the cart shows "التوصيل مجاني" and checkout
   * stays open (fee-default-free 2026-11-27). */
  const pr = currentPricing();
  let breakdown = $('#cartBreakdown');
  if (!breakdown) {
    breakdown = document.createElement('div');
    breakdown.id = 'cartBreakdown';
    const foot = document.querySelector('.cart-foot');
    if (foot) foot.insertBefore(breakdown, $('#checkoutBtn'));
  }
  if (breakdown) {
    breakdown.innerHTML = `
      ${cartBlocked ? '<div class="checkout-blocked-note">في منتجات خلصت من المخزون — شيلها أو قلل الكمية عشان تكمل الطلب</div>' : ''}
      ${pr.saleSavings > 0 ? `<div class="row save-row"><span>وفّرت</span><strong>${money(pr.saleSavings)}</strong></div>` : ''}
      <div class="row fee-row"><span>التوصيل</span><strong>${feeLineText(pr.feeUnset ? null : pr.deliveryFee, 'browse')}</strong></div>
      ${pr.amountDue != null ? `<div class="row due-row"><span>المبلغ المستحق عند الاستلام</span><strong>${money(pr.amountDue)}</strong></div>` : ''}`;
  }
  $('#cartTotal').textContent = money(cartTotal());
  const checkoutBtn = $('#checkoutBtn');
  if (checkoutBtn) checkoutBtn.disabled = cartBlocked;
  const badge = $('#cartCount');
  badge.textContent = count;
  badge.classList.toggle('show', count > 0);
  localStorage.setItem('sp-cart', JSON.stringify(cart));
}
/* Skeleton screens (perf item 1): the grid shows skeleton cards from
 * page load until the first catalog render replaces them; the product
 * modal shows a skeleton media block until its main image loads. */
function renderGridSkeleton() {
  const grid = $('#productsGrid');
  if (!grid || grid.children.length > 0) return;
  grid.innerHTML = Array.from({ length: 6 }, () => `
    <article class="product skeleton-card" aria-hidden="true">
      <div class="product-visual skeleton"></div>
      <div class="product-body"><div class="skeleton-line"></div><div class="skeleton-line short"></div></div>
    </article>`).join('');
}
function addToCart(id) {
  cart[id] = (cart[id] || 0) + 1;
  funnelRecorded = false; // cart activity resumes the heartbeat
  noteActivity();
  renderCart();
  saveDraftLocal();
  scheduleDraftSync();
  journeyNoteAdd(id);
  refreshCartAvailability();
  toast('تمت الإضافة للسلة');
  const btn = document.querySelector(`[data-add="${id}"]`);
  if (btn) { btn.classList.remove('added'); void btn.offsetWidth; btn.classList.add('added'); }
}
function changeQty(id, delta) {
  const next = (cart[id] || 0) + delta;
  if (next <= 0) { delete cart[id]; delete lineAvailabilityMap[id]; } else cart[id] = next;
  renderCart();
  saveDraftLocal();
  scheduleDraftSync();
  refreshCartAvailability();
}
/* Instant propagation (§6) without a standing listener: the catalog
 * is re-read on visibility return and category navigation, throttled
 * to at most one re-read per 60 seconds per tab; the cart drawer
 * re-reads only its own lines' prices when opened, at most once per
 * 60 seconds. A re-read requested inside the window is skipped and
 * the last render stands. */
let lastCatalogRefreshAt = 0;
let lastCartPriceRefreshAt = 0;
async function refreshCatalog() {
  const now = Date.now();
  if (now - lastCatalogRefreshAt < 60000) return false;
  lastCatalogRefreshAt = now;
  try {
    const [catsSnap, prodsSnap] = await Promise.all([
      getDocs(query(collection(db, 'categories'), orderBy('createdAt'))),
      getDocs(query(collection(db, 'products'), orderBy('createdAt'))),
    ]);
    categories = catsSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
    products = prodsSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
    renderAll();
    return true;
  } catch (_) { return false; }
}
async function refreshCartPrices() {
  const now = Date.now();
  if (now - lastCartPriceRefreshAt < 60000) return;
  lastCartPriceRefreshAt = now;
  const lines = cartLines();
  if (lines.length === 0) return;
  let changed = false;
  for (const { p } of lines) {
    try {
      const snap = await getDoc(doc(db, 'products', p.id));
      if (!snap.exists()) continue;
      const d = snap.data();
      if (d.price !== p.price || (d.basePrice ?? null) !== (p.basePrice ?? null)) {
        p.price = d.price;
        p.basePrice = d.basePrice ?? null;
        changed = true;
      }
    } catch (_) { /* keep the last render on a failed re-read */ }
  }
  if (changed) { renderCart(); renderProducts(); }
}
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) refreshCatalog();
});
function openCart(open) {
  $('#cartDrawer').classList.toggle('open', open);
  $('#cartDrawer').setAttribute('aria-hidden', !open);
  $('#scrim').classList.toggle('show', open);
  if (open) {
    // Cart activity resumes the heartbeat after a funnel stop.
    funnelRecorded = false;
    noteActivity();
    recordStep('cart'); refreshCartPrices(); refreshCartAvailability();
  }
}

/* ---------- toast ---------- */
let toastTimer;
function toast(msg) {
  const el = $('#toast');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2200);
}

/* ---------- modal ---------- */
function openModal(html) {
  $('#modalSheet').innerHTML = html;
  $('#modal').classList.add('open');
  $('#modal').setAttribute('aria-hidden', 'false');
}
function closeModal() {
  $('#modal').classList.remove('open');
  $('#modal').setAttribute('aria-hidden', 'true');
  $('#modalSheet').innerHTML = '';
}
function openProduct(id) {
  const p = products.find((x) => x.id === id);
  if (!p) return;
  recordStep('product');
  journeyNoteView(id);
  const imgs = productImages(p);
  const main = imgs[0] || '';
  /* Availability comes from products.inStock only — never the count.
   * A missing flag means available (older products predate the field). */
  const inStock = p.inStock !== false;
  openModal(`
    <button class="icon-btn modal-close" id="modalClose" aria-label="إغلاق">✕</button>
    ${main ? `<div class="modal-media skeleton"><img id="modalMain" src="${esc(main)}" alt="${esc(p.name)}" /></div>` : ''}
    ${imgs.length > 1 ? `<div class="modal-thumbs">${imgs.map((u, i) => `<button class="mthumb ${i === 0 ? 'on' : ''}" data-thumb="${esc(u)}">${`<img src="${esc(u)}" alt="" loading="lazy" />`}</button>`).join('')}</div>` : ''}
    <h2>${esc(p.name)}</h2>
    <span class="avail-badge ${inStock ? 'in' : 'out'}">${inStock ? 'متوفر' : 'غير متوفر'}</span>
    ${salePriceHtml(p)}
    ${saveLineHtml(p, 1)}
    ${p.description ? `<p>${esc(p.description)}</p>` : ''}
    <button class="btn btn-primary btn-block" data-add="${p.id}">أضف للسلة</button>`);
  document.querySelectorAll('[data-thumb]').forEach((b) => b.addEventListener('click', () => {
    document.querySelectorAll('[data-thumb]').forEach((x) => x.classList.remove('on'));
    b.classList.add('on');
    const m = $('#modalMain');
    if (m) m.src = b.dataset.thumb;
  }));
  /* Skeleton media clears the moment the main image loads (or at
   * once when it is already cached). */
  const modalMain = $('#modalMain');
  if (modalMain) {
    const clearSkeleton = () => modalMain.parentElement.classList.remove('skeleton');
    if (modalMain.complete) clearSkeleton();
    else modalMain.addEventListener('load', clearSkeleton, { once: true });
  }
}

/* ---------- checkout: 2-step COD, contact ONLY after info step ---------- */
function showInfoForm(err = '') {
  openModal(`
    <button class="icon-btn modal-close" id="modalClose" aria-label="إغلاق">✕</button>
    <h2>بيانات التوصيل</h2>
    <p style="color:var(--text-soft)">الدفع عند الاستلام — مفيش دفع أونلاين</p>
    ${err ? `<p class="form-err">${esc(err)}</p>` : ''}
    <label class="field"><span>الاسم</span><input id="fName" type="text" autocomplete="name" /></label>
    <label class="field"><span>رقم الموبايل</span><input id="fPhone" type="tel" dir="ltr" style="text-align:right" autocomplete="tel" /></label>
    <label class="field"><span>رقم موبايل احتياطي (اختياري)</span><input id="fPhone2" type="tel" dir="ltr" style="text-align:right" autocomplete="tel" /></label>
    <label class="field"><span>المحافظة</span><select id="fGov" dir="rtl"></select></label>
    <p class="form-err" id="govNotSetUp" hidden>التوصيل غير متاح حالياً — لم يتم إعداد مناطق التوصيل بعد</p>
    <label class="field"><span>العنوان بالتفصيل (شارع / عمارة / شقة)</span><textarea id="fAddr" rows="2" autocomplete="street-address"></textarea></label>
    <button class="btn btn-primary btn-block" id="toReview">مراجعة الطلب</button>`);
  /* Pre-fill: the local checkout draft first (typed-but-unsubmitted
   * input is not lost on reload), then the saved customer (last
   * successful order) for fields the draft does not have. */
  const draft = readLocalDraft() || {};
  const saved = loadSavedCustomer();
  const pick = (key, savedKey) => (draft[key] && String(draft[key]).trim())
    || (saved && saved[savedKey || key] ? String(saved[savedKey || key]) : '');
  if (pick('name')) $('#fName').value = pick('name');
  if (pick('phone')) $('#fPhone').value = pick('phone');
  if (pick('phone2')) $('#fPhone2').value = pick('phone2');
  if (pick('detailedAddress', 'address')) $('#fAddr').value = pick('detailedAddress', 'address');
  /* Governorate dropdown: only the active entries, read once per
   * session. A failed read falls back to the full 27; zero active
   * shows the "not set up" message and blocks checkout. */
  const govSelect = $('#fGov');
  const fillGov = (list, selectedId) => {
    govSelect.innerHTML = '<option value="">اختار المحافظة</option>'
      + list.map((g) => `<option value="${esc(g.id)}"${g.id === selectedId ? ' selected' : ''}>${esc(g.name)}</option>`).join('');
  };
  fillGov(GOVERNORATES_27, draft.governorate || (saved && saved.governorate) || '');
  loadGovernorates().then((gov) => {
    if (gov.notSetUp) {
      govSelect.innerHTML = '';
      govSelect.disabled = true;
      $('#govNotSetUp').hidden = false;
      $('#toReview').disabled = true;
      return;
    }
    fillGov(gov.entries, draft.governorate || (saved && saved.governorate) || '');
  }).catch(() => {});
  /* Draft autosave wiring: every keystroke saves locally and
   * schedules the 10s-idle server sync; leaving a field syncs now. */
  ['fName', 'fPhone', 'fPhone2', 'fGov', 'fAddr'].forEach((id) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.addEventListener('input', onDraftFieldInput);
    el.addEventListener('focusout', () => { saveDraftLocal(); syncDraftToServer().catch(() => {}); });
  });
  $('#toReview').addEventListener('click', async () => {
    const name = $('#fName').value.trim();
    const phone = $('#fPhone').value.trim();
    const phone2 = $('#fPhone2').value.trim();
    const govId = $('#fGov').value;
    const detailed = $('#fAddr').value.trim();
    if (!name) return showInfoForm('اكتب الاسم');
    if (!isValidEgyptianMobile(phone)) return showInfoForm('اكتب رقم موبايل صحيح (01xxxxxxxxx)');
    if (phone2 && !isValidEgyptianMobile(phone2)) return showInfoForm('رقم الموبايل الاحتياطي مش صحيح');
    if (!govId) return showInfoForm('اختار المحافظة');
    if (!detailed) return showInfoForm('اكتب العنوان بالتفصيل');
    /* Submit-time re-check against the live governorate list: a
     * customer who loaded the page before the change and submits
     * with a governorate that is now off is rejected here. */
    const gov = await loadGovernorates(true);
    if (gov.notSetUp) return showInfoForm('التوصيل غير متاح حالياً — لم يتم إعداد مناطق التوصيل بعد');
    if (!gov.entries.some((g) => g.id === govId)) return showInfoForm('التوصيل غير متاح للمحافظة دي حالياً');
    const addr = governorateName(govId) + ' — ' + detailed;
    // Info step COMPLETED here — only now is the contact written to
    // the analytics attempt doc. (The checkout draft itself already
    // syncs as typed, per the author decision in the header.)
    updateDoc(doc(db, 'analytics', 'attempts', 'items', attemptId),
      { contactName: name, contactPhone: phone, contactAddress: addr }).catch(() => {});
    saveDraftLocal();
    syncDraftToServer().catch(() => {});
    showReview({ name, phone, phone2: phone2 || null, governorate: govId, detailedAddress: detailed, addr });
  });
}
/* Review step. `notice` is shown when the function rejected the previous
 * confirm (price/total changed) — the customer re-confirms
 * with the same clientOrderId, never a new one. The review renders the
 * FULL breakdown the customer confirms: products subtotal, the sale
 * savings line, the fee line, the amount due, and the
 * headline "هتوفر X وهتدفع Y بدلًا من Z" (Y = amountDue, Z =
 * baseSubtotal + deliveryFee). The fee line here reads "الشحن مجانًا"
 * when the fee is 0 (the review modal is the confirm-order step). */
function showReview(customer, notice = '') {
  const lines = cartLines();
  const pr = currentPricing();
  openModal(`
    <button class="icon-btn modal-close" id="modalClose" aria-label="إغلاق">✕</button>
    <h2>مراجعة الطلب</h2>
    ${notice ? `<p class="form-err">${esc(notice)}</p>` : ''}
    <div class="review-box">
      <p><strong>${esc(customer.name)}</strong> — ${esc(customer.phone)}${customer.phone2 ? ` — ${esc(customer.phone2)}` : ''}</p>
      ${customer.governorate ? `<p>${esc(governorateName(customer.governorate))}</p>` : ''}
      <p>${esc(customer.addr)}</p>
    </div>
    ${lines.map((l) => {
      const av = lineAvailabilityMap[l.p.id];
      const oosLine = !av || av.state === 'ok' ? ''
        : av.state === 'out' ? '<div class="oos-line">المنتج خلص من المخزون</div>'
        : `<div class="oos-line">المتاح من المنتج ده ${av.availableQty} بس — قلل الكمية</div>`;
      return `<div class="cart-line${oosLine ? ' oos' : ''}"><div class="cart-thumb">${(() => { const c = coverUrl(l.p); return c ? `<img src="${esc(c)}" alt="" loading="lazy" />` : esc(initialOf(l.p.name)); })()}</div><div><h4>${esc(l.p.name)}</h4>${oosLine}<span>× ${l.qty}</span>${saveLineHtml(l.p, l.qty)}</div><strong>${money(l.p.price * l.qty)}</strong></div>`;
    }).join('')}
    <div class="cart-foot review-breakdown">
      <div class="row"><span>إجمالي المنتجات</span><strong>${money(pr.subtotal)}</strong></div>
      ${pr.saleSavings > 0 ? `<div class="row save-row"><span>وفّرت من العرض</span><strong>${money(pr.saleSavings)}</strong></div>` : ''}
      <div class="row fee-row"><span>الشحن</span><strong>${feeLineText(pr.deliveryFee, 'review')}</strong></div>
      <div class="row due-row"><span>المبلغ المستحق عند الاستلام</span><strong>${money(pr.amountDue)}</strong></div>
      ${pr.savingTotal > 0 ? `<p class="save-headline">هتوفر ${money(pr.savingTotal)} وهتدفع ${money(pr.amountDue)} بدلًا من ${money(pr.insteadOf)}</p>` : ''}
    </div>
    <p style="color:var(--text-soft)">الدفع عند الاستلام</p>
    ${isPreviewMode
      ? `<div class="preview-end-stamp" role="status">معاينة — لن يتم إنشاء طلب هنا. المراجعة تنتهي عند هذه الخطوة.</div>`
      : `<button class="btn btn-primary btn-block" id="confirmOrder">تأكيد الطلب</button>`}
    ${(!isPreviewMode && whatsappOrderEnabled) ? `<button class="btn btn-ghost btn-block" id="waOrder" style="margin-top:10px">اطلب عبر واتساب</button>` : ''}`);
  const confirmBtn = $('#confirmOrder');
  if (confirmBtn) confirmBtn.addEventListener('click', () => {
    /* Preview dry run: the confirm button is replaced in preview
     * mode (see below) and submitOrder never runs — no order, no
     * inventory reserve. */
    if (isPreviewMode) return;
    submitOrder(customer);
  });
  const waBtn = $('#waOrder');
  if (waBtn) waBtn.addEventListener('click', () => orderViaWhatsApp(customer));
}
/* WhatsApp order: no order doc is created — the pre-filled message
 * (identical breakdown through the same canonical helper) opens in
 * WhatsApp for the store to take. No transaction, no guard, no stock
 * check. A missing fee quotes free (fee-default-free), like the
 * in-app review. */
function orderViaWhatsApp(customer) {
  const pr = currentPricing();
  const lines = cartLines();
  const text = [
    'طلب جديد من المتجر',
    ...lines.map((l, i) => {
      const save = pr.perLine[i] && pr.perLine[i].saving > 0 ? ` (وفّر ${money(pr.perLine[i].saving)})` : '';
      return `- ${l.p.name} × ${l.qty} — ${money(l.p.price * l.qty)}${save}`;
    }),
    `إجمالي المنتجات: ${money(pr.subtotal)}`,
    ...(pr.saleSavings > 0 ? [`وفّرت من العرض: ${money(pr.saleSavings)}`] : []),
    pr.deliveryFee === 0 ? 'التوصيل: التوصيل مجاني' : `التوصيل: ${money(pr.deliveryFee)}`,
    `المبلغ المستحق عند الاستلام: ${money(pr.amountDue)}`,
    ...(pr.savingTotal > 0 ? [`هتوفر ${money(pr.savingTotal)} وهتدفع ${money(pr.amountDue)} بدلًا من ${money(pr.insteadOf)}`] : []),
    `الاسم: ${customer.name}`,
    `الموبايل: ${customer.phone}`,
    ...(customer.phone2 ? [`موبايل احتياطي: ${customer.phone2}`] : []),
    ...(customer.governorate ? [`المحافظة: ${governorateName(customer.governorate)}`] : []),
    `العنوان: ${customer.addr}`,
  ].join('\n');
  window.open(`https://wa.me/${whatsappNumber}?text=${encodeURIComponent(text)}`, '_blank');
}

/* ---------- order: ONE client Firestore transaction (no-functions) ----------
 * Replaces the placeOrder callable (contract §1). The transaction does,
 * atomically: idempotency by clientOrderId -> read products + inventory
 * -> validate shape/prices/stock -> total from DATABASE prices ->
 * reserve stock -> create the order (exact createOrderTx field list
 * + auditId). The movements and the audit entry left the transaction
 * (Option 3 + audit-split): they are best-effort post-commit writes
 * after a fresh create (recordOrderMovements / recordOrderAudit) —
 * never inside the tx. The products.inStock refresh is a SECOND,
 * best-effort batched write after commit (contract §13) — never
 * inside the tx.
 * The client sends ONLY product ids + quantities + the prices it
 * displayed (seenPrices/seenTotal) — never a price or total as a
 * fact. */
class OrderError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.code = code;
    this.details = details;
  }
}
/* Milliseconds from a Firestore Timestamp, a Date, an ISO string, or a
 * plain number. */
function toMillis(value) {
  if (value == null) return 0;
  if (typeof value === 'number') return value;
  if (typeof value === 'string') return Date.parse(value) || 0;
  if (typeof value.toMillis === 'function') return value.toMillis();
  if (value instanceof Date) return value.getTime();
  if (typeof value.seconds === 'number') return value.seconds * 1000;
  return 0;
}
/* Merge duplicate lines by productId, summing quantities. */
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
function newAuditId() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID();
  return 'au_' + Math.random().toString(36).slice(2) + Date.now().toString(36);
}
/* The order transaction. Returns { order, created, stockState } —
 * stockState is [{ productId, inStock }] from the inventory values the
 * transaction just wrote, for the §13 second write. Throws OrderError
 * with a structured code on any validation failure. */
async function placeOrderTx({ clientOrderId: orderId, items, customer, seenPrices, seenBasePrices, seenDeliveryFee, seenTotal }) {
  /* Shape validation (client-side, before the transaction). */
  const shapeError = (() => {
    if (!customer || typeof customer !== 'object') return 'بيانات العميل ناقصة';
    if (!customer.name || String(customer.name).trim().length === 0) return 'اكتب الاسم';
    if (!isValidEgyptianMobile(customer.phone || '')) return 'اكتب رقم موبايل صحيح';
    if (customer.phone2 && !isValidEgyptianMobile(customer.phone2)) return 'رقم الموبايل الاحتياطي مش صحيح';
    if (!customer.governorate || String(customer.governorate).trim().length === 0) return 'اختار المحافظة';
    if (!customer.detailedAddress || String(customer.detailedAddress).trim().length === 0) return 'اكتب العنوان بالتفصيل';
    if (!customer.address || String(customer.address).trim().length === 0) return 'اكتب العنوان';
    if (!Array.isArray(items) || items.length === 0) return 'السلة فارغة';
    const distinct = new Set(items.map((l) => String(l.productId || ''))).size;
    if (distinct > 7) return 'ORDER_TOO_LARGE';
    for (const line of items) {
      if (!line.productId || String(line.productId).trim() === '') return 'INVALID_INPUT';
      const qty = Number(line.qty);
      if (!Number.isInteger(qty) || qty < 1 || qty > 20) return 'INVALID_INPUT';
    }
    return null;
  })();
  if (shapeError === 'ORDER_TOO_LARGE') {
    throw new OrderError('ORDER_TOO_LARGE', 'الطلب فيه منتجات أكتر من الحد المسموح', { maxProducts: 7 });
  }
  if (shapeError) throw new OrderError('INVALID_INPUT', shapeError);
  const merged = dedupeItems(items);
  if (merged.length > 7) {
    throw new OrderError('ORDER_TOO_LARGE', 'الطلب فيه منتجات أكتر من الحد المسموح', { maxProducts: 7 });
  }
  const auditId = newAuditId();
  let result;
  await runTransaction(db, async (tx) => {
    const orderRef = doc(db, 'orders', orderId);
    /* Idempotency probe — VERIFIED TRUTH (2026-11-27): this get only
     * succeeds while the order does not exist yet. The rules deny an
     * anonymous get of an existing order (firestore.rules:997-998:
     * anonymous get allowed only when resource == null), so for an
     * anonymous storefront customer the `{ order, created: false }`
     * branch below is UNREACHABLE: a retry after a lost response is
     * denied at the probe, and a fresh attempt can duplicate. Do not
     * rely on this branch for storefront retries. (The same branch
     * IS reachable on the authenticated admin paths, where the get
     * is allowed — that is why it stays.) */
    const existing = await tx.get(orderRef);
    if (existing.exists()) {
      result = { order: { id: existing.id, ...existing.data() }, created: false, stockState: null };
      return;
    }
    /* Read products + inventory (one read per line). Base prices are
     * snapshotted per line (null when no sale); a stored base below
     * the price is not a sale (the rules deny such writes, so this
     * is only a defensive read). */
    const lines = [];
    const dbPrices = {};
    const dbBasePrices = {};
    for (const line of merged) {
      const productSnap = await tx.get(doc(db, 'products', line.productId));
      if (!productSnap.exists()) throw new OrderError('INVALID_INPUT', 'منتج مش موجود في المتجر');
      const product = productSnap.data();
      const price = Number(product.price);
      if (!Number.isFinite(price) || price <= 0) throw new OrderError('INVALID_INPUT', 'سعر المنتج مش صحيح');
      const rawBase = product.basePrice;
      const basePrice = (Number.isInteger(rawBase) && rawBase >= price) ? rawBase : null;
      const invSnap = await tx.get(doc(db, 'inventory', line.productId));
      const inv = invSnap.exists() ? invSnap.data() : { stock: 0, reserved: 0 };
      const available = (inv.stock || 0) - (inv.reserved || 0);
      if (line.qty > available) {
        throw new OrderError('INSUFFICIENT_STOCK', 'الكمية المطلوبة أكبر من المتاح', {
          productId: line.productId, availableQty: Math.max(available, 0),
        });
      }
      lines.push({ productId: line.productId, name: product.name, price, basePrice, qty: line.qty, inv });
      dbPrices[line.productId] = price;
      dbBasePrices[line.productId] = basePrice;
    }
    /* Delivery fee: one re-read of the settings doc inside the
     * transaction (the extra read per order in the quota budget).
     * A missing fee field means FREE (fee-default-free 2026-11-27):
     * the effective fee is 0, exactly like the display helper —
     * a fee removed mid-checkout still creates a free-delivery
     * order (the seen-fee guard below catches the change and
     * re-renders the review instead). The threshold waiver
     * (decision D3) applies on the `total`, exactly like the
     * display helper. */
    const settingsSnap = await tx.get(doc(db, 'storeSettings', 'settings'));
    const settingsData = settingsSnap.exists() ? settingsSnap.data() : {};
    const settingsFee = (Number.isInteger(settingsData.deliveryFee) && settingsData.deliveryFee >= 0)
      ? settingsData.deliveryFee : 0;
    const settingsThreshold = (Number.isInteger(settingsData.freeDeliveryThreshold) && settingsData.freeDeliveryThreshold > 0)
      ? settingsData.freeDeliveryThreshold : null;
    /* Totals from the DATABASE prices through the ONE canonical
     * helper — no inline money arithmetic inside this transaction.
     * The seen-value guard (§7) compares against exactly what the
     * customer saw rendered: per-line effective prices, per-line
     * base prices (a base-only change still rejects — the customer
     * confirmed a different % and saving), the fee, and the amount
     * due (seenTotal IS the seen amountDue, never the products
     * total). On any mismatch the transaction returns the current
     * database prices/fee so the client re-renders the review for a
     * fresh confirmation. */
    const pricing = computePricing(
      lines.map((l) => ({ price: l.price, basePrice: l.basePrice, qty: l.qty })),
      { deliveryFee: settingsFee, freeDeliveryThreshold: settingsThreshold });
    const subtotal = pricing.subtotal;
    const total = pricing.total;
    const deliveryFeeEffective = pricing.deliveryFee;
    const amountDue = pricing.amountDue;
    const guardDetails = {
      currentPrices: dbPrices,
      currentBasePrices: dbBasePrices,
      currentFee: deliveryFeeEffective,
      currentTotal: amountDue,
    };
    if (seenPrices && typeof seenPrices === 'object') {
      for (const [id, price] of Object.entries(dbPrices)) {
        if (seenPrices[id] !== undefined && Number(seenPrices[id]) !== price) {
          throw new OrderError('PRICE_CHANGED', 'اتغير سعر منتج من اللي شفتهم', guardDetails);
        }
      }
    }
    if (seenBasePrices && typeof seenBasePrices === 'object') {
      for (const [id, basePrice] of Object.entries(dbBasePrices)) {
        const seen = seenBasePrices[id];
        const seenBase = (seen === undefined || seen === null) ? null : Number(seen);
        if (seenBase !== basePrice) {
          throw new OrderError('PRICE_CHANGED', 'اتغير سعر منتج من اللي شفتهم', guardDetails);
        }
      }
    }
    if (seenDeliveryFee !== undefined && seenDeliveryFee !== null && Number(seenDeliveryFee) !== deliveryFeeEffective) {
      throw new OrderError('FEE_CHANGED', 'اتغيرت رسوم التوصيل', guardDetails);
    }
    if (seenTotal !== undefined && seenTotal !== null && Number(seenTotal) !== amountDue) {
      throw new OrderError('TOTAL_CHANGED', 'اتغير الإجمالي', guardDetails);
    }
    const now = serverTimestamp();
    const stockState = [];
    for (const line of lines) {
      const invRef = doc(db, 'inventory', line.productId);
      const inv = line.inv;
      const newReserved = (inv.reserved || 0) + line.qty;
      const newAvailable = (inv.stock || 0) - newReserved;
      tx.set(invRef, {
        productId: line.productId,
        stock: inv.stock || 0,
        reserved: newReserved,
        minStock: inv.minStock != null ? inv.minStock : 5,
        costPrice: inv.costPrice != null ? inv.costPrice : 0,
        updatedAt: now,
      }, { merge: true });
      /* Movements left the transaction (Option 3): the ledger write
       * happens AFTER the order commits, in recordOrderMovements —
       * the tx writes ONLY order + inventory reserves. */
      stockState.push({ productId: line.productId, inStock: newAvailable > 0 });
    }
    /* Create the order (doc id = clientOrderId) — the exact
     * createOrderTx field list, PLUS auditId, PLUS the pricing
     * snapshot: per-line basePrice, saleSavings, deliveryFee,
     * amountDue, and attemptId (present on storefront orders; the
     * key is omitted when there is no checkout attempt, so the doc
     * alone reconstructs exactly what the customer saw).
     * NOTE: these new keys are denied by the pre-feature rules —
     * they ship only after the Phase A dual-shape rules deploy. */
    const order = {
      id: orderId,
      clientOrderId: orderId,
      customerName: String(customer.name).trim(),
      customerPhone: String(customer.phone).trim(),
      customerPhone2: customer.phone2 ? String(customer.phone2).trim() : null,
      governorate: String(customer.governorate).trim(),
      detailedAddress: String(customer.detailedAddress).trim(),
      customerAddress: String(customer.address).trim(),
      items: lines.map((l) => ({ productId: l.productId, name: l.name, price: l.price, qty: l.qty, basePrice: l.basePrice })),
      subtotal,
      total,
      saleSavings: pricing.saleSavings,
      deliveryFee: deliveryFeeEffective,
      amountDue,
      status: 'new',
      paymentStatus: 'cod_pending',
      source: 'storefront',
      createdBy: null,
      shippingCompanyId: null,
      trackingNumber: null,
      notes: null,
      createdAt: now,
      updatedAt: now,
      acceptedAt: null,
      deliveredAt: null,
      cancelledAt: null,
      cancelReason: null,
      auditId,
    };
    if (attemptId) order.attemptId = attemptId;
    tx.set(orderRef, order);
    /* Audit entry left the transaction (audit-split): it is written
     * AFTER the order commits, in recordOrderAudit — the tx writes
     * ONLY order + inventory reserves. The audit payload is rebuilt
     * there from the returned order (same fields, fresh timestamp). */
    result = { order, created: true, stockState };
  });
  return result;
}
/* §13 second write: refresh products.inStock from the inventory values
 * the transaction just wrote. Batched, up to 3 attempts, best-effort —
 * a failure only leaves a stale availability flag (logged, corrected
 * by the next admin sync / lazy sweep). */
async function refreshInStock(stockState) {
  if (!stockState || stockState.length === 0) return;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const batch = writeBatch(db);
      for (const s of stockState) {
        batch.set(doc(db, 'products', s.productId), { inStock: s.inStock }, { merge: true });
      }
      await batch.commit();
      return;
    } catch (err) {
      if (attempt === 3) console.warn('[storefront] inStock refresh failed after 3 attempts', err);
    }
  }
}
/* Post-commit movement ledger (Option 3): the movement writes left
 * the order transaction — the tx writes ONLY order + inventory
 * reserves. One batch, one movement doc per line, the EXACT fields
 * the tx used to write, EXCEPT createdAt is a FRESH
 * serverTimestamp(): the movement rule (movementReserveOk) requires
 * createdAt == request.time of the movement write, and the tx's
 * sentinel would resolve to the tx's time, not this write's time.
 * Batched, up to 3 attempts, best-effort — a failure only leaves a
 * ledger gap (logged); the order already exists, so never throw. */
async function recordOrderMovements(order) {
  const items = (order && order.items) || [];
  if (items.length === 0) return;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const batch = writeBatch(db);
      for (const line of items) {
        batch.set(doc(collection(db, 'movements')), {
          productId: line.productId,
          type: 'order_reserve',
          qty: -line.qty,
          orderId: order.id,
          source: 'placeOrder',
          actorUid: null,
          createdAt: serverTimestamp(),
        });
      }
      await batch.commit();
      return;
    } catch (err) {
      if (attempt === 3) console.warn('[storefront] order movements failed after 3 attempts', err);
    }
  }
}
/* Post-commit audit entry (audit-split): the audit write left the
 * order transaction with the movements. The EXACT entry the tx used
 * to write — same operationId/actor/collection/docId/operation,
 * same changedFields/newValues/docIds/newValuesByDoc/documents,
 * rebuilt from the returned order — EXCEPT timestamp is a FRESH
 * serverTimestamp(): the audit rule (auditAnonOk) requires
 * timestamp == request.time of the audit write. Up to 3 attempts,
 * best-effort, never throws — a missing audit entry is diagnostic
 * noise, never a failed order. */
async function recordOrderAudit(order) {
  const auditId = order && order.auditId;
  const orderId = order && order.id;
  if (!auditId || !orderId) return;
  const auditFields = ['status', 'total', 'saleSavings', 'deliveryFee', 'amountDue'];
  const auditNew = { status: 'new', total: order.total, saleSavings: order.saleSavings, deliveryFee: order.deliveryFee, amountDue: order.amountDue };
  if ((order.items || []).some((l) => l.basePrice != null)) { auditFields.push('items'); auditNew.items = order.items; }
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      await setDoc(doc(db, 'audit', auditId), {
        operationId: auditId,
        actor: 'anonymous',
        actorName: 'storefront',
        timestamp: serverTimestamp(),
        collection: 'orders',
        docId: orderId,
        operation: 'create',
        changedFields: auditFields,
        oldValues: {},
        newValues: auditNew,
        docIds: { [`orders/${orderId}`]: auditFields },
        newValuesByDoc: { [`orders/${orderId}`]: auditNew },
        documents: [{
          collection: 'orders', docId: orderId,
          changedFields: auditFields, oldValues: {}, newValues: auditNew,
        }],
        source: 'placeOrder',
      });
      return;
    } catch (err) {
      if (attempt === 3) console.warn('[storefront] order audit failed after 3 attempts', err);
    }
  }
}
/* Attempt-doc failure fields (§11): one update on a failed checkout
 * — error code, the seen values, and the current database prices/fee
 * — so a price failure leaves a trace. Best-effort: a denied write
 * must never mask the error the customer already sees.
 * NOTE: `FEE_UNSET` stays in the rules' §11 allowed errorCode set
 * even though this storefront no longer throws it (fee-default-free
 * 2026-11-27 removed the throw) — an older client can still record
 * it, and this update is best-effort either way. */
async function recordAttemptFailure(code, seen, details) {
  if (!attemptId) return;
  try {
    await updateDoc(doc(db, 'analytics', 'attempts', 'items', attemptId), {
      errorCode: code,
      seenPrices: seen.seenPrices || null,
      seenBasePrices: seen.seenBasePrices || null,
      seenDeliveryFee: seen.seenDeliveryFee ?? null,
      currentPrices: (details && details.currentPrices) || null,
      currentBasePrices: (details && details.currentBasePrices) || null,
      currentFee: (details && details.currentFee !== undefined) ? details.currentFee : null,
      clientOrderId: clientOrderId || null,
      templateId: activeTemplateId, templateVersion: activeTemplateVersion,
    });
  } catch (_) { /* failure telemetry must never break checkout */ }
}
async function submitOrder(customer) {
  // Preview dry run: NEVER place an order from a preview.
  if (isPreviewMode) return;
  if (ordering) return;
  ordering = true;
  const btn = $('#confirmOrder');
  if (btn) btn.disabled = true;
  const lines = cartLines();
  /* Client-side cap (10 different products): the transaction enforces
   * it too — this only saves a round trip with a clear message. */
  if (lines.length > 7) {
    ordering = false;
    showReview(customer, 'الطلب فيه أكتر من 7 منتجات — قلل المنتجات الأول');
    return;
  }
  /* Idempotency: one clientOrderId per checkout attempt. Normally set when
   * the checkout opens; generate here only if submitOrder is ever reached
   * without it, so the order id is never null. */
  if (!clientOrderId) {
    clientOrderId = newClientOrderId();
    localStorage.setItem('sp-checkout', clientOrderId);
  }
  /* Seen values (§7): exactly what the review rendered — per-line
   * effective prices, per-line base prices, the fee the customer saw
   * (the effective fee, after any threshold waiver), and the seen
   * amountDue (seenTotal IS the amount due). */
  const seenPrices = {};
  const seenBasePrices = {};
  for (const l of lines) {
    seenPrices[l.p.id] = l.p.price;
    seenBasePrices[l.p.id] = l.p.basePrice ?? null;
  }
  const seenPricing = currentPricing();
  const seenDeliveryFee = seenPricing.deliveryFee;
  const seenTotal = seenPricing.amountDue;
  try {
    const { order, created, stockState } = await placeOrderTx({
      clientOrderId,
      items: lines.map((l) => ({ productId: l.p.id, qty: l.qty })),
      customer: {
        name: customer.name, phone: customer.phone,
        phone2: customer.phone2 || null,
        governorate: customer.governorate || '',
        detailedAddress: customer.detailedAddress || '',
        address: customer.addr,
      },
      seenPrices,
      seenBasePrices,
      seenDeliveryFee,
      seenTotal,
    });
    if (!order) throw new Error('no order returned');
    /* §13: refresh the products.inStock display cache AFTER the
     * transaction commits (best-effort, never blocks the success). */
    if (created) refreshInStock(stockState).catch(() => {});
    /* Movements + audit left the transaction (Option 3 + audit-split):
     * written AFTER the order commits, best-effort, never blocking
     * the success UI. Only on a fresh create — never on an
     * idempotent retry (created == false) and never when the
     * transaction throws (this line is unreachable then). */
    if (created) {
      recordOrderMovements(order).catch(() => {});
      recordOrderAudit(order).catch(() => {});
    }
    await updateDoc(doc(db, 'analytics', 'attempts', 'items', attemptId), { ordered: true, clientOrderId, templateId: activeTemplateId, templateVersion: activeTemplateVersion }).catch(() => {});
    recordStep('order');
    cart = {}; renderCart();
    /* Order created: this checkout attempt is done, so the next checkout
     * gets a fresh id. */
    localStorage.removeItem('sp-checkout');
    clientOrderId = null;
    /* The draft is now a real order: drop the local copy and close the
     * journey with this order id. */
    try { localStorage.removeItem('sp-draft'); } catch (_) {}
    serverDraftCreated = false;
    journey.orderId = order.id;
    flushJourney().catch(() => {});
    /* Remember the customer for the next checkout + the complaint form. */
    saveCustomer({
      name: customer.name, phone: customer.phone, phone2: customer.phone2 || null,
      governorate: customer.governorate || '', detailedAddress: customer.detailedAddress || '',
      address: customer.addr,
    });
    ordering = false;
    closeModal();
    showJourney();
  } catch (e) {
    ordering = false;
    /* Structured errors from the transaction (OrderError.code) or a
     * Firestore denial (e.code, e.g. 'permission-denied'). Real error,
     * NO animation — never a fake success. The clientOrderId is
     * deliberately KEPT (sp-checkout untouched), so a retry reuses the
     * same id instead of creating a duplicate. */
    const code = (e && e.code) || (e && e.details && e.details.code) || '';
    const details = (e && e.details) || {};
    /* checkout_failed event (templateId + error code + attemptId —
     * ids only, never PII). */
    recordTemplateEvent('checkout_failed', { errorCode: code || 'UNKNOWN', attemptId: attemptId || null });
    /* Record the failure on the attempt doc (one update per failed
     * checkout — §11), then handle the error for the customer. */
    await recordAttemptFailure(code || 'UNKNOWN', { seenPrices, seenBasePrices, seenDeliveryFee }, details);
    if (code === 'PRICE_CHANGED' || code === 'TOTAL_CHANGED' || code === 'FEE_CHANGED') {
      /* Prices/fee/total changed since the review loaded: update the
       * loaded prices AND fee from the transaction's current values
       * and re-render the review — the customer confirms the NEW
       * numbers before any order is created. */
      const current = details.currentPrices || {};
      for (const [id, price] of Object.entries(current)) {
        const p = products.find((x) => x.id === id);
        if (p) p.price = price;
      }
      const currentBases = details.currentBasePrices || {};
      for (const [id, basePrice] of Object.entries(currentBases)) {
        const p = products.find((x) => x.id === id);
        if (p) p.basePrice = basePrice;
      }
      if (details.currentFee !== undefined && details.currentFee !== null) {
        deliveryFee = details.currentFee;
      }
      renderProducts();
      renderCart();
      showReview(customer, code === 'FEE_CHANGED'
        ? 'اتغيرت رسوم التوصيل — دي الرسوم الجديدة، راجع الإجمالي وأكد تاني'
        : code === 'PRICE_CHANGED'
          ? 'اتغير سعر منتج من اللي شفتهم — دي الأسعار الجديدة، راجع الإجمالي وأكد تاني'
          : 'اتغير الإجمالي — راجع الإجمالي الجديد وأكد تاني');
      return;
    }
    if (code === 'INSUFFICIENT_STOCK') {
      const name = (details.productId && (products.find((x) => x.id === details.productId) || {}).name) || 'المنتج';
      const avail = details.availableQty ?? 0;
      const msg = avail === 0
        ? 'المنتج ده خلص من المخزون'
        : `المتاح دلوقتي من "${esc(name)}" ${avail} بس — عدّل الكمية في السلة وحاول تاني.`;
      openModal(`
        <button class="icon-btn modal-close" id="modalClose" aria-label="إغلاق">✕</button>
        <h2>الكمية مش متاحة</h2>
        <p style="color:var(--text-soft)">${msg}</p>
        <button class="btn btn-primary btn-block" id="adjustQty">تعديل الكمية</button>`);
      $('#adjustQty').addEventListener('click', () => { closeModal(); openCart(true); });
      return;
    }
    if (code === 'permission-denied') {
      /* The rules denied the reservation (an over-reservation): re-read
       * inventory and show the available count only. */
      try {
        let short = null;
        for (const l of lines) {
          const invSnap = await getDoc(doc(db, 'inventory', l.p.id));
          const inv = invSnap.exists() ? invSnap.data() : { stock: 0, reserved: 0 };
          const avail = Math.max((inv.stock || 0) - (inv.reserved || 0), 0);
          if (l.qty > avail) { short = { name: l.p.name, avail }; break; }
        }
        if (short) {
          const msg = short.avail === 0
            ? 'المنتج ده خلص من المخزون'
            : `المتاح دلوقتي من "${esc(short.name)}" ${short.avail} بس — عدّل الكمية في السلة وحاول تاني.`;
          openModal(`
            <button class="icon-btn modal-close" id="modalClose" aria-label="إغلاق">✕</button>
            <h2>الكمية مش متاحة</h2>
            <p style="color:var(--text-soft)">${msg}</p>
            <button class="btn btn-primary btn-block" id="adjustQty">تعديل الكمية</button>`);
          $('#adjustQty').addEventListener('click', () => { closeModal(); openCart(true); });
          return;
        }
      } catch (_) { /* fall through to the generic error below */ }
    }
    openModal(`
      <button class="icon-btn modal-close" id="modalClose" aria-label="إغلاق">✕</button>
      <h2>حصلت مشكلة</h2>
      <p style="color:var(--text-soft)">${esc(e && e.message ? e.message : 'تعذر إرسال الطلب، حاول تاني')}</p>
      <button class="btn btn-primary btn-block" id="retryOrder">حاول تاني</button>`);
    $('#retryOrder').addEventListener('click', () => showReview(customer));
  }
}
function showJourney() {
  const j = $('#journey');
  j.classList.add('open');
  j.setAttribute('aria-hidden', 'false');
  requestAnimationFrame(() => j.classList.add('journey-run'));
  let done = false;
  const finish = () => {
    if (done) return;
    done = true;
    j.classList.remove('open', 'journey-run');
    j.setAttribute('aria-hidden', 'true');
    openModal(`
      <button class="icon-btn modal-close" id="modalClose" aria-label="إغلاق">✕</button>
      <div style="text-align:center;padding:20px 0">
        <h2>طلبك اتأكد!</h2>
        <p style="color:var(--text-soft)">هندفع عند الاستلام — شكراً لطلبك.</p>
        <button class="btn btn-primary btn-block" id="successClose">تمام</button>
      </div>`);
    $('#successClose').addEventListener('click', closeModal);
  };
  setTimeout(finish, 2500);
  $('#jSkip').onclick = finish;
}

/* ---------- motion (original behaviour) ---------- */
let revealObserver;
function observeReveals() {
  if (!('IntersectionObserver' in window)) {
    document.querySelectorAll('.reveal, .product').forEach((el) => el.classList.add('in'));
    return;
  }
  revealObserver?.disconnect();
  // Both-directions stagger (standing rule): an item fades + slides
  // in on entry from EITHER direction and replays every time it
  // re-enters the viewport. The old observer unobserved after the
  // first intersect, so scrolling up showed items as one solid
  // block. Now exit removes 'in' (and the stagger delay) so entry
  // replays; items entering together stagger by their order in the
  // batch via transition-delay.
  revealObserver = new IntersectionObserver((entries) => {
    const entering = entries.filter((e) => e.isIntersecting);
    entering.forEach((e, i) => {
      e.target.style.transitionDelay = (Math.min(i, 8) * 60) + 'ms';
      e.target.classList.add('in');
    });
    entries.forEach((e) => {
      if (!e.isIntersecting) {
        e.target.classList.remove('in');
        e.target.style.transitionDelay = '0ms';
      }
    });
  }, { threshold: 0.12 });
  document.querySelectorAll('.reveal, .product').forEach((el) => revealObserver.observe(el));
}
function animateCounters() {
  const counters = document.querySelectorAll('[data-count]');
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      const el = e.target;
      const target = +el.dataset.count;
      const start = performance.now();
      const step = (now) => {
        const p = Math.min((now - start) / 1600, 1);
        const eased = 1 - Math.pow(1 - p, 3);
        el.textContent = Math.round(target * eased).toLocaleString('ar-EG') + (target >= 100 ? '+' : '');
        if (p < 1) requestAnimationFrame(step);
      };
      requestAnimationFrame(step);
      io.unobserve(el);
    });
  }, { threshold: 0.6 });
  counters.forEach((c) => io.observe(c));
}
function applyTheme() {
  document.documentElement.dataset.theme = theme;
  localStorage.setItem('sp-theme', theme);
}

/* ---------- events ---------- */
document.addEventListener('click', (e) => {
  const car = e.target.closest('[data-carousel]');
  if (car) { stepPromoCarousel(car.dataset.carousel, Number(car.dataset.dir || 1)); return; }
  const add = e.target.closest('[data-add]');
  if (add) { addToCart(add.dataset.add); return; }
  const open = e.target.closest('[data-open]');
  if (open) { openProduct(open.dataset.open); return; }
  const catLink = e.target.closest('[data-cat-link]');
  if (catLink) { filter = catLink.dataset.catLink; gridExpanded = false; renderPills(); renderProducts(); refreshCatalog(); document.querySelector('#featured')?.scrollIntoView({ behavior: 'smooth' }); return; }
  const pill = e.target.closest('[data-filter]');
  if (pill) { filter = pill.dataset.filter; gridExpanded = false; renderPills(); renderProducts(); refreshCatalog(); return; }
  const cat = e.target.closest('[data-cat]');
  if (cat) { filter = cat.dataset.cat; gridExpanded = false; renderPills(); renderProducts(); refreshCatalog(); recordStep('category'); return; }
  const prod = e.target.closest('.product');
  if (prod) { openProduct(prod.dataset.id); return; }
  const inc = e.target.closest('[data-inc]');
  if (inc) return changeQty(inc.dataset.inc, 1);
  const dec = e.target.closest('[data-dec]');
  if (dec) return changeQty(dec.dataset.dec, -1);
  const rm = e.target.closest('[data-remove]');
  if (rm) { delete cart[rm.dataset.remove]; delete lineAvailabilityMap[rm.dataset.remove]; renderCart(); saveDraftLocal(); scheduleDraftSync(); refreshCartAvailability(); return; }
  if (e.target.closest('#modalClose')) { closeModal(); return; }
  if (e.target === $('#modal')) { closeModal(); return; }
});
$('#cartToggle').addEventListener('click', () => openCart(true));
$('#cartClose').addEventListener('click', () => openCart(false));
$('#scrim').addEventListener('click', () => openCart(false));
$('#checkoutBtn').addEventListener('click', () => {
  if (cartLines().length === 0) { toast('السلة فارغة حالياً'); return; }
  /* [OOS] Early block: an unorderable line stops checkout BEFORE the
   * customer fills in any details — the cart already shows the red
   * line; this is the guard for a stale availability map. */
  const blockedNow = cartLines().some((l) => {
    const av = lineAvailabilityMap[l.p.id];
    return av && av.state !== 'ok';
  });
  if (blockedNow) { toast('في منتجات خلصت من المخزون — شيلها أو قلل الكمية'); openCart(true); return; }
  recordStep('checkout');
  journeyNoteCheckoutStart();
  // Attempt doc WITHOUT contact on checkout open — contact comes only
  // after the info step completes (see showInfoForm).
  attemptId = 'a_' + Math.random().toString(36).slice(2) + Date.now().toString(36);
  // One clientOrderId per checkout attempt, persisted so a reload or a
  // retry after a failed order reuses the same id (same order doc id, so
  // no duplicate). Cleared only when the order is created.
  if (!clientOrderId) {
    clientOrderId = newClientOrderId();
    localStorage.setItem('sp-checkout', clientOrderId);
  }
  setDoc(doc(db, 'analytics', 'attempts', 'items', attemptId),
    { startedAt: serverTimestamp(), ordered: false, clientOrderId,
      templateId: activeTemplateId, templateVersion: activeTemplateVersion,
      shellVersion: SHELL_VERSION }, { merge: true }).catch(() => {});
  funnelRecorded = true; // heartbeat stops; resumes on cart/checkout activity
  noteActivity();
  openCart(false);
  showInfoForm();
});
$('#searchToggle').addEventListener('click', () => {
  const bar = $('#searchBar');
  bar.classList.toggle('open');
  if (bar.classList.contains('open')) $('#searchInput').focus();
});
/* Search is debounced (perf item 2): every keystroke used to
 * re-filter and re-render the grid immediately. 250 ms of quiet
 * before the filter runs; there is no autocomplete to debounce. */
let searchDebounceTimer;
$('#searchInput').addEventListener('input', (e) => {
  const value = e.target.value.trim().toLowerCase();
  clearTimeout(searchDebounceTimer);
  searchDebounceTimer = setTimeout(() => {
    searchQuery = value;
    gridExpanded = false;
    renderProducts();
  }, 250);
});
/* Price filter (min/max) + sort by price. An empty or invalid bound
 * means "no limit". The price inputs are debounced like search (they
 * run the same re-filter + re-render); sort is a change event and
 * stays immediate. */
let priceFilterDebounceTimer;
function debouncedPriceFilter() {
  clearTimeout(priceFilterDebounceTimer);
  priceFilterDebounceTimer = setTimeout(() => { gridExpanded = false; renderProducts(); }, 250);
}
const priceMinInput = $('#priceMin');
if (priceMinInput) priceMinInput.addEventListener('input', (e) => {
  const v = Number(e.target.value);
  priceMin = (e.target.value === '' || !Number.isFinite(v) || v < 0) ? null : v;
  debouncedPriceFilter();
});
const priceMaxInput = $('#priceMax');
if (priceMaxInput) priceMaxInput.addEventListener('input', (e) => {
  const v = Number(e.target.value);
  priceMax = (e.target.value === '' || !Number.isFinite(v) || v < 0) ? null : v;
  debouncedPriceFilter();
});
const sortSelect = $('#sortSelect');
if (sortSelect) sortSelect.addEventListener('change', (e) => {
  sortMode = ['price-asc', 'price-desc'].includes(e.target.value) ? e.target.value : 'none';
  gridExpanded = false;
  renderProducts();
});
$('#themeToggle').addEventListener('click', () => {
  theme = theme === 'dark' ? 'light' : 'dark';
  applyTheme();
});

/* ---------- saved customer (sp-customer) ----------
 * The checkout info (name/phone/address) is saved here when an
 * order succeeds, so the customer doesn't retype it: the next
 * checkout info form and the complaint form are pre-filled from
 * it. Fields stay editable; nothing is sent anywhere except as
 * the order's own customer data or the complaint's phone. */
const STORE_PHONE = '01557887719';
function loadSavedCustomer() {
  try {
    const raw = localStorage.getItem('sp-customer');
    if (!raw) return null;
    const c = JSON.parse(raw);
    if (!c || typeof c !== 'object') return null;
    return {
      name: typeof c.name === 'string' ? c.name : '',
      phone: typeof c.phone === 'string' ? c.phone : '',
      phone2: typeof c.phone2 === 'string' ? c.phone2 : '',
      governorate: typeof c.governorate === 'string' ? c.governorate : '',
      detailedAddress: typeof c.detailedAddress === 'string' ? c.detailedAddress : '',
      address: typeof c.address === 'string' ? c.address : '',
    };
  } catch (_) {
    return null;
  }
}
function saveCustomer(customer) {
  try {
    localStorage.setItem('sp-customer', JSON.stringify({
      name: customer.name || '',
      phone: customer.phone || '',
      phone2: customer.phone2 || '',
      governorate: customer.governorate || '',
      detailedAddress: customer.detailedAddress || '',
      address: customer.address || customer.addr || '',
    }));
  } catch (_) { /* storage unavailable — pre-fill just won't happen */ }
}
/* Fill the complaint form from the saved customer; the phone falls
 * back to the store number when there is no saved customer. Only
 * empty fields are filled, so typed text is never clobbered. */
function prefillFeedbackForm() {
  const nameEl = $('#fbName');
  const phoneEl = $('#fbPhone');
  if (!nameEl || !phoneEl) return;
  const saved = loadSavedCustomer();
  if (nameEl.value.trim() === '' && saved && saved.name) nameEl.value = saved.name;
  if (phoneEl.value.trim() === '') {
    phoneEl.value = (saved && saved.phone) || STORE_PHONE;
  }
}

/* ---------- feedback: "Contact us" — one-way complaint cards ----------
 * No functions, no tracking code, no lookup. The form writes directly
 * to the feedback collection (contract §6, shape §3): name, email,
 * phone, message, createdAt. Admin reads the cards; spam is deleted
 * from the admin apps. */
async function submitFeedbackForm(e) {
  if (e && e.preventDefault) e.preventDefault();
  const resultEl = $('#fbResult');
  const showResult = (msg, ok) => {
    if (!resultEl) return;
    resultEl.hidden = false;
    resultEl.textContent = msg;
    resultEl.style.color = ok ? 'var(--accent)' : '#c0392b';
  };
  const name = (($('#fbName') || {}).value || '').trim();
  const email = (($('#fbEmail') || {}).value || '').trim();
  const phone = (($('#fbPhone') || {}).value || '').replace(/[^0-9]/g, '');
  const message = (($('#fbMessage') || {}).value || '').trim();
  /* Name/phone are required only for a direct complaint. The
   * exit-intent popup and the footer link send anonymous feedback
   * (source 'exit-feedback' / 'footer-feedback') — those may have
   * empty name and phone, and the rules allow exactly that. */
  const anonymous = feedbackSource !== 'direct';
  if (!anonymous && (name.length === 0 || name.length > 100)) return showResult('اكتب الاسم (لحد 100 حرف)');
  if (name.length > 100) return showResult('الاسم لحد 100 حرف');
  if (email.length > 0 && (!email.includes('@') || email.length > 100)) return showResult('اكتب إيميل صحيح');
  if (!anonymous && (phone.length < 10 || phone.length > 15)) return showResult('اكتب رقم موبايل صحيح');
  if (phone.length > 15) return showResult('اكتب رقم موبايل صحيح');
  if (message.length < 10 || message.length > 2000) return showResult('اكتب رسالتك (من 10 لـ 2000 حرف)');
  const btn = $('#fbSubmit');
  if (btn) btn.disabled = true;
  try {
    await setDoc(doc(collection(db, 'feedback')), {
      name, email, phone, message, source: feedbackSource,
      createdAt: serverTimestamp(),
    });
    showResult('تم استلام شكواك — شكراً', true);
    const form = $('#fbForm');
    if (form && form.reset) form.reset();
    feedbackSource = 'direct';
  } catch (_) {
    showResult('حصلت مشكلة — حاول تاني');
  } finally {
    if (btn) btn.disabled = false;
  }
}
const fbForm = $('#fbForm');
if (fbForm) fbForm.addEventListener('submit', submitFeedbackForm);
/* Feedback source: 'direct' by default; the footer link (mobile
 * feedback entry point) marks the next submission 'footer-feedback'
 * so the admin sees where it came from. */
let feedbackSource = 'direct';
const footerFeedbackLink = document.getElementById('footerFeedbackLink');
if (footerFeedbackLink) footerFeedbackLink.addEventListener('click', (e) => {
  e.preventDefault();
  feedbackSource = 'footer-feedback';
  document.querySelector('#contact')?.scrollIntoView({ behavior: 'smooth' });
  setTimeout(() => { const m = document.getElementById('fbMessage'); if (m) m.focus(); }, 400);
});
/* Fill the complaint form when it first appears (and once at init,
 * in case it is already visible) — only empty fields are filled. */
prefillFeedbackForm();
if ('IntersectionObserver' in window) {
  const contactSection = $('#contact');
  if (contactSection) {
    const contactObs = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      prefillFeedbackForm();
      const nameEl = $('#fbName');
      const phoneEl = $('#fbPhone');
      if (nameEl && phoneEl && nameEl.value.trim() !== '' && phoneEl.value.trim() !== '') contactObs.disconnect();
    }, { threshold: 0.1 });
    contactObs.observe(contactSection);
  }
}
window.addEventListener('scroll', () => {
  $('#topbar').classList.toggle('scrolled', window.scrollY > 20);
}, { passive: true });

/* Subtle parallax on hero card (original behaviour) */
const heroCard = document.querySelector('.hero-card');
if (heroCard && matchMedia('(pointer: fine)').matches) {
  document.addEventListener('pointermove', (e) => {
    const x = (e.clientX / window.innerWidth - 0.5) * 14;
    const y = (e.clientY / window.innerHeight - 0.5) * 14;
    heroCard.style.transform = `translate(${x * 0.3}px, ${y * 0.3}px)`;
  });
}

/* ---------- boot (perf item 5: parallel boot reads) ----------
 * Boot was a serial waterfall (settings -> homepage -> design ->
 * template pointer -> template doc -> categories -> products:
 * 5+N+M reads per visit). The reads are independent, so they now run
 * in parallel in one Promise.all — same reads, same total count, no
 * new reads per visit, no cache added. Each step still fails
 * independently into its existing fallback. */
$('#year').textContent = new Date().getFullYear();
applyTheme();
renderCart();
renderGridSkeleton();
/* Named (not an IIFE) so the boot-error retry button can re-run it. */
async function boot() {
  const loadSettings = (async () => {
    try {
      const sSnap = await getDoc(doc(db, 'storeSettings', 'settings'));
      if (sSnap.exists()) {
        const d = sSnap.data();
        // Brand slot: settings brandName when set, else neutral "المتجر".
        if (d.brandName) window.__brandName = d.brandName;
        if (d.tagline) window.__brandTag = d.tagline;
        // Logo mark: settings logoImageUrl when set (non-empty), else pulse SVG.
        if (typeof d.logoImageUrl === 'string' && d.logoImageUrl.trim()) window.__logoImageUrl = d.logoImageUrl.trim();
        // WhatsApp ordering: off unless the toggle is true; the number
        // defaults to the store's WhatsApp line when unset/empty.
        if (d.whatsappOrderEnabled === true) whatsappOrderEnabled = true;
        if (typeof d.whatsappNumber === 'string' && d.whatsappNumber.trim()) {
          whatsappNumber = d.whatsappNumber.trim();
        }
        // Delivery fee + free-delivery threshold (pricing): ride this
        // existing read. A missing fee field leaves deliveryFee null,
        // which the pricing helper treats as free (fee-default-free).
        if (Number.isInteger(d.deliveryFee) && d.deliveryFee >= 0) deliveryFee = d.deliveryFee;
        if (Number.isInteger(d.freeDeliveryThreshold) && d.freeDeliveryThreshold > 0) {
          freeDeliveryThreshold = d.freeDeliveryThreshold;
        }
      }
    } catch (_) {}
  })();
  const loadHomepage = (async () => {
    try {
      const hSnap = await getDoc(doc(db, 'storeSettings', 'homepage'));
      if (hSnap.exists() && hSnap.data()) homepage = hSnap.data();
    } catch (_) {}
  })();
  const loadDesign = (async () => {
    try {
      const dSnap = await getDoc(doc(db, 'storeSettings', 'design'));
      if (dSnap.exists() && dSnap.data()) design = dSnap.data();
    } catch (_) {}
  })();
  /* Active template (pointer -> template doc -> classic.json ->
   * built-in classic). Loaded before applyDesign so the template's
   * section toggles apply with the design toggles. */
  const loadTemplate = loadActiveTemplate();
  const loadCatalog = (async () => {
    try {
      const catsSnap = await getDocs(query(collection(db, 'categories'), orderBy('createdAt')));
      categories = catsSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
      const prodsSnap = await getDocs(query(collection(db, 'products'), orderBy('createdAt')));
      products = prodsSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
    } catch (_) {
      /* Catalog load failure is NOT silent anymore: the products grid
       * shows the error with a retry (renderProducts reads bootFailed). */
      bootFailed = true;
    }
  })();
  /* [Incomplete-orders] Pre-load governorates + quota in parallel
   * with the catalog (cached; failures fall back silently). GA4 loads
   * only when a measurement ID is configured. */
  loadGA4();
  const loadGov = loadGovernorates().catch(() => {});
  const loadQ = loadQuota().catch(() => {});
  await Promise.all([loadSettings, loadHomepage, loadDesign, loadTemplate, loadCatalog, loadGov, loadQ]);
  applyBrand();
  applyLogoMark();
  if (activeBundleManifest) {
    // Bundle path: the bundle hero wins (applyHero skips the
    // homepage hero fields) and the slot contract fills the mounts.
    // The fixed-DOM renderers do not run on this path.
    applyHero();
    renderBundleData();
  } else {
    applyDesign();
    applyHero();
    renderAll();
    checkRenderBlank();
  }
  observeReveals();
  refreshCartAvailability();
}
boot();
