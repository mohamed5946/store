/* Phase 2 proving tests (design doc file 33, test plan T1–T24).
 *
 * TWO parts, one file:
 *  (A) Storefront tests — run the REAL storefront/app.js in a vm context
 *      with stubbed Firebase (in-memory Firestore + a stubbed
 *      placeOrder callable), stubbed DOM/localStorage/timers, no network.
 *      app.js is a browser ES module with CDN Firebase imports, so the
 *      harness rewrites ONLY the three import statements into
 *      destructuring from a stub object (__firebase). Every other line of
 *      app.js runs unmodified. Test state is driven through hook code
 *      appended in the SAME evaluated scope (it can reach the
 *      module-level `products`, `cart`, `clientOrderId`, `submitOrder`,
 *      `showReview`, `cartLines`, `cartTotal` directly). No test hook
 *      exists in app.js itself.
 *  (B) Function tests — run the REAL functions/lib code
 *      (createOrderTx, releaseReservationTx, isAllowedTransition,
 *      sweepExpiredReservations) against the in-memory fake Firestore
 *      (functions/test/fake-firestore.js). The lib takes `serverTimestamp`
 *      as an injected function returning a plain ms number in tests.
 *
 * No npm dependencies beyond the repo's own: only Node builtins
 * (node:test, node:assert/strict, fs, vm) + the fake. Run from the
 * repo root:
 *   node --test functions/test/orders.test.js
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const APP_PATH = path.join(__dirname, '..', '..', 'storefront', 'app.js');
const { createFakeFirestore } = require('./fake-firestore');
const { createOrderTx, releaseReservationTx, isAllowedTransition } = require('../lib/orders');
const { sweepExpiredReservations } = require('../lib/sweep');

const PRODUCTS = [
  { id: 'prod-1', name: 'سماعة بلوتوث', price: 500, categoryId: 'cat-1' },
  { id: 'prod-2', name: 'شاحن سريع', price: 250, categoryId: 'cat-1' },
];
const CART = { 'prod-1': 2, 'prod-2': 1 }; // total: 2*500 + 1*250 = 1250
const CUSTOMER = { name: 'اختبار', phone: '01012345678', addr: 'عنوان اختبار' };
const FIXED_UUID = '11111111-2222-4333-8444-555555555555';
const NOW = 1793000000000; // fixed "now" (ms) for the function tests

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Objects created inside the vm context have a different realm prototype,
// so assert.deepEqual (strict) rejects them even when the values match.
// Normalize through JSON before comparing.
const plain = (v) => JSON.parse(JSON.stringify(v));

/* ================= (A) storefront harness ================= */

/* ---------- localStorage stub ---------- */
function createLocalStorage() {
  const map = new Map();
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => { map.set(k, String(v)); },
    removeItem: (k) => { map.delete(k); },
    clear: () => { map.clear(); },
  };
}

/* ---------- DOM element stub ---------- */
function makeElement(selector, getElement) {
  const listeners = {};
  const el = {
    _selector: selector,
    textContent: '',
    innerHTML: '',
    value: '',
    hidden: false,
    disabled: false,
    dataset: {},
    // Phase 3: CSS custom properties set by applyTemplate are
    // recorded here so tests can assert which tokens were applied.
    style: {
      _vars: {},
      setProperty(k, v) { this._vars[k] = v; },
      getPropertyValue(k) { return this._vars[k] || ''; },
    },
    offsetWidth: 0,
    onclick: null,
    classList: {
      add() {}, remove() {}, toggle() {}, contains() { return false; },
    },
    setAttribute() {},
    getAttribute() { return null; },
    addEventListener(type, fn) { (listeners[type] ??= []).push(fn); },
    removeEventListener() {},
    appendChild() {},
    focus() {},
    click() {},
    scrollIntoView() {},
    querySelector: (sel) => getElement(sel),
    querySelectorAll: () => [],
    closest: () => null,
    __fire(type, event = {}) {
      for (const fn of (listeners[type] || [])) fn(event);
    },
  };
  return el;
}

/* ---------- fake in-memory Firestore (storefront side) ---------- */
function createStorefrontFake() {
  const store = new Map(); // full doc path -> plain data object
  const writes = []; // every write, in order: { op, path, data }
  const fake = {
    store,
    writes,
    calls: [], // every placeOrder callable invocation, in order
    // The callable implementation. Tests replace it to drive error paths;
    // the default records the call and returns a successful order.
    callableImpl: async (name, data) => {
      fake.calls.push({ name, data: JSON.parse(JSON.stringify(data)) });
      return { data: { order: { id: data.clientOrderId, clientOrderId: data.clientOrderId, total: data.seenTotal, status: 'new' } } };
    },
    initializeApp: (cfg) => ({ cfg }),
    getFirestore: () => ({}),
    getFunctions: () => ({}),
    httpsCallable: (fns, name) => async (data) => fake.callableImpl(name, data),
    collection: (db, name) => ({ __path: name }),
    doc: (db, ...segs) => ({ __path: segs.join('/') }),
    query: (coll) => ({ __collection: coll.__path }),
    orderBy: (field) => ({ __orderBy: field }),
    serverTimestamp: () => 'SERVER_TIMESTAMP',
    arrayUnion: (...vals) => vals,
    setDoc: async (ref, data, options) => {
      writes.push({ op: 'setDoc', path: ref.__path, data: JSON.parse(JSON.stringify(data)) });
      const prev = store.get(ref.__path) || {};
      store.set(ref.__path, options && options.merge ? { ...prev, ...data } : { ...data });
    },
    updateDoc: async (ref, data) => {
      writes.push({ op: 'updateDoc', path: ref.__path, data: JSON.parse(JSON.stringify(data)) });
      const prev = store.get(ref.__path) || {};
      store.set(ref.__path, { ...prev, ...data });
    },
    getDoc: async (ref) => ({
      exists: () => store.has(ref.__path),
      data: () => store.get(ref.__path),
      id: ref.__path.split('/').pop(),
    }),
    getDocs: async (q) => {
      const prefix = `${q.__collection}/`;
      const docs = [...store.entries()]
        .filter(([p]) => p.startsWith(prefix) && !p.slice(prefix.length).includes('/'))
        .map(([p, d]) => ({ id: p.slice(prefix.length), data: () => d, exists: () => true }));
      return { docs };
    },
  };
  return fake;
}

