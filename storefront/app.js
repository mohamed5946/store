// Store storefront — vanilla JS + Firestore. Mobile-first, COD only, dark SOVA-style theme.
//
// ANALYTICS BOUNDARY (hard requirement): a visitor's contact info is saved
// to a checkout attempt ONLY after they complete the info step (press
// "مراجعة الطلب" with valid data). Opening checkout, or typing without
// completing the step, never stores any contact info. Sessions are
// anonymous (random localStorage id, no personal data).
import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js';
import {
  getFirestore, collection, doc, getDoc, getDocs, setDoc, updateDoc,
  addDoc, serverTimestamp, arrayUnion, query, orderBy,
} from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js';

const app = initializeApp(window.STORE_FIREBASE_CONFIG);
const db = getFirestore(app);

// ---------- anonymous session + funnel ----------
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

// ---------- state ----------
let categories = [];
let products = [];
let homepage = {};
let activeCat = 'all';
let cart = {}; // id -> qty
let attemptId = null;
let heroIdx = 0;
let heroTimer = null;

const $ = (id) => document.getElementById(id);
const money = (n) => Number(n || 0).toFixed(0);
const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

// Cloudinary auto-optimization: every Cloudinary image is served with
// f_auto,q_auto so the storefront loads fast. Pasted links pass through.
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

function productImage(p) {
  const url = coverUrl(p);
  if (url) return `<img src="${url}" alt="" onerror="this.remove()">`;
  const initial = (p.name || '?').trim().charAt(0);
  return esc(initial);
}

function galleryHtml(p) {
  const imgs = (p.images || []).filter((i) => i && i.url);
  if (imgs.length === 0 && p.imageUrl) imgs.push({ url: p.imageUrl });
  if (imgs.length === 0) return '';
  const main = `<div id="galMain" style="aspect-ratio:1;border-radius:14px;overflow:hidden;background:linear-gradient(135deg,#ff5a3c,#ff8a3d)"><img src="${deliveryUrl(imgs[0].url)}" style="width:100%;height:100%;object-fit:cover"></div>`;
  if (imgs.length === 1) return main;
  const thumbs = imgs.map((im, i) =>
    `<img src="${deliveryUrl(im.url)}" data-gal="${i}" style="width:64px;height:64px;object-fit:cover;border-radius:10px;cursor:pointer;border:2px solid ${i === 0 ? '#ff5a3c' : '#2a2a2e'}">`).join('');
  return main + `<div style="display:flex;gap:8px;margin-top:10px">${thumbs}</div>`;
}

function catName(id) {
  const c = categories.find((x) => x.id === id);
  return c ? c.name : '';
}

// ---------- brand + catalog + homepage ----------
async function loadBrand() {
  try {
    const snap = await getDoc(doc(db, 'storeSettings', 'settings'));
    if (snap.exists()) {
      const d = snap.data();
      if (d.brandName) { $('brand').textContent = d.brandName; $('footerBrand').textContent = d.brandName; document.title = d.brandName; }
      if (d.tagline) $('tagline').textContent = d.tagline;
    }
  } catch (_) {}
}

async function loadHomepage() {
  try {
    const snap = await getDoc(doc(db, 'storeSettings', 'homepage'));
    if (snap.exists() && snap.data()) homepage = snap.data();
  } catch (_) { homepage = {}; }
}

// Homepage content resolution — EXACT schema the app editor writes:
// { heroProductIds: string[] (max 4, ordered),
//   promoBanners: [{imageUrl, title, subtitle, linkType: 'category'|'product'|'none', linkId}],
//   featuredProductId: string,
//   deliveryBanner: {title, subtitle, imageUrl} }
// Every field is optional: missing fields fall back to real products so the
// site always looks complete. Only the store's own images are ever used.
function heroProducts() {
  const ids = Array.isArray(homepage.heroProductIds) ? homepage.heroProductIds : [];
  const picked = ids.map((id) => products.find((p) => p.id === id)).filter(Boolean).slice(0, 4);
  if (picked.length > 0) return picked;
  return products.slice(0, 4);
}
function featuredProduct() {
  if (typeof homepage.featuredProductId === 'string') {
    const f = products.find((p) => p.id === homepage.featuredProductId);
    if (f) return f;
  }
  return products[0] || null;
}
function promoBanners() {
  const list = Array.isArray(homepage.promoBanners) ? homepage.promoBanners : [];
  const valid = list.filter((b) => b && typeof b.title === 'string').slice(0, 2);
  if (valid.length > 0) return valid;
  return products.slice(0, 2).map((p) => ({
    imageUrl: coverUrl(p), title: p.name, subtitle: `${money(p.price)} ج.م`,
    linkType: 'product', linkId: p.id,
  }));
}
function deliveryBanner() {
  const d = (homepage.deliveryBanner && typeof homepage.deliveryBanner === 'object') ? homepage.deliveryBanner : {};
  return {
    title: typeof d.title === 'string' && d.title ? d.title : 'الدفع عند الاستلام',
    subtitle: typeof d.subtitle === 'string' && d.subtitle ? d.subtitle : 'ادفع كاش لما طلبك يوصلك لحد البيت — من غير أي دفع أونلاين',
    imageUrl: typeof d.imageUrl === 'string' ? d.imageUrl : '',
  };
}

