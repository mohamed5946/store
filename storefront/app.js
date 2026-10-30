// Store storefront — vanilla JS + Firestore. Mobile-first, COD only.
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
let activeCat = 'all';
let cart = {}; // id -> qty
let attemptId = null;

const $ = (id) => document.getElementById(id);
const money = (n) => Number(n || 0).toFixed(0);

// Cloudinary auto-optimization: every Cloudinary image is served with
// f_auto,q_auto so the storefront loads fast. Pasted links pass through.
function deliveryUrl(u) {
  if (!u || !u.includes('res.cloudinary.com') || u.includes('f_auto')) return u;
  return u.replace('/upload/', '/upload/f_auto,q_auto/');
}

function productImage(p) {
  const imgs = p.images || [];
  if (imgs.length > 0 && imgs[0].url) return `<img src="${deliveryUrl(imgs[0].url)}" alt="">`;
  if (p.imageUrl) return `<img src="${p.imageUrl}" alt="" onerror="this.remove()">`;
  const initial = (p.name || '?').trim().charAt(0);
  return initial;
}

function galleryHtml(p) {
  const imgs = (p.images || []).filter((i) => i && i.url);
  if (imgs.length === 0 && p.imageUrl) imgs.push({ url: p.imageUrl });
  if (imgs.length === 0) return '';
  const main = `<div id="galMain" style="aspect-ratio:1;border-radius:14px;overflow:hidden;background:linear-gradient(135deg,#0a84ff,#64d2ff)"><img src="${deliveryUrl(imgs[0].url)}" style="width:100%;height:100%;object-fit:cover"></div>`;
  if (imgs.length === 1) return main;
  const thumbs = imgs.map((im, i) =>
    `<img src="${deliveryUrl(im.url)}" data-gal="${i}" style="width:64px;height:64px;object-fit:cover;border-radius:10px;cursor:pointer;border:2px solid ${i === 0 ? '#0a84ff' : '#eee'}">`).join('');
  return main + `<div style="display:flex;gap:8px;margin-top:10px">${thumbs}</div>`;
}

// ---------- brand + catalog ----------
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

function renderCats() {
  const el = $('cats');
  const chips = [{ id: 'all', name: 'الكل' }, ...categories];
  el.innerHTML = chips.map((c) =>
    `<button class="chip ${c.id === activeCat ? 'active' : ''}" data-cat="${c.id}">${c.name}</button>`).join('');
  el.querySelectorAll('.chip').forEach((b) => b.addEventListener('click', () => {
    activeCat = b.dataset.cat;
    if (activeCat !== 'all') recordStep('category');
    renderCats(); renderGrid();
  }));
}

function renderGrid() {
  const list = products.filter((p) => activeCat === 'all' || p.categoryId === activeCat);
  $('grid').innerHTML = list.length === 0
    ? '<p style="grid-column:1/-1;text-align:center;color:#86868b">مفيش منتجات في القسم ده لسه</p>'
    : list.map((p) => `
      <div class="card" data-id="${p.id}">
        <div class="img">${productImage(p)}</div>
        <div class="body">
          <div class="name">${p.name}</div>
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
    <h2>${p.name}</h2>
    <p style="color:#0a84ff;font-weight:800;font-size:20px">${money(p.price)} ج.م</p>
    <p>${p.description || ''}</p>
    <button class="primary" id="modalAdd">أضف للسلة</button>
    <button class="secondary" id="modalClose">إغلاق</button>`;
  $('modal').classList.add('open');
  document.querySelectorAll('[data-gal]').forEach((t) => t.addEventListener('click', () => {
    const imgs = (p.images || []).filter((i) => i && i.url);
    const main = $('galMain');
    if (main && imgs[t.dataset.gal]) main.innerHTML = `<img src="${deliveryUrl(imgs[t.dataset.gal].url)}" style="width:100%;height:100%;object-fit:cover">`;
    document.querySelectorAll('[data-gal]').forEach((x) => x.style.borderColor = '#eee');
    t.style.borderColor = '#0a84ff';
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
        <span>${l.name}</span>
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
    <p style="color:#86868b">الدفع عند الاستلام — مفيش دفع أونلاين</p>
    <input id="fName" placeholder="الاسم بالكامل">
    <input id="fPhone" placeholder="رقم الموبايل" inputmode="tel">
    <textarea id="fAddr" placeholder="العنوان بالتفصيل" rows="3"></textarea>
    ${err ? `<p class="err">${err}</p>` : ''}
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

function showReview(customer) {
  const lines = cartLines();
  $('modalSheet').innerHTML = `
    <h2>مراجعة الطلب</h2>
    <p>الاسم: ${customer.name}</p>
    <p>الموبايل: ${customer.phone}</p>
    <p>العنوان: ${customer.addr}</p>
    <hr>
    ${lines.map((l) => `<p>${l.name} × ${l.qty} = ${money(l.price * l.qty)} ج.م</p>`).join('')}
    <p><strong>الإجمالي: ${money(cartTotal())} ج.م — الدفع عند الاستلام</strong></p>
    <p class="err" id="orderErr"></p>
    <button class="primary" id="confirmOrder">تأكيد الطلب</button>
    <button class="secondary" id="backToForm">تعديل البيانات</button>`;
  $('backToForm').addEventListener('click', () => showInfoForm());
  $('confirmOrder').addEventListener('click', async () => {
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
      $('modalSheet').innerHTML = `<div class="ok"><h2>تم استلام طلبك بنجاح</h2><p>هنكلمك قريب لتأكيد التوصيل — والدفع عند الاستلام.</p><button class="primary" id="doneBtn">تمام</button></div>`;
      $('doneBtn').addEventListener('click', closeModal);
    } catch (e) {
      $('orderErr').textContent = 'تعذر إرسال الطلب — حاول تاني';
    }
  });
}

// ---------- boot ----------
(async () => {
  await loadBrand();
  try {
    const catsSnap = await getDocs(query(collection(db, 'categories'), orderBy('createdAt')));
    categories = catsSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
    const prodsSnap = await getDocs(query(collection(db, 'products'), orderBy('createdAt')));
    products = prodsSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
  } catch (_) {}
  renderCats(); renderGrid();
})();