/* ---------- load the real app.js into a vm context ---------- */
function loadApp({ seedCheckoutId = null, seedDocs = {} } = {}) {
  const localStorage = createLocalStorage();
  localStorage.setItem('sp-cart', '{}');
  if (seedCheckoutId) localStorage.setItem('sp-checkout', seedCheckoutId);

  const fake = createStorefrontFake();
  // Phase 3: seed Firestore documents (full doc path -> data) BEFORE
  // boot() runs, so template tests can drive the pointer/template
  // reads.
  for (const [path, data] of Object.entries(seedDocs)) fake.store.set(path, data);

  const elements = new Map();
  const getElement = (sel) => {
    if (!elements.has(sel)) elements.set(sel, makeElement(sel, getElement));
    return elements.get(sel);
  };
  const documentStub = {
    title: '',
    documentElement: makeElement('html', getElement),
    querySelector: (sel) => getElement(sel),
    querySelectorAll: () => [],
    getElementById: (id) => getElement(`#${id}`),
    addEventListener: () => {},
  };

  const sandbox = {
    console,
    STORE_FIREBASE_CONFIG: {},
    __firebase: fake,
    localStorage,
    document: documentStub,
    // Timers never fire inside the vm: showJourney's 2.5s finish and the
    // toast timer must not run after submitOrder returns.
    setTimeout: () => 0,
    clearTimeout: () => {},
    setInterval: () => 0,
    requestAnimationFrame: () => 0,
    performance: { now: () => 0 },
    // Deterministic UUID so the checkout-generation test can assert it.
    crypto: { randomUUID: () => FIXED_UUID },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    addEventListener: () => {},
    IntersectionObserver: class {
      constructor() {}
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);

  let src = fs.readFileSync(APP_PATH, 'utf8');
  // Rewrite ONLY the three CDN import statements into destructuring from
  // the stub. Everything else in app.js runs byte-for-byte.
  src = src
    .replace(
      /import \{ initializeApp \} from '[^']+';/,
      'const { initializeApp } = __firebase;',
    )
    .replace(
      /import \{[\s\S]*?\} from 'https:\/\/www\.gstatic\.com\/firebasejs\/[^']*firebase-firestore\.js';/,
      'const { getFirestore, collection, query, orderBy, getDocs, doc, getDoc, setDoc, updateDoc, serverTimestamp, arrayUnion } = __firebase;',
    )
    .replace(
      /import \{[\s\S]*?\} from 'https:\/\/www\.gstatic\.com\/firebasejs\/[^']*firebase-functions\.js';/,
      'const { getFunctions, httpsCallable } = __firebase;',
    );
  assert.ok(!src.includes("from 'https://www.gstatic.com"), 'Firebase imports were not stubbed');
  assert.ok(!src.includes('addDoc('), 'the storefront must never call addDoc (orders are created by the function)');

  // Hook code, appended in the SAME evaluated scope so it can reach the
  // module-level bindings. app.js itself has no test hook.
  src += `
;globalThis.__test = {
  setProducts(list) { products = list; },
  getProducts() { return products; },
  setCart(c) { cart = c; localStorage.setItem('sp-cart', JSON.stringify(c)); renderCart(); },
  getCart() { return cart; },
  setDiscountCode(code) { discountCode = code; },
  getDiscountCode() { return discountCode; },
  submitOrder, showReview, cartLines, cartTotal,
  getClientOrderId() { return clientOrderId; },
  setClientOrderId(id) { clientOrderId = id; localStorage.setItem('sp-checkout', id); },
  // Phase 3: template + feedback state.
  getTemplateState() { return { templateId: activeTemplateId, grid: { ...templateGrid }, sections: { ...templateSections } }; },
  getAppliedVars() { return { ...document.documentElement.style._vars }; },
  getGridState() {
    const grid = document.querySelector('#productsGrid');
    return { columns: grid.style.gridTemplateColumns || '', expanded: gridExpanded };
  },
  loadActiveTemplate, applyTemplate, validateTemplateBody, renderProducts,
  submitFeedbackForm, lookupFeedback,
};`;
  vm.runInContext(src, sandbox, { filename: 'storefront/app.js' });
  return { sandbox, fake, localStorage, elements, getElement, t: sandbox.__test };
}