// ---------- sections ----------
function renderCats() {
  const el = $('cats');
  const chips = [{ id: 'all', name: 'الكل' }, ...categories];
  el.innerHTML = chips.map((c) =>
    `<button class="chip ${c.id === activeCat ? 'active' : ''}" data-cat="${c.id}">${esc(c.name)}</button>`).join('');
  el.querySelectorAll('.chip').forEach((b) => b.addEventListener('click', () => {
    activeCat = b.dataset.cat;
    if (activeCat !== 'all') recordStep('category');
    renderCats(); renderGrid();
  }));
}

function setFilter(catId) {
  activeCat = catId;
  if (activeCat !== 'all') recordStep('category');
  renderCats(); renderGrid();
  document.querySelector('#grid').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function renderHero() {
  const slides = heroProducts();
  const el = $('hero');
  if (slides.length === 0) { el.innerHTML = ''; return; }
  if (heroTimer) clearInterval(heroTimer);
  heroIdx = 0;
  const slideHtml = (p, i) => `
    <div class="hero-slide ${i === 0 ? 'active' : ''}">
      <p class="hero-eyebrow">${esc(catName(p.categoryId) || 'منتج مميز')}</p>
      <h2>${esc(p.name)}</h2>
      <p class="hero-price">${money(p.price)} ج.م</p>
      ${coverUrl(p) ? `<img class="hero-img" src="${coverUrl(p)}" alt="" onerror="this.remove()">` : ''}
      <div class="hero-actions">
        <button class="primary" data-hero-add="${p.id}">أضف للسلة</button>
        <button class="ghost" data-hero-open="${p.id}">التفاصيل</button>
      </div>
    </div>`;
  el.innerHTML = `
    <button class="hero-arrow next" aria-label="التالي">›</button>
    <button class="hero-arrow prev" aria-label="السابق">‹</button>
    ${slides.map(slideHtml).join('')}
    <div class="hero-dots">${slides.map((_, i) => `<button data-dot="${i}" class="${i === 0 ? 'on' : ''}" aria-label="شريحة ${i + 1}"></button>`).join('')}</div>`;
  const show = (i) => {
    heroIdx = (i + slides.length) % slides.length;
    el.querySelectorAll('.hero-slide').forEach((s, j) => s.classList.toggle('active', j === heroIdx));
    el.querySelectorAll('[data-dot]').forEach((d, j) => d.classList.toggle('on', j === heroIdx));
  };
  const restart = () => {
    if (heroTimer) clearInterval(heroTimer);
    if (slides.length > 1) heroTimer = setInterval(() => show(heroIdx + 1), 4500);
  };
  el.querySelector('.hero-arrow.next').addEventListener('click', () => { show(heroIdx + 1); restart(); });
  el.querySelector('.hero-arrow.prev').addEventListener('click', () => { show(heroIdx - 1); restart(); });
  el.querySelectorAll('[data-dot]').forEach((d) => d.addEventListener('click', () => { show(+d.dataset.dot); restart(); }));
  el.querySelectorAll('[data-hero-add]').forEach((b) => b.addEventListener('click', () => {
    cart[b.dataset.heroAdd] = (cart[b.dataset.heroAdd] || 0) + 1;
    updateCartBadge();
  }));
  el.querySelectorAll('[data-hero-open]').forEach((b) => b.addEventListener('click', () => openProduct(b.dataset.heroOpen)));
  restart();
}

function renderFeatured() {
  const p = featuredProduct();
  const el = $('featured');
  if (!p) { el.innerHTML = ''; return; }
  el.innerHTML = `
    <div class="feat-card" data-feat="${p.id}">
      ${coverUrl(p) ? `<img src="${coverUrl(p)}" alt="" onerror="this.remove()">` : ''}
      <div class="feat-body">
        <p class="eyebrow">منتج الشهر</p>
        <h3>${esc(p.name)}</h3>
        ${p.description ? `<p>${esc(p.description)}</p>` : ''}
        <div class="feat-price">${money(p.price)} ج.م</div>
        <div style="display:flex;gap:10px">
          <button class="primary" style="margin-top:0" data-feat-add="${p.id}">أضف للسلة</button>
          <button class="ghost" data-feat-open="${p.id}">التفاصيل</button>
        </div>
      </div>
    </div>`;
  el.querySelector('[data-feat-add]').addEventListener('click', (e) => {
    e.stopPropagation();
    cart[p.id] = (cart[p.id] || 0) + 1;
    updateCartBadge();
  });
  el.querySelector('[data-feat-open]').addEventListener('click', () => openProduct(p.id));
  el.querySelector('.feat-card').addEventListener('click', (e) => {
    if (e.target.closest('button')) return;
    openProduct(p.id);
  });
}

function renderCatGrid() {
  const el = $('catGrid');
  if (categories.length === 0) { el.innerHTML = ''; return; }
  el.innerHTML = categories.map((c) => {
    const count = products.filter((p) => p.categoryId === c.id).length;
    const initial = (c.name || '?').trim().charAt(0);
    return `<div class="cat-tile" data-tile-cat="${c.id}">
      <div class="initial">${esc(initial)}</div>
      <div class="cname">${esc(c.name)}</div>
      <div class="ccount">${count} منتج</div>
    </div>`;
  }).join('');
  el.querySelectorAll('[data-tile-cat]').forEach((t) => t.addEventListener('click', () => setFilter(t.dataset.tileCat)));
}

function renderPromos() {
  const banners = promoBanners();
  const el = $('promos');
  if (banners.length === 0) { el.innerHTML = ''; return; }
  el.innerHTML = banners.map((b) => `
    <div class="promo" data-link-type="${esc(b.linkType || 'none')}" data-link-id="${esc(b.linkId || '')}">
      ${b.imageUrl ? `<img src="${deliveryUrl(b.imageUrl)}" alt="" onerror="this.remove()">` : ''}
      <div class="shade"></div>
      <div class="txt">
        <h3>${esc(b.title)}</h3>
        ${b.subtitle ? `<p>${esc(b.subtitle)}</p>` : ''}
        <span class="cta">تسوق الآن</span>
      </div>
    </div>`).join('');
  el.querySelectorAll('.promo').forEach((pr) => pr.addEventListener('click', () => {
    const type = pr.dataset.linkType, id = pr.dataset.linkId;
    if (type === 'category' && categories.some((c) => c.id === id)) setFilter(id);
    else if (type === 'product' && products.some((p) => p.id === id)) openProduct(id);
  }));
}

function renderDelivery() {
  const d = deliveryBanner();
  $('deliveryBand').innerHTML = `
    <h3>${esc(d.title)}</h3>
    <p>${esc(d.subtitle)}</p>
    ${d.imageUrl ? `<img class="band-img" src="${deliveryUrl(d.imageUrl)}" alt="" onerror="this.remove()">` : ''}`;
}

function renderGrid() {
  const list = products.filter((p) => activeCat === 'all' || p.categoryId === activeCat);
  $('grid').innerHTML = list.length === 0
    ? '<p style="grid-column:1/-1;text-align:center;color:#a1a1aa">مفيش منتجات في القسم ده لسه</p>'
    : list.map((p) => `
      <div class="card" data-id="${p.id}">
        <div class="img">${productImage(p)}</div>
        <div class="body">
          <div class="name">${esc(p.name)}</div>
          <div class="price">${money(p.price)} ج.م</div>
          <button class="add" data-add="${p.id}">أضف للسلة</button>
        </div>
      </div>`).join('');
  document.querySelectorAll('[data-add]').forEach((b) => b.addEventListener('click', (e) => {
    e.stopPropagation();
    cart[b.dataset.add] = (cart[b.dataset.add] || 0) + 1;
    updateCartBadge();
  }));
  document.querySelectorAll('.card[data-id]').forEach((c) => c.addEventListener('click', () => openProduct(c.dataset.id)));
}

function openProduct(id) {
  const p = products.find((x) => x.id === id);
  if (!p) return;
  recordStep('product');
  $('modalSheet').innerHTML = `
    ${galleryHtml(p)}
    <h2>${esc(p.name)}</h2>
    <p style="color:#ff8a3d;font-weight:800;font-size:20px">${money(p.price)} ج.م</p>
    <p>${esc(p.description || '')}</p>
    <button class="primary" id="modalAdd">أضف للسلة</button>
    <button class="secondary" id="modalClose">إغلاق</button>`;
  $('modal').classList.add('open');
  document.querySelectorAll('[data-gal]').forEach((t) => t.addEventListener('click', () => {
    const imgs = (p.images || []).filter((i) => i && i.url);
    const main = $('galMain');
    if (main && imgs[t.dataset.gal]) main.innerHTML = `<img src="${deliveryUrl(imgs[t.dataset.gal].url)}" style="width:100%;height:100%;object-fit:cover">`;
    document.querySelectorAll('[data-gal]').forEach((x) => x.style.borderColor = '#2a2a2e');
    t.style.borderColor = '#ff5a3c';
  }));
  $('modalAdd').addEventListener('click', () => { cart[id] = (cart[id] || 0) + 1; updateCartBadge(); closeModal(); openDrawer(); });
  $('modalClose').addEventListener('click', closeModal);
}
function closeModal() { $('modal').classList.remove('open'); }
$('modal').addEventListener('click', (e) => { if (e.target.id === 'modal') closeModal(); });

// ---------- cart drawer ----------
function cartLines() {
  return Object.entries(cart).map(([id, qty]) => {
    const p = products.find((x) => x.id === id);
    return p ? { ...p, qty } : null;
  }).filter(Boolean);
}
function cartTotal() { return cartLines().reduce((n, l) => n + l.price * l.qty, 0); }
function updateCartBadge() {
  $('cartCount').textContent = Object.values(cart).reduce((n, q) => n + q, 0);
}
function openDrawer() {
  recordStep('cart');
  const lines = cartLines();
  $('cartLines').innerHTML = lines.length === 0
    ? '<p>السلة فاضية</p>'
    : lines.map((l) => `
      <div class="line">
        <span>${esc(l.name)}</span>
        <span class="qty">
          <button data-dec="${l.id}">−</button> ${l.qty}
          <button data-inc="${l.id}">+</button>
        </span>
        <span>${money(l.price * l.qty)} ج.م</span>
      </div>`).join('');
  $('cartTotal').textContent = money(cartTotal());
  $('drawer').classList.add('open');
  document.querySelectorAll('[data-inc]').forEach((b) => b.addEventListener('click', () => { cart[b.dataset.inc]++; updateCartBadge(); openDrawer(); }));
  document.querySelectorAll('[data-dec]').forEach((b) => b.addEventListener('click', () => {
    cart[b.dataset.dec]--;
    if (cart[b.dataset.dec] <= 0) delete cart[b.dataset.dec];
    updateCartBadge(); openDrawer();
  }));
}
function closeDrawer() { $('drawer').classList.remove('open'); }
$('cartBtn').addEventListener('click', openDrawer);
$('closeDrawer').addEventListener('click', closeDrawer);

// ---------- checkout (COD, two steps) ----------
$('toCheckout').addEventListener('click', () => {
  if (cartLines().length === 0) return;
  recordStep('checkout');
  closeDrawer();
  // Attempt doc is created WITHOUT any contact info. Contact is added
  // only when the info step is completed (review button), never before.
  attemptId = 'a_' + Math.random().toString(36).slice(2) + Date.now().toString(36);
  setDoc(doc(db, 'analytics', 'attempts', 'items', attemptId),
    { startedAt: serverTimestamp(), ordered: false }, { merge: true }).catch(() => {});
  showInfoForm();
});

function showInfoForm(err = '') {
  $('modalSheet').innerHTML = `
    <h2>بيانات التوصيل</h2>
    <p style="color:#a1a1aa">الدفع عند الاستلام — مفيش دفع أونلاين</p>
    <input id="fName" placeholder="الاسم بالكامل">
    <input id="fPhone" placeholder="رقم الموبايل" inputmode="tel">
    <textarea id="fAddr" placeholder="العنوان بالتفصيل" rows="3"></textarea>
    ${err ? `<p class="err">${esc(err)}</p>` : ''}
    <button class="primary" id="toReview">مراجعة الطلب</button>
    <button class="secondary" id="formClose">إلغاء</button>`;
  $('modal').classList.add('open');
  $('formClose').addEventListener('click', closeModal);
  $('toReview').addEventListener('click', () => {
    const name = $('fName').value.trim();
    const phone = $('fPhone').value.trim();
    const addr = $('fAddr').value.trim();
    const digits = phone.replace(/\D/g, '');
    if (!name) return showInfoForm('اكتب اسمك');
    if (digits.length < 10) return showInfoForm('رقم الموبايل مش كامل');
    if (!addr) return showInfoForm('اكتب العنوان');
    // Info step COMPLETED here — only now may contact info be saved.
    updateDoc(doc(db, 'analytics', 'attempts', 'items', attemptId),
      { contactName: name, contactPhone: phone, contactAddress: addr }).catch(() => {});
    showReview({ name, phone, addr });
  });
}

// Order journey animation — PRESENTATION ONLY. The order doc is created
// exactly once below, before the animation starts. On failure the real
// error shows and no animation (never a fake success). Tappable to skip.
function showJourney(onDone) {
  const j = $('journey');
  j.classList.remove('journey-run');
  void j.offsetWidth; // restart CSS animations
  j.classList.add('open', 'journey-run');
  let done = false;
  const finish = () => {
    if (done) return;
    done = true;
    clearTimeout(timer);
    j.classList.remove('open', 'journey-run');
    onDone();
  };
  const timer = setTimeout(finish, 2500);
  $('jSkip').onclick = finish;
}

function showReview(customer) {
  const lines = cartLines();
  $('modalSheet').innerHTML = `
    <h2>مراجعة الطلب</h2>
    <p>الاسم: ${esc(customer.name)}</p>
    <p>الموبايل: ${esc(customer.phone)}</p>
    <p>العنوان: ${esc(customer.addr)}</p>
    <hr style="border-color:#2a2a2e">
    ${lines.map((l) => `<p>${esc(l.name)} × ${l.qty} = ${money(l.price * l.qty)} ج.م</p>`).join('')}
    <p><strong>الإجمالي: ${money(cartTotal())} ج.م — الدفع عند الاستلام</strong></p>
    <p class="err" id="orderErr"></p>
    <button class="primary" id="confirmOrder">تأكيد الطلب</button>
    <button class="secondary" id="backToForm">تعديل البيانات</button>`;
  $('backToForm').addEventListener('click', () => showInfoForm());
  let ordering = false;
  $('confirmOrder').addEventListener('click', async () => {
    if (ordering) return;
    ordering = true;
    const btn = $('confirmOrder');
    btn.disabled = true;
    btn.textContent = 'جارٍ إرسال الطلب…';
    try {
      await addDoc(collection(db, 'orders'), {
        customerName: customer.name,
        customerPhone: customer.phone,
        customerAddress: customer.addr,
        items: lines.map((l) => ({ id: l.id, name: l.name, price: l.price, qty: l.qty })),
        total: cartTotal(),
        status: 'new',
        createdAt: serverTimestamp(),
      });
      await updateDoc(doc(db, 'analytics', 'attempts', 'items', attemptId), { ordered: true }).catch(() => {});
      recordStep('order');
      cart = {}; updateCartBadge();
      ordering = false;
      showJourney(() => {
        $('modalSheet').innerHTML = `<div class="ok"><h2>تم استلام طلبك بنجاح</h2><p>هنكلمك قريب لتأكيد التوصيل — والدفع عند الاستلام.</p><button class="primary" id="doneBtn">تمام</button></div>`;
        $('doneBtn').addEventListener('click', closeModal);
      });
    } catch (e) {
      ordering = false;
      btn.disabled = false;
      btn.textContent = 'تأكيد الطلب';
      $('orderErr').textContent = 'تعذر إرسال الطلب — حاول تاني';
    }
  });
}

// ---------- boot ----------
(async () => {
  await loadBrand();
  await loadHomepage();
  try {
    const catsSnap = await getDocs(query(collection(db, 'categories'), orderBy('createdAt')));
    categories = catsSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
    const prodsSnap = await getDocs(query(collection(db, 'products'), orderBy('createdAt')));
    products = prodsSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
  } catch (_) {}
  renderCats(); renderHero(); renderFeatured(); renderCatGrid(); renderPromos(); renderDelivery(); renderGrid();
})();
