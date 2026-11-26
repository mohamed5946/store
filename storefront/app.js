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
 * - Customer contact is saved ONLY after the info step completes with valid
 *   data. Typing without completing never stores contact. No keystroke
 *   capture anywhere.
 * - The order doc is created EXACTLY ONCE, before the journey animation.
 *   On failure the real error shows and NO animation plays (never fake).
 * - Analytics are anonymous (random localStorage id, heartbeat, funnel).
 * - No invented stats, discount codes, or product claims anywhere.
 */

import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js';
import {
  getFirestore, collection, query, orderBy, getDocs, doc, getDoc,
  setDoc, updateDoc, serverTimestamp, arrayUnion,
} from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js';
import {
  getFunctions, httpsCallable,
} from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-functions.js';

const app = initializeApp(window.STORE_FIREBASE_CONFIG);
const db = getFirestore(app);
const functions = getFunctions(app); /* us-central1 (default) */
const placeOrderCallable = httpsCallable(functions, 'placeOrder');
const submitFeedbackCallable = httpsCallable(functions, 'submitFeedback');
const getFeedbackStatusCallable = httpsCallable(functions, 'getFeedbackStatus');

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
async function heartbeat() {
  try {
    await updateDoc(sessionRef, { lastSeenAt: serverTimestamp(), durationMs: Date.now() - sessionStart });
  } catch (_) {}
}
setDoc(sessionRef, { startedAt: serverTimestamp(), lastSeenAt: serverTimestamp(), durationMs: 0, steps: ['home'] }, { merge: true }).catch(() => {});
setInterval(heartbeat, 30000);
window.addEventListener('pagehide', heartbeat);

/* ---------- state ---------- */
let categories = [];
let products = [];
let homepage = {};
let design = {};
let searchQuery = '';
let filter = 'all';
let cart = JSON.parse(localStorage.getItem('sp-cart') || '{}');
let attemptId = null;
let clientOrderId = localStorage.getItem('sp-checkout') || null;
function newClientOrderId() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID();
  return 'o_' + Math.random().toString(36).slice(2) + Date.now().toString(36);
}
let ordering = false;
let theme = localStorage.getItem('sp-theme') || 'light';
/* Discount code typed in the review step (sent to the placeOrder
 * callable; the function validates and consumes it server-side). */
let discountCode = '';
/* True when the catalog load failed at boot — renderProducts shows an
 * error UI with a retry instead of an empty grid (the silent catches
 * used to swallow this with zero signal). */
let bootFailed = false;

/* ---------- active template (Phase 3) ---------- */
/* The storefront is a frozen trusted shell + a swappable template
 * skin. The template is declarative data only (JSON): tokens (CSS
 * variables), grid (rows x columns), section toggles. No template
 * runs JavaScript, so no template can read the cart, the checkout
 * form, or customer contact data.
 * Load order: the pointer (storeSettings/activeTemplate) -> the
 * template document (public get, only the active one) -> the
 * bundled classic.json asset -> the built-in classic below. Any
 * step that fails or fails validation falls through to the next,
 * so the site always renders — the launch template is the current
 * site, unchanged. */
let activeTemplateId = 'classic';
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

/* Cloudinary auto-optimization: every Cloudinary image is served with
 * f_auto,q_auto so the storefront loads fast. Pasted links pass through. */