/* boot() is async (settings/categories/products reads). Give its
 * microtasks a chance to finish before driving state, or its
 * `products = ...` assignment would overwrite the test's products. */
async function loadAppReady(options) {
  const app = loadApp(options);
  await sleep(50);
  return app;
}

/* ---------- the storefront proving tests ---------- */

test('Phase 2: submitOrder sends only ids+quantities+code+seen prices, clears the cart on success', async () => {
  const { fake, localStorage, t } = await loadAppReady({ seedCheckoutId: 'client-order-1' });
  t.setProducts([...PRODUCTS]);
  t.setCart({ ...CART });
  assert.equal(t.cartTotal(), 1250);

  await t.submitOrder(CUSTOMER);

  assert.equal(fake.calls.length, 1, 'exactly one callable invocation');
  const call = fake.calls[0];
  assert.equal(call.name, 'placeOrder');
  assert.equal(call.data.clientOrderId, 'client-order-1');
  assert.deepEqual(plain(call.data.items), [
    { productId: 'prod-1', qty: 2 },
    { productId: 'prod-2', qty: 1 },
  ]);
  // The client never sends a price or a total as a fact — only what it
  // displayed, for the function's seen-price check.
  assert.deepEqual(plain(call.data.seenPrices), { 'prod-1': 500, 'prod-2': 250 });
  assert.equal(call.data.seenTotal, 1250);
  assert.equal(call.data.discountCode, null);
  assert.equal(call.data.customer.phone, CUSTOMER.phone);
  // No order document is written by the client — the function creates it.
  assert.equal(
    fake.writes.filter((w) => w.path.startsWith('orders/')).length,
    0,
    'the storefront must never write an order document itself',
  );
  // Cart cleared, checkout id released for the next checkout.
  assert.equal(localStorage.getItem('sp-cart'), '{}');
  assert.equal(t.cartLines().length, 0);
  assert.equal(localStorage.getItem('sp-checkout'), null);
  assert.equal(t.getClientOrderId(), null);
});

test('Phase 2 (T15): PRICE_CHANGED updates the loaded prices, re-renders the review, retry confirms the new total', async () => {
  const { fake, localStorage, elements, t } = await loadAppReady({ seedCheckoutId: 'client-order-2' });
  t.setProducts([...PRODUCTS]);
  t.setCart({ ...CART });

  // First confirm: the function rejects — prod-1 is now 550.
  fake.callableImpl = async (name, data) => {
    fake.calls.push({ name, data: JSON.parse(JSON.stringify(data)) });
    const err = new Error('price changed');
    err.details = { code: 'PRICE_CHANGED', currentPrices: { 'prod-1': 550, 'prod-2': 250 } };
    throw err;
  };
  await t.submitOrder(CUSTOMER);

  assert.equal(t.getProducts()[0].price, 550, 'loaded price updated from the function');
  assert.equal(t.cartTotal(), 1350, 'total recomputed from the new price');
  assert.ok(
    elements.get('#modalSheet').innerHTML.includes('اتغير سعر منتج'),
    'review re-rendered with the price-change notice',
  );
  // No order was created; the same clientOrderId is kept for the retry.
  assert.equal(localStorage.getItem('sp-checkout'), 'client-order-2');
  assert.equal(t.getClientOrderId(), 'client-order-2');
  assert.equal(t.cartLines().length, 2, 'cart kept after the rejection');

  // Retry with the new prices — the callable now succeeds.
  fake.callableImpl = async (name, data) => {
    fake.calls.push({ name, data: JSON.parse(JSON.stringify(data)) });
    return { data: { order: { id: data.clientOrderId, total: data.seenTotal, status: 'new' } } };
  };
  await t.submitOrder(CUSTOMER);

  assert.equal(fake.calls.length, 2);
  assert.equal(fake.calls[1].data.clientOrderId, 'client-order-2', 'retry reuses the same id');
  assert.deepEqual(plain(fake.calls[1].data.seenPrices), { 'prod-1': 550, 'prod-2': 250 });
  assert.equal(fake.calls[1].data.seenTotal, 1350, 'retry confirms the NEW total');
  assert.equal(localStorage.getItem('sp-cart'), '{}');
  assert.equal(localStorage.getItem('sp-checkout'), null);
});

test('Phase 2 (T16): INSUFFICIENT_STOCK shows the available quantity, keeps the id', async () => {
  const { fake, localStorage, elements, t } = await loadAppReady({ seedCheckoutId: 'client-order-3' });
  t.setProducts([...PRODUCTS]);
  t.setCart({ ...CART });

  fake.callableImpl = async (name, data) => {
    fake.calls.push({ name, data: JSON.parse(JSON.stringify(data)) });
    const err = new Error('insufficient stock');
    err.details = { code: 'INSUFFICIENT_STOCK', productId: 'prod-1', availableQty: 1 };
    throw err;
  };
  await t.submitOrder(CUSTOMER);

  assert.ok(
    elements.get('#modalSheet').innerHTML.includes('الكمية مش متاحة'),
    'stock modal shown',
  );
  assert.ok(
    elements.get('#modalSheet').innerHTML.includes('1'),
    'available quantity shown in the message',
  );
  assert.equal(localStorage.getItem('sp-checkout'), 'client-order-3', 'id kept for the retry');
  assert.equal(t.cartLines().length, 2, 'cart kept');
});

test('Phase 2 (T23): more than 10 products is refused client-side, the callable is never called', async () => {
  const { fake, elements, t } = await loadAppReady({ seedCheckoutId: 'client-order-4' });
  const many = Array.from({ length: 11 }, (_, i) => ({ id: `prod-${i + 1}`, name: `منتج ${i + 1}`, price: 100, categoryId: 'cat-1' }));
  t.setProducts(many);
  t.setCart(Object.fromEntries(many.map((p) => [p.id, 1])));

  await t.submitOrder(CUSTOMER);

  assert.equal(fake.calls.length, 0, 'the function is never called for an oversized order');
  assert.ok(
    elements.get('#modalSheet').innerHTML.includes('أكتر من 10 منتجات'),
    'review re-rendered with the size notice',
  );
  assert.equal(t.cartLines().length, 11, 'cart kept');
});

test('Phase 2: DISCOUNT_INVALID re-renders the review with a notice, keeps the id', async () => {
  const { fake, localStorage, elements, t } = await loadAppReady({ seedCheckoutId: 'client-order-5' });
  t.setProducts([...PRODUCTS]);
  t.setCart({ ...CART });
  t.setDiscountCode('BADCODE');

  fake.callableImpl = async (name, data) => {
    fake.calls.push({ name, data: JSON.parse(JSON.stringify(data)) });
    const err = new Error('bad code');
    err.details = { code: 'DISCOUNT_INVALID' };
    throw err;
  };
  await t.submitOrder(CUSTOMER);

  assert.equal(fake.calls[0].data.discountCode, 'BADCODE', 'the code was sent to the function');
  assert.ok(
    elements.get('#modalSheet').innerHTML.includes('كود الخصم مش صحيح'),
    'review re-rendered with the bad-code notice',
  );
  assert.equal(localStorage.getItem('sp-checkout'), 'client-order-5', 'id kept');
  assert.equal(t.cartLines().length, 2, 'cart kept');
});

test('Phase 2: a generic callable failure keeps the id and the cart, shows the real error', async () => {
  const { fake, localStorage, elements, t } = await loadAppReady({ seedCheckoutId: 'client-order-6' });
  t.setProducts([...PRODUCTS]);
  t.setCart({ ...CART });

  fake.callableImpl = async () => { throw new Error('network down'); };
  await t.submitOrder(CUSTOMER);

  assert.equal(localStorage.getItem('sp-checkout'), 'client-order-6', 'id kept on failure');
  assert.equal(t.getClientOrderId(), 'client-order-6');
  assert.equal(t.cartLines().length, 2, 'cart kept on failure');
  assert.ok(
    elements.get('#modalSheet').innerHTML.includes('حصلت مشكلة'),
    'the real error is shown, no fake success',
  );

  // Retry with the same id succeeds exactly once.
  fake.callableImpl = async (name, data) => {
    fake.calls.push({ name, data: JSON.parse(JSON.stringify(data)) });
    return { data: { order: { id: data.clientOrderId, total: data.seenTotal, status: 'new' } } };
  };
  await t.submitOrder(CUSTOMER);
  assert.equal(fake.calls.length, 1, 'retry creates exactly one order');
  assert.equal(fake.calls[0].data.clientOrderId, 'client-order-6');
  assert.equal(localStorage.getItem('sp-cart'), '{}');
});

test('Phase 2: the discount code typed in the review reaches the callable', async () => {
  const { fake, getElement, t } = await loadAppReady({ seedCheckoutId: 'client-order-7' });
  t.setProducts([...PRODUCTS]);
  t.setCart({ ...CART });

  t.showReview(CUSTOMER);
  getElement('#fDiscount').value = 'SAVE10';
  getElement('#confirmOrder').__fire('click');
  await sleep(50);

  assert.equal(fake.calls.length, 1);
  assert.equal(fake.calls[0].data.discountCode, 'SAVE10');
  assert.equal(t.getDiscountCode(), '', 'discount code cleared after a successful order');
});

test('Phase 2: opening checkout generates and persists one clientOrderId', async () => {
  const { localStorage, elements, t } = await loadAppReady();
  t.setProducts([...PRODUCTS]);
  t.setCart({ ...CART });
  assert.equal(localStorage.getItem('sp-checkout'), null);

  elements.get('#checkoutBtn').__fire('click');
  assert.equal(localStorage.getItem('sp-checkout'), FIXED_UUID);
  assert.equal(t.getClientOrderId(), FIXED_UUID);

  // Opening checkout again reuses the same attempt id (unchanged on retry).
  elements.get('#checkoutBtn').__fire('click');
  assert.equal(localStorage.getItem('sp-checkout'), FIXED_UUID);
  assert.equal(t.getClientOrderId(), FIXED_UUID);
});

/* ================= (B) function tests ================= */