function deliveryUrl(u) {
  if (!u || !u.includes('res.cloudinary.com') || u.includes('f_auto')) return u;
  return u.replace('/upload/', '/upload/f_auto,q_auto/');
}
function coverUrl(p) {
  const imgs = p.images || [];
  if (imgs.length > 0 && imgs[0].url) return deliveryUrl(imgs[0].url);
  if (p.imageUrl) return p.imageUrl;
  return '';
}
function productImages(p) {
  const imgs = (p.images || []).filter((i) => i && i.url).map((i) => deliveryUrl(i.url));
  if (imgs.length === 0 && p.imageUrl) imgs.push(p.imageUrl);
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
async function loadActiveTemplate() {
  try {
    const ptrSnap = await getDoc(doc(db, 'storeSettings', 'activeTemplate'));
    let body = null;
    if (ptrSnap.exists() && ptrSnap.data() && typeof ptrSnap.data().templateId === 'string' && ptrSnap.data().templateId) {
      const tSnap = await getDoc(doc(db, 'templates', ptrSnap.data().templateId));
      if (tSnap.exists() && tSnap.data()) body = { id: tSnap.id, ...tSnap.data() };
    }
    if (!body || !validateTemplateBody(body).passed) body = await loadClassicTemplateFile();
    if (!body || !validateTemplateBody(body).passed) body = CLASSIC_TEMPLATE;
    applyTemplate(body);
  } catch (_) {
    applyTemplate(CLASSIC_TEMPLATE);
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
}

/* ---------- brand + design application ---------- */
function applyBrand() {
  const name = window.__brandName || 'المتجر';
  const tag = window.__brandTag || 'تسوق';
  $('#brandName').textContent = name;
  $('#brandTag').textContent = tag;
  $('#footerBrand').textContent = name;
  $('#footerTag').textContent = 'الدفع عند الاستلام — ادفع لما طلبك يوصلك';
  $('#copyBrand').textContent = name;
  $('#aboutTitle').textContent = `لماذا ${name}؟`;
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
  $('#brandMark').innerHTML = `<img src="${esc(deliveryUrl(url))}" alt="" />`;
}
function applyHero() {
  const hp = homepage || {};
  const setText = (id, v) => {
    if (typeof v === 'string' && v.trim()) {
      const el = document.getElementById(id);
      if (el) el.textContent = v.trim();
    }
  };
  setText('heroTitleLine', hp.heroTitle);
  setText('heroAccentLine', hp.heroAccent);
  setText('heroSubtitle', hp.heroSubtitle);
  // Hero image: only when set. Otherwise the original earbuds SVG + chips
  // stay exactly as in the HTML (nothing here touches them).
  const imgUrl = (typeof hp.heroImageUrl === 'string' && hp.heroImageUrl.trim())
    ? deliveryUrl(hp.heroImageUrl.trim()) : '';
  if (!imgUrl) return;
  const media = $('#heroMedia');
  media.innerHTML = `<img src="${esc(imgUrl)}" alt="" />`;
  media.hidden = false;
  const svg = $('#heroEarbuds');
  if (svg) svg.hidden = true;
  // The float chips carry earbuds-specific claims ("65W", "4.9"), so they
  // hide with the earbuds visual and return with it.
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
        <span class="price">${money(p.price)}</span>
        <button class="add-btn" data-add="${p.id}" aria-label="أضف للسلة">+</button>
      </div>
    </div>
  </article>`;
}
function visibleProducts() {
  return products.filter((p) =>
    (filter === 'all' || p.categoryId === filter) &&
    (searchQuery === '' || (p.name || '').toLowerCase().includes(searchQuery)));
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
function renderFeatured() {
  const spot = $('#featuredSpot');
  if (!sectionOn('featured')) { spot.innerHTML = ''; return; }
  const hp = homepage || {};
  let p = products.find((x) => x.id === hp.featuredProductId);
  if (!p) p = products[0];
  if (!p) { spot.innerHTML = ''; return; }
  const cover = coverUrl(p);
  spot.innerHTML = `
    <div class="glass featured-card reveal in">
      ${cover ? `<div class="featured-media"><img src="${esc(cover)}" alt="${esc(p.name)}" /></div>` : ''}
      <div class="featured-body">
        <span class="eyebrow">منتج الشهر</span>
        <h3>${esc(p.name)}</h3>
        ${p.description ? `<p>${esc(p.description)}</p>` : ''}
        <div class="price">${money(p.price)}</div>
        <div class="hero-cta">
          <button class="btn btn-primary" data-add="${p.id}">أضف للسلة</button>
          <button class="btn btn-ghost" data-open="${p.id}">التفاصيل</button>
        </div>
      </div>
    </div>`;
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
      visual = `<div class="promo-carousel" data-carousel-prod="${esc(prod.id)}"><img class="promo-carousel-img" data-carousel-img="${esc(prod.id)}" src="${esc(imgs[idx])}" alt="" />${arrows}</div>`;
    } else {
      const img = b.imageUrl ? `<img class="promo-img" src="${esc(deliveryUrl(b.imageUrl))}" alt="" />` : '';
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
  const img = d.imageUrl ? `<img class="delivery-img" src="${esc(deliveryUrl(d.imageUrl))}" alt="" />` : '';
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
  $('#cartItems').innerHTML = items.length ? items.map(({ p, qty }) => {
    const cover = coverUrl(p);
    const thumb = cover ? `<img src="${esc(cover)}" alt="" />` : esc(initialOf(p.name));
    return `
    <div class="cart-line">
      <div class="cart-thumb">${thumb}</div>
      <div>
        <h4>${esc(p.name)}</h4>
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
  $('#cartTotal').textContent = money(cartTotal());
  const badge = $('#cartCount');
  badge.textContent = count;
  badge.classList.toggle('show', count > 0);
  localStorage.setItem('sp-cart', JSON.stringify(cart));
}
function addToCart(id) {
  cart[id] = (cart[id] || 0) + 1;
  renderCart();
  toast('تمت الإضافة للسلة');
  const btn = document.querySelector(`[data-add="${id}"]`);
  if (btn) { btn.classList.remove('added'); void btn.offsetWidth; btn.classList.add('added'); }
}
function changeQty(id, delta) {
  const next = (cart[id] || 0) + delta;
  if (next <= 0) delete cart[id]; else cart[id] = next;
  renderCart();
}
function openCart(open) {
  $('#cartDrawer').classList.toggle('open', open);
  $('#cartDrawer').setAttribute('aria-hidden', !open);
  $('#scrim').classList.toggle('show', open);
  if (open) recordStep('cart');
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
  const imgs = productImages(p);
  const main = imgs[0] || '';
  openModal(`
    <button class="icon-btn modal-close" id="modalClose" aria-label="إغلاق">✕</button>
    ${main ? `<div class="modal-media"><img id="modalMain" src="${esc(main)}" alt="${esc(p.name)}" /></div>` : ''}
    ${imgs.length > 1 ? `<div class="modal-thumbs">${imgs.map((u, i) => `<button class="mthumb ${i === 0 ? 'on' : ''}" data-thumb="${esc(u)}">${`<img src="${esc(u)}" alt="" />`}</button>`).join('')}</div>` : ''}
    <h2>${esc(p.name)}</h2>
    <div class="price">${money(p.price)}</div>
    ${p.description ? `<p>${esc(p.description)}</p>` : ''}
    <button class="btn btn-primary btn-block" data-add="${p.id}">أضف للسلة</button>`);
  document.querySelectorAll('[data-thumb]').forEach((b) => b.addEventListener('click', () => {
    document.querySelectorAll('[data-thumb]').forEach((x) => x.classList.remove('on'));
    b.classList.add('on');
    const m = $('#modalMain');
    if (m) m.src = b.dataset.thumb;
  }));
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
    <label class="field"><span>العنوان</span><textarea id="fAddr" rows="2" autocomplete="street-address"></textarea></label>
    <button class="btn btn-primary btn-block" id="toReview">مراجعة الطلب</button>`);
  $('#toReview').addEventListener('click', () => {
    const name = $('#fName').value.trim();
    const phone = $('#fPhone').value.trim();
    const addr = $('#fAddr').value.trim();
    const digits = phone.replace(/\D/g, '');
    if (!name) return showInfoForm('اكتب الاسم');
    if (digits.length < 10) return showInfoForm('اكتب رقم موبايل صحيح');
    if (!addr) return showInfoForm('اكتب العنوان');
    // Info step COMPLETED here — only now may contact info be saved.
    updateDoc(doc(db, 'analytics', 'attempts', 'items', attemptId),
      { contactName: name, contactPhone: phone, contactAddress: addr }).catch(() => {});
    showReview({ name, phone, addr });
  });
}
/* Review step. `notice` is shown when the function rejected the previous
 * confirm (price/total changed, bad code) — the customer re-confirms
 * with the same clientOrderId, never a new one. */
function showReview(customer, notice = '') {
  const lines = cartLines();
  openModal(`
    <button class="icon-btn modal-close" id="modalClose" aria-label="إغلاق">✕</button>
    <h2>مراجعة الطلب</h2>
    ${notice ? `<p class="form-err">${esc(notice)}</p>` : ''}
    <div class="review-box">
      <p><strong>${esc(customer.name)}</strong> — ${esc(customer.phone)}</p>
      <p>${esc(customer.addr)}</p>
    </div>
    ${lines.map((l) => `<div class="cart-line"><div class="cart-thumb">${(() => { const c = coverUrl(l.p); return c ? `<img src="${esc(c)}" alt="" />` : esc(initialOf(l.p.name)); })()}</div><div><h4>${esc(l.p.name)}</h4><span>× ${l.qty}</span></div><strong>${money(l.p.price * l.qty)}</strong></div>`).join('')}
    <div class="cart-foot"><div class="row"><span>الإجمالي</span><strong>${money(cartTotal())}</strong></div></div>
    <label class="field"><span>كود خصم (اختياري)</span><input id="fDiscount" type="text" dir="ltr" style="text-align:right" placeholder="اكتب الكود لو معاك" value="${esc(discountCode)}" /></label>
    <p style="color:var(--text-soft)">الدفع عند الاستلام</p>
    <button class="btn btn-primary btn-block" id="confirmOrder">تأكيد الطلب</button>`);
  $('#confirmOrder').addEventListener('click', () => {
    discountCode = ($('#fDiscount').value || '').trim();
    submitOrder(customer);
  });
}

/* ---------- order journey: the trusted placeOrder callable creates the
 * order EXACTLY ONCE, then the van drives ----------
 * The client function is named submitOrder (not placeOrder) so it never
 * collides with the callable of the same name. The client sends ONLY
 * product ids + quantities + (optionally) a discount code + the prices
 * it displayed (seenPrices/seenTotal) — never a price or total as a
 * fact. The function recomputes everything from the database. */
async function submitOrder(customer) {
  if (ordering) return;
  ordering = true;
  const btn = $('#confirmOrder');
  if (btn) btn.disabled = true;
  const lines = cartLines();
  /* Client-side cap (10 different products, T23): the function enforces
   * it too — this only saves a round trip with a clear message. */
  if (lines.length > 10) {
    ordering = false;
    showReview(customer, 'الطلب فيه أكتر من 10 منتجات — قلل المنتجات الأول');
    return;
  }
  const total = cartTotal();
  /* Idempotency: one clientOrderId per checkout attempt. Normally set when
   * the checkout opens; generate here only if submitOrder is ever reached
   * without it, so the order id is never null. */
  if (!clientOrderId) {
    clientOrderId = newClientOrderId();
    localStorage.setItem('sp-checkout', clientOrderId);
  }
  const seenPrices = {};
  for (const l of lines) seenPrices[l.p.id] = l.p.price;
  try {
    const res = await placeOrderCallable({
      clientOrderId,
      items: lines.map((l) => ({ productId: l.p.id, qty: l.qty })),
      discountCode: discountCode || null,
      customer: { name: customer.name, phone: customer.phone, address: customer.addr },
      seenPrices,
      seenTotal: total,
    });
    const order = res && res.data && res.data.order;
    if (!order) throw new Error('no order returned');
    await updateDoc(doc(db, 'analytics', 'attempts', 'items', attemptId), { ordered: true }).catch(() => {});
    recordStep('order');
    cart = {}; discountCode = ''; renderCart();
    /* Order created: this checkout attempt is done, so the next checkout
     * gets a fresh id. */
    localStorage.removeItem('sp-checkout');
    clientOrderId = null;
    ordering = false;
    closeModal();
    showJourney();
  } catch (e) {
    ordering = false;
    /* Structured errors from the function (e.details.code). Real error,
     * NO animation — never a fake success. The clientOrderId is
     * deliberately KEPT (sp-checkout untouched), so a retry reuses the
     * same id instead of creating a duplicate. */
    const code = (e && e.details && e.details.code) || '';
    const details = (e && e.details) || {};
    if (code === 'PRICE_CHANGED' || code === 'TOTAL_CHANGED') {
      /* Prices/total changed since the review loaded: update the loaded
       * prices from the function's current values and re-render the
       * review — the customer confirms the NEW total before any order
       * is created (T15). */
      const current = details.currentPrices || {};
      for (const [id, price] of Object.entries(current)) {
        const p = products.find((x) => x.id === id);
        if (p) p.price = price;
      }
      renderProducts();
      showReview(customer, code === 'PRICE_CHANGED'
        ? 'اتغير سعر منتج من اللي شفتهم — دي الأسعار الجديدة، راجع الإجمالي وأكد تاني'
        : 'اتغير الإجمالي — راجع الإجمالي الجديد وأكد تاني');
      return;
    }
    if (code === 'INSUFFICIENT_STOCK') {
      const name = (details.productId && (products.find((x) => x.id === details.productId) || {}).name) || 'المنتج';
      const avail = details.availableQty ?? 0;
      openModal(`
        <button class="icon-btn modal-close" id="modalClose" aria-label="إغلاق">✕</button>
        <h2>الكمية مش متاحة</h2>
        <p style="color:var(--text-soft)">المتاح دلوقتي من "${esc(name)}" ${avail} بس — عدّل الكمية في السلة وحاول تاني.</p>
        <button class="btn btn-primary btn-block" id="adjustQty">تعديل الكمية</button>`);
      $('#adjustQty').addEventListener('click', () => { closeModal(); openCart(true); });
      return;
    }
    if (code === 'DISCOUNT_INVALID' || code === 'DISCOUNT_USED') {
      showReview(customer, code === 'DISCOUNT_USED'
        ? 'كود الخصم ده اتستخدم قبل كده — جرّب كود تاني أو كمّل من غيره'
        : 'كود الخصم مش صحيح — اتأكد منه أو كمّل من غيره');
      return;
    }
    if (code === 'RATE_LIMITED') {
      openModal(`
        <button class="icon-btn modal-close" id="modalClose" aria-label="إغلاق">✕</button>
        <h2>محاولات كتير</h2>
        <p style="color:var(--text-soft)">حاولت كتير في وقت قصير — استنى شوية وحاول تاني.</p>
        <button class="btn btn-primary btn-block" id="retryOrder">حاول تاني</button>`);
      $('#retryOrder').addEventListener('click', () => showReview(customer));
      return;
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
        <h2>طلبك اتأكد! ✅</h2>
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
  revealObserver = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add('in'); revealObserver.unobserve(e.target); }
    });
  }, { threshold: 0.12 });
  document.querySelectorAll('.reveal:not(.in), .product:not(.in)').forEach((el) => revealObserver.observe(el));
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
  if (catLink) { filter = catLink.dataset.catLink; gridExpanded = false; renderPills(); renderProducts(); document.querySelector('#featured')?.scrollIntoView({ behavior: 'smooth' }); return; }
  const pill = e.target.closest('[data-filter]');
  if (pill) { filter = pill.dataset.filter; gridExpanded = false; renderPills(); renderProducts(); return; }
  const cat = e.target.closest('[data-cat]');
  if (cat) { filter = cat.dataset.cat; gridExpanded = false; renderPills(); renderProducts(); recordStep('category'); return; }
  const prod = e.target.closest('.product');
  if (prod) { openProduct(prod.dataset.id); return; }
  const inc = e.target.closest('[data-inc]');
  if (inc) return changeQty(inc.dataset.inc, 1);
  const dec = e.target.closest('[data-dec]');
  if (dec) return changeQty(dec.dataset.dec, -1);
  const rm = e.target.closest('[data-remove]');
  if (rm) { delete cart[rm.dataset.remove]; renderCart(); return; }
  if (e.target.closest('#modalClose')) { closeModal(); return; }
  if (e.target === $('#modal')) { closeModal(); return; }
});
$('#cartToggle').addEventListener('click', () => openCart(true));
$('#cartClose').addEventListener('click', () => openCart(false));
$('#scrim').addEventListener('click', () => openCart(false));
$('#checkoutBtn').addEventListener('click', () => {
  if (cartLines().length === 0) { toast('السلة فارغة حالياً'); return; }
  recordStep('checkout');
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
    { startedAt: serverTimestamp(), ordered: false }, { merge: true }).catch(() => {});
  openCart(false);
  showInfoForm();
});
$('#searchToggle').addEventListener('click', () => {
  const bar = $('#searchBar');
  bar.classList.toggle('open');
  if (bar.classList.contains('open')) $('#searchInput').focus();
});
$('#searchInput').addEventListener('input', (e) => {
  searchQuery = e.target.value.trim().toLowerCase();
  gridExpanded = false;
  renderProducts();
});
$('#themeToggle').addEventListener('click', () => {
  theme = theme === 'dark' ? 'light' : 'dark';
  applyTheme();
});

/* ---------- feedback: "Contact us" (CUJ 6) ---------- */
/* The storefront form calls the submitFeedback callable (rate-limited,
 * duplicate-checked server-side, returns a tracking code) and the
 * lookup calls getFeedbackStatus (tracking code + phone). The
 * function never says which part failed — the lookup shows one
 * generic "not found" message either way. */
const FEEDBACK_STATUS_LABELS = { new: 'جديدة', in_review: 'قيد المراجعة', awaiting_customer: 'بانتظار العميل', resolved: 'تم الحل', closed: 'مغلقة', rejected: 'مرفوضة', spam: 'سبام' };
function newSubmissionId() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID();
  return 'fb_' + Math.random().toString(36).slice(2) + Date.now().toString(36);
}
async function submitFeedbackForm(e) {
  if (e && e.preventDefault) e.preventDefault();
  const resultEl = $('#fbResult');
  const showResult = (msg, ok) => {
    if (!resultEl) return;
    resultEl.hidden = false;
    resultEl.textContent = msg;
    resultEl.style.color = ok ? 'var(--accent)' : '#c0392b';
  };
  const type = (($('#fbType') || {}).value || 'complaint');
  const category = (($('#fbCategory') || {}).value || 'other');
  const title = (($('#fbTitle') || {}).value || '').trim();
  const message = (($('#fbMessage') || {}).value || '').trim();
  const orderId = (($('#fbOrderId') || {}).value || '').trim();
  const phone = (($('#fbPhone') || {}).value || '').trim();
  if (title.length === 0 || title.length > 100) return showResult('اكتب عنوان من سطر واحد (لحد 100 حرف)');
  if (message.length < 10 || message.length > 2000) return showResult('اكتب رسالتك (من 10 لـ 2000 حرف)');
  if (phone.replace(/\D/g, '').length < 10) return showResult('اكتب رقم موبايل صحيح — هنحتاجه عشان تتابع الشكوى');
  const btn = $('#fbSubmit');
  if (btn) btn.disabled = true;
  try {
    const res = await submitFeedbackCallable({
      submissionId: newSubmissionId(),
      type, category, title, message,
      orderId: orderId || null,
      phone,
    });
    const data = (res && res.data) || {};
    if (data.trackingCode) {
      showResult(data.duplicate
        ? `الشكوى دي اتبعتت قبل كده — كود التتبع بتاعها: ${data.trackingCode}`
        : `تم استلام رسالتك! كود التتبع بتاعك: ${data.trackingCode} — احتفظ بيه عشان تتابع الحالة`, true);
      const form = $('#fbForm');
      if (form && form.reset) form.reset();
    } else {
      showResult('حصلت مشكلة — حاول تاني');
    }
  } catch (err) {
    const code = (err && err.details && err.details.code) || '';
    showResult(code === 'RATE_LIMITED' ? 'محاولات كتير — استنى شوية وحاول تاني'
      : code === 'BLOCKED' ? 'الإرسال من الرقم ده موقوف مؤقتاً'
      : 'حصلت مشكلة — حاول تاني');
  } finally {
    if (btn) btn.disabled = false;
  }
}
async function lookupFeedback() {
  const resultEl = $('#fbLookupResult');
  const showResult = (msg, ok) => {
    if (!resultEl) return;
    resultEl.hidden = false;
    resultEl.textContent = msg;
    resultEl.style.color = ok ? 'var(--accent)' : '#c0392b';
  };
  const code = (($('#fbLookupCode') || {}).value || '').trim();
  const phone = (($('#fbLookupPhone') || {}).value || '').trim();
  if (!code || phone.replace(/\D/g, '').length < 10) return showResult('اكتب كود التتبع ورقم الموبايل');
  try {
    const res = await getFeedbackStatusCallable({ trackingCode: code, phone });
    const data = (res && res.data) || {};
    const label = FEEDBACK_STATUS_LABELS[data.status] || data.status || '';
    showResult(`الحالة: ${label}${data.lastReply ? ` — آخر رد: ${data.lastReply}` : ''}`, true);
  } catch (_) {
    showResult('مفيش شكوى بالكود ده — اتأكد من الكود ورقم الموبايل');
  }
}
const fbForm = $('#fbForm');
if (fbForm) fbForm.addEventListener('submit', submitFeedbackForm);
const fbLookupBtn = $('#fbLookupBtn');
if (fbLookupBtn) fbLookupBtn.addEventListener('click', lookupFeedback);
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

/* ---------- boot ---------- */
$('#year').textContent = new Date().getFullYear();
applyTheme();
renderCart();
/* Named (not an IIFE) so the boot-error retry button can re-run it. */
async function boot() {
  try {
    const sSnap = await getDoc(doc(db, 'storeSettings', 'settings'));
    if (sSnap.exists()) {
      const d = sSnap.data();
      // Brand slot: settings brandName when set, else neutral "المتجر".
      if (d.brandName) window.__brandName = d.brandName;
      if (d.tagline) window.__brandTag = d.tagline;
      // Logo mark: settings logoImageUrl when set (non-empty), else pulse SVG.
      if (typeof d.logoImageUrl === 'string' && d.logoImageUrl.trim()) window.__logoImageUrl = d.logoImageUrl.trim();
    }
  } catch (_) {}
  try {
    const hSnap = await getDoc(doc(db, 'storeSettings', 'homepage'));
    if (hSnap.exists() && hSnap.data()) homepage = hSnap.data();
  } catch (_) {}
  try {
    const dSnap = await getDoc(doc(db, 'storeSettings', 'design'));
    if (dSnap.exists() && dSnap.data()) design = dSnap.data();
  } catch (_) {}
  /* Active template (pointer -> template doc -> classic.json ->
   * built-in classic). Loaded before applyDesign so the template's
   * section toggles apply with the design toggles. */
  await loadActiveTemplate();
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
  applyBrand();
  applyDesign();
  applyLogoMark();
  applyHero();
  renderAll();
  observeReveals();
}
boot();