/* Seed a store: prod-1 stock 5 @500, prod-2 stock 3 @250. */
function seedStore(db) {
  db.seed('products/prod-1', { name: 'سماعة بلوتوث', price: 500, categoryId: 'cat-1', inStock: true });
  db.seed('products/prod-2', { name: 'شاحن سريع', price: 250, categoryId: 'cat-1', inStock: true });
  db.seed('inventory/prod-1', { productId: 'prod-1', stock: 5, reserved: 0, minStock: 5, costPrice: 300 });
  db.seed('inventory/prod-2', { productId: 'prod-2', stock: 3, reserved: 0, minStock: 5, costPrice: 150 });
}

function placeOrder(db, overrides = {}) {
  return createOrderTx(db, {
    clientOrderId: 'order-1',
    items: [{ productId: 'prod-1', qty: 2 }, { productId: 'prod-2', qty: 1 }],
    discountCode: null,
    customer: { name: 'اختبار', phone: '01012345678', address: 'عنوان اختبار' },
    source: 'storefront',
    createdBy: null,
    shippingCompanyId: null,
    notes: null,
    seenPrices: { 'prod-1': 500, 'prod-2': 250 },
    seenTotal: 1250,
    serverTimestamp: () => NOW,
    ...overrides,
  });
}

test('Phase 2 (T1): placeOrder creates the order from DB prices, reserves stock, writes movements + one audit entry', async () => {
  const db = createFakeFirestore();
  seedStore(db);

  const { order, created } = await placeOrder(db);
  assert.equal(created, true);
  assert.equal(order.id, 'order-1');
  assert.equal(order.clientOrderId, 'order-1');
  assert.equal(order.status, 'new');
  assert.equal(order.paymentStatus, 'cod_pending');
  assert.equal(order.subtotal, 1250);
  assert.equal(order.total, 1250);
  assert.equal(order.discountPercent, null);
  assert.equal(order.discountAmount, 0);
  assert.deepEqual(order.items, [
    { productId: 'prod-1', name: 'سماعة بلوتوث', price: 500, qty: 2 },
    { productId: 'prod-2', name: 'شاحن سريع', price: 250, qty: 1 },
  ]);

  // Stock reserved, inStock still true (5-2=3 and 3-1=2 remain).
  assert.equal(db.all('inventory/').find((d) => d.id === 'prod-1').data.reserved, 2);
  assert.equal(db.all('inventory/').find((d) => d.id === 'prod-2').data.reserved, 1);
  assert.equal(db.all('products/').find((d) => d.id === 'prod-1').data.inStock, true);
  assert.equal(db.all('products/').find((d) => d.id === 'prod-2').data.inStock, true);

  // Two reserve movements, one audit entry, no customer PII in the audit.
  const movements = db.all('movements/');
  assert.equal(movements.length, 2);
  assert.ok(movements.every((m) => m.data.type === 'order_reserve' && m.data.qty < 0));
  const audits = db.all('audit/');
  assert.equal(audits.length, 1, 'exactly one audit entry per order');
  assert.equal(audits[0].data.collection, 'orders');
  assert.equal(audits[0].data.docId, 'order-1');
  assert.equal(audits[0].data.newValues.total, 1250);
  assert.ok(!JSON.stringify(audits[0].data).includes('01012345678'), 'no customer phone in the audit entry');
});

test('Phase 2 (T1): reserving the last unit flips inStock to false', async () => {
  const db = createFakeFirestore();
  seedStore(db);
  db.seed('inventory/prod-2', { productId: 'prod-2', stock: 1, reserved: 0, minStock: 5, costPrice: 150 });

  await placeOrder(db, { items: [{ productId: 'prod-2', qty: 1 }], seenPrices: { 'prod-2': 250 }, seenTotal: 250 });

  assert.equal(db.all('products/').find((d) => d.id === 'prod-2').data.inStock, false);
  assert.equal(db.all('products/').find((d) => d.id === 'prod-1').data.inStock, true);
});

test('Phase 2 (T5/T14): the same clientOrderId twice returns the existing order, no double reserve, no second audit', async () => {
  const db = createFakeFirestore();
  seedStore(db);

  const first = await placeOrder(db);
  assert.equal(first.created, true);
  const second = await placeOrder(db);
  assert.equal(second.created, false, 'idempotent retry returns the existing order');
  assert.equal(second.order.id, 'order-1');
  assert.equal(second.order.total, 1250);

  assert.equal(db.all('orders/').length, 1, 'still exactly one order');
  assert.equal(db.all('audit/').length, 1, 'no second audit entry on the retry');
  assert.equal(db.all('inventory/').find((d) => d.id === 'prod-1').data.reserved, 2, 'no double reservation');
  assert.equal(db.all('movements/').length, 2);
});

test('Phase 2 (T6/T8): insufficient stock on the second line rolls the whole transaction back', async () => {
  const db = createFakeFirestore();
  seedStore(db);

  await assert.rejects(
    placeOrder(db, { items: [{ productId: 'prod-1', qty: 2 }, { productId: 'prod-2', qty: 4 }] }),
    (e) => e.code === 'INSUFFICIENT_STOCK' && e.details.productId === 'prod-2' && e.details.availableQty === 3,
  );

  assert.equal(db.all('orders/').length, 0, 'no order created');
  assert.equal(db.all('audit/').length, 0, 'no audit entry on failure');
  assert.equal(db.all('movements/').length, 0, 'no movements on failure');
  // The first line's reservation was rolled back too (atomicity).
  assert.equal(db.all('inventory/').find((d) => d.id === 'prod-1').data.reserved, 0);
});

test('Phase 2 (T7): two concurrent orders for the last unit — exactly one wins', async () => {
  const db = createFakeFirestore();
  seedStore(db);
  db.seed('inventory/prod-1', { productId: 'prod-1', stock: 1, reserved: 0, minStock: 5, costPrice: 300 });

  const one = placeOrder(db, {
    clientOrderId: 'order-a',
    items: [{ productId: 'prod-1', qty: 1 }],
    seenPrices: { 'prod-1': 500 },
    seenTotal: 500,
  });
  const two = placeOrder(db, {
    clientOrderId: 'order-b',
    items: [{ productId: 'prod-1', qty: 1 }],
    seenPrices: { 'prod-1': 500 },
    seenTotal: 500,
  });
  const results = await Promise.allSettled([one, two]);

  const fulfilled = results.filter((r) => r.status === 'fulfilled');
  const rejected = results.filter((r) => r.status === 'rejected');
  assert.equal(fulfilled.length, 1, 'exactly one order succeeds');
  assert.equal(rejected.length, 1);
  assert.equal(rejected[0].reason.code, 'INSUFFICIENT_STOCK');
  assert.equal(db.all('orders/').length, 1);
  assert.equal(db.all('inventory/').find((d) => d.id === 'prod-1').data.reserved, 1);
  assert.equal(db.all('products/').find((d) => d.id === 'prod-1').data.inStock, false);
});

test('Phase 2 (T17): a changed price rejects the order and creates nothing', async () => {
  const db = createFakeFirestore();
  seedStore(db);

  await assert.rejects(
    placeOrder(db, { seenPrices: { 'prod-1': 450, 'prod-2': 250 }, seenTotal: 1150 }),
    (e) => e.code === 'PRICE_CHANGED' && e.details.currentPrices['prod-1'] === 500,
  );
  assert.equal(db.all('orders/').length, 0);
  assert.equal(db.all('audit/').length, 0);
  assert.equal(db.all('inventory/').find((d) => d.id === 'prod-1').data.reserved, 0);
});

test('Phase 2 (T17): correct prices but a wrong total rejects the order', async () => {
  const db = createFakeFirestore();
  seedStore(db);

  await assert.rejects(
    placeOrder(db, { seenTotal: 1200 }),
    (e) => e.code === 'TOTAL_CHANGED',
  );
  assert.equal(db.all('orders/').length, 0);
});

test('Phase 2 (T3): a valid one-time code discounts the total and is claimed atomically', async () => {
  const db = createFakeFirestore();
  seedStore(db);
  db.seed('discounts/SAVE10', { percent: 10, active: true, usedBy: null, expiresAt: null });

  const { order } = await placeOrder(db, { discountCode: 'SAVE10' });
  assert.equal(order.discountCode, 'SAVE10');
  assert.equal(order.discountPercent, 10);
  assert.equal(order.discountAmount, 125);
  assert.equal(order.total, 1125);
  assert.equal(db.all('discounts/').find((d) => d.id === 'SAVE10').data.usedBy, 'order-1');

  // The same code a second time is refused (one use only).
  await assert.rejects(
    placeOrder(db, { clientOrderId: 'order-2', discountCode: 'SAVE10' }),
    (e) => e.code === 'DISCOUNT_USED',
  );
  assert.equal(db.all('orders/').length, 1);
});

test('Phase 2 (T23): more than 10 products is refused before any read or write', async () => {
  const db = createFakeFirestore();
  seedStore(db);
  const items = Array.from({ length: 11 }, (_, i) => ({ productId: `prod-x${i}`, qty: 1 }));

  await assert.rejects(placeOrder(db, { items }), (e) => e.code === 'ORDER_TOO_LARGE');
  assert.equal(db.all('orders/').length, 0);
  assert.equal(db.all('audit/').length, 0);
});

test('Phase 2 (T2): an invalid phone is refused before any read or write', async () => {
  const db = createFakeFirestore();
  seedStore(db);

  await assert.rejects(
    placeOrder(db, { customer: { name: 'x', phone: '123', address: 'y' } }),
    (e) => e.code === 'INVALID_INPUT',
  );
  assert.equal(db.all('orders/').length, 0);
});

test('Phase 2 (T10): cancelling releases the reservation and flips inStock back', async () => {
  const db = createFakeFirestore();
  seedStore(db);
  db.seed('inventory/prod-2', { productId: 'prod-2', stock: 1, reserved: 0, minStock: 5, costPrice: 150 });
  const { order } = await placeOrder(db, { items: [{ productId: 'prod-2', qty: 1 }], seenPrices: { 'prod-2': 250 }, seenTotal: 250 });
  assert.equal(db.all('products/').find((d) => d.id === 'prod-2').data.inStock, false);

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(db.collection('orders').doc(order.id));
    await releaseReservationTx(db, tx, { id: snap.id, ...snap.data() }, {
      movementType: 'order_cancel', newStatus: 'cancelled', now: NOW + 1000, actorUid: 'admin-1', source: 'admin',
    });
  });

  assert.equal(db.all('inventory/').find((d) => d.id === 'prod-2').data.reserved, 0);
  assert.equal(db.all('products/').find((d) => d.id === 'prod-2').data.inStock, true);
  assert.equal(db.all('orders/').find((d) => d.id === 'order-1').data.status, 'cancelled');
  assert.equal(db.all('movements/').filter((m) => m.data.type === 'order_cancel').length, 1);
  assert.equal(db.all('audit/').length, 2, 'create audit + cancel audit');
});

test('Phase 2 (T11): the sweep expires a 25-hour-old new order, leaves a fresh one alone, and is idempotent', async () => {
  const db = createFakeFirestore();
  seedStore(db);
  // Old order (25h ago, still new) + fresh order (just now).
  await placeOrder(db, { clientOrderId: 'order-old', serverTimestamp: () => NOW - 25 * 60 * 60 * 1000 });
  await placeOrder(db, { clientOrderId: 'order-fresh', serverTimestamp: () => NOW });

  const first = await sweepExpiredReservations(db, { now: NOW, serverTimestamp: () => NOW });
  assert.deepEqual(first, { released: 1, checked: 2 });
  assert.equal(db.all('orders/').find((d) => d.id === 'order-old').data.status, 'expired');
  assert.equal(db.all('orders/').find((d) => d.id === 'order-old').data.cancelReason, 'reservation_expired');
  assert.equal(db.all('orders/').find((d) => d.id === 'order-fresh').data.status, 'new');
  assert.equal(db.all('inventory/').find((d) => d.id === 'prod-1').data.reserved, 2, 'only the fresh order keeps its reservation');

  // A re-run releases nothing (idempotent by construction).
  const second = await sweepExpiredReservations(db, { now: NOW, serverTimestamp: () => NOW });
  assert.deepEqual(second, { released: 0, checked: 1 });
});

test('Phase 2 (T12): the unified state machine allows exactly the legal transitions', () => {
  assert.equal(isAllowedTransition('new', 'accepted'), true);
  assert.equal(isAllowedTransition('new', 'cancelled'), true);
  assert.equal(isAllowedTransition('new', 'expired'), true);
  assert.equal(isAllowedTransition('new', 'delivered'), false);
  assert.equal(isAllowedTransition('accepted', 'preparing'), true);
  assert.equal(isAllowedTransition('preparing', 'ready'), true);
  assert.equal(isAllowedTransition('ready', 'in_transit'), true);
  assert.equal(isAllowedTransition('ready', 'delivered'), false);
  assert.equal(isAllowedTransition('in_transit', 'delivered'), true);
  assert.equal(isAllowedTransition('in_transit', 'ready'), false);
  assert.equal(isAllowedTransition('delivered', 'cancelled'), false);
  assert.equal(isAllowedTransition('cancelled', 'accepted'), false);
  assert.equal(isAllowedTransition('cancelled', 'new'), true);
  assert.equal(isAllowedTransition('cancelled', 'in_transit'), false);
  assert.equal(isAllowedTransition('expired', 'accepted'), false);
});

/* ================= (C) Phase 3: templates ================= */

const DARK_TEMPLATE = {
  schemaVersion: 1,
  status: 'active',
  grid: { columns: 3, rows: 2, minColumnWidthPx: 200 },
  tokens: { accent: '#111111', bg: '#222222', text: '#eeeeee' },
  sections: { hero: false, promos: true, featured: true, delivery: true, contact: true },
};

const EIGHT_PRODUCTS = Array.from({ length: 8 }, (_, i) => ({
  id: `prod-${i + 1}`, name: `منتج ${i + 1}`, price: 100 + i * 10, categoryId: 'cat-1',
}));

test('Phase 3: boot with no template pointer falls back to classic (auto-fill grid, classic tokens)', async () => {
  const { t } = await loadAppReady({});
  const state = t.getTemplateState();
  assert.equal(state.templateId, 'classic');
  assert.deepEqual(plain(state.grid), { columns: null, rows: null, minColumnWidthPx: 250 });
  const vars = t.getAppliedVars();
  assert.equal(vars['--accent'], '#3f7f8c');
  assert.equal(vars['--bg'], '#f4f6f8');
  // Launch grid: null columns keep the stylesheet auto-fill exactly.
  assert.equal(t.getGridState().columns, '');
});

test('Phase 3: boot with a seeded template applies its tokens + fixed grid + rows cap', async () => {
  const { t, elements, getElement } = await loadAppReady({
    seedDocs: {
      'storeSettings/activeTemplate': { templateId: 'dark' },
      'templates/dark': DARK_TEMPLATE,
    },
  });
  const state = t.getTemplateState();
  assert.equal(state.templateId, 'dark');
  assert.equal(state.sections.hero, false);
  const vars = t.getAppliedVars();
  assert.equal(vars['--accent'], '#111111');
  assert.equal(vars['--bg'], '#222222');
  assert.equal(t.getGridState().columns, 'repeat(3, 1fr)');

  t.setProducts([...EIGHT_PRODUCTS]);
  t.renderProducts();
  const gridHtml = getElement('#productsGrid').innerHTML;
  const shown = (gridHtml.match(/<article class="product"/g) || []).length;
  assert.equal(shown, 6, 'rows 2 x columns 3 caps the visible products at 6');
  assert.equal(elements.has('#gridMoreBtn'), true);
  getElement('#gridMoreBtn').__fire('click');
  const shownAll = (getElement('#productsGrid').innerHTML.match(/<article class="product"/g) || []).length;
  assert.equal(shownAll, 8, 'show more reveals the rest');
  assert.equal(elements.has('#gridLessBtn'), true);
});

test('Phase 3: an invalid template is rejected and classic applies', async () => {
  const { t } = await loadAppReady({
    seedDocs: {
      'storeSettings/activeTemplate': { templateId: 'bad' },
      'templates/bad': {
        schemaVersion: 1,
        status: 'active',
        tokens: { accent: 'url(evil)' },
      },
    },
  });
  assert.equal(t.getTemplateState().templateId, 'classic');
  assert.equal(t.getAppliedVars()['--accent'], '#3f7f8c');
});

test('Phase 3: the built-in classic matches templates/classic.json', async () => {
  const classicJson = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'storefront', 'templates', 'classic.json'), 'utf8'));
  const { t } = await loadAppReady({});
  const state = t.getTemplateState();
  assert.deepEqual(plain(state.grid), plain(classicJson.grid));
  const cssVars = { bg: '--bg', bg2: '--bg-2', surface: '--surface', surfaceStrong: '--surface-strong', border: '--border', text: '--text', textSoft: '--text-soft', accent: '--accent', accent2: '--accent-2', warm: '--warm', radius: '--radius' };
  const vars = t.getAppliedVars();
  for (const [key, cssVar] of Object.entries(cssVars)) {
    assert.equal(vars[cssVar], classicJson.tokens[key], `token ${key}`);
  }
});

test('Phase 3: validateTemplateBody mirrors the gateway', async () => {
  const { t } = await loadAppReady({});
  assert.equal(t.validateTemplateBody({ schemaVersion: 1, tokens: { accent: '#3f7f8c' } }).passed, true);
  // Failed-check arrays come from the vm realm — normalize via plain().
  assert.deepEqual(plain(t.validateTemplateBody({ schemaVersion: 1, tokens: { accent: 'url(evil)' } }).failed), ['tokens.accent']);
  assert.deepEqual(plain(t.validateTemplateBody({ schemaVersion: 1, grid: { columns: 99 } }).failed), ['grid.columns']);
  assert.deepEqual(plain(t.validateTemplateBody({ schemaVersion: 2 }).failed), ['schemaVersion']);
});

/* ================= (D) Phase 3: feedback form ================= */

function feedbackCallableImpl(fake) {
  return async (name, data) => {
    fake.calls.push({ name, data: JSON.parse(JSON.stringify(data)) });
    if (name === 'submitFeedback') return { data: { trackingCode: 'FB-ABC123', duplicate: false, linked: false } };
    if (name === 'getFeedbackStatus') return { data: { status: 'in_review', lastReply: 'جارٍ المراجعة' } };
    return { data: { order: { id: data.clientOrderId, clientOrderId: data.clientOrderId, total: data.seenTotal, status: 'new' } } };
  };
}

test('Phase 3: feedback form submits via the callable and shows the tracking code', async () => {
  const { fake, getElement } = await loadAppReady({});
  fake.callableImpl = feedbackCallableImpl(fake);
  getElement('#fbType').value = 'complaint';
  getElement('#fbCategory').value = 'delivery';
  getElement('#fbTitle').value = 'مشكلة في التوصيل';
  getElement('#fbMessage').value = 'الطلب وصل متأخر يومين عن الميعاد';
  getElement('#fbOrderId').value = '';
  getElement('#fbPhone').value = '01012345678';
  getElement('#fbForm').__fire('submit', { preventDefault() {} });
  await sleep(50);
  assert.equal(fake.calls.length, 1);
  const call = fake.calls[0];
  assert.equal(call.name, 'submitFeedback');
  assert.equal(call.data.submissionId, FIXED_UUID);
  assert.equal(call.data.type, 'complaint');
  assert.equal(call.data.category, 'delivery');
  assert.equal(call.data.title, 'مشكلة في التوصيل');
  assert.equal(call.data.phone, '01012345678');
  assert.equal(call.data.orderId, null);
  const result = getElement('#fbResult');
  assert.equal(result.hidden, false);
  assert.ok(result.textContent.includes('FB-ABC123'), `tracking code shown, got: ${result.textContent}`);
});

test('Phase 3: feedback lookup shows the status and last reply', async () => {
  const { fake, getElement } = await loadAppReady({});
  fake.callableImpl = feedbackCallableImpl(fake);
  getElement('#fbLookupCode').value = 'FB-ABC123';
  getElement('#fbLookupPhone').value = '01012345678';
  getElement('#fbLookupBtn').__fire('click');
  await sleep(50);
  assert.equal(fake.calls.length, 1);
  assert.equal(fake.calls[0].name, 'getFeedbackStatus');
  assert.equal(fake.calls[0].data.trackingCode, 'FB-ABC123');
  const result = getElement('#fbLookupResult');
  assert.equal(result.hidden, false);
  assert.ok(result.textContent.includes('قيد المراجعة'), `status shown, got: ${result.textContent}`);
  assert.ok(result.textContent.includes('جارٍ المراجعة'), `last reply shown, got: ${result.textContent}`);
});
