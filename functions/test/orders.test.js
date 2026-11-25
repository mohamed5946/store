/* Stage 0 proving test (design doc file 33, test plan T1/T2).
 *
 * Runs the REAL storefront/app.js in a vm context with stubbed Firebase
 * (in-memory Firestore), stubbed DOM/localStorage/timers, and no network.
 * No npm dependencies: only Node builtins (node:test, node:assert/strict,
 * fs, vm). Run from the repo root:
 *   node --test functions/test/orders.test.js
 *
 * app.js is a browser ES module with CDN Firebase imports, so the harness
 * rewrites ONLY the two import statements into destructuring from a stub
 * object (__firebase). Every other line of app.js runs unmodified. Test
 * state is driven through hook code appended in the SAME evaluated scope
 * (it can reach the module-level `products`, `cart`, `clientOrderId`,
 * `placeOrder`, `cartLines`, `cartTotal` directly). No test hook exists
 * in app.js itself.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const APP_PATH = path.join(__dirname, '..', '..', 'storefront', 'app.js');

const PRODUCTS = [
  { id: 'prod-1', name: 'سماعة بلوتوث', price: 500, categoryId: 'cat-1' },
  { id: 'prod-2', name: 'شاحن سريع', price: 250, categoryId: 'cat-1' },
];
const CART = { 'prod-1': 2, 'prod-2': 1 }; // total: 2*500 + 1*250 = 1250
const EXPECTED_ITEMS = [
  { id: 'prod-1', name: 'سماعة بلوتوث', price: 500, qty: 2 },
  { id: 'prod-2', name: 'شاحن سريع', price: 250, qty: 1 },
];
const CUSTOMER = { name: 'اختبار', phone: '01012345678', addr: 'عنوان اختبار' };
const FIXED_UUID = '11111111-2222-4333-8444-555555555555';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Objects created inside the vm context have a different realm prototype,
// so assert.deepEqual (strict) rejects them even when the values match.
// Normalize through JSON before comparing.
const plain = (v) => JSON.parse(JSON.stringify(v));

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
    style: {},
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

/* ---------- fake in-memory Firestore ---------- */
function createFakeFirestore() {
  const store = new Map(); // full doc path -> plain data object
  const writes = []; // every write, in order: { op, path, data }
  const fake = {
    store,
    writes,
    // Set true to make the next setDoc on an orders/* doc throw, so the
    // test can drive placeOrder's failure path (ambiguous failure -> retry).
    failNextOrderSetDoc: false,
    initializeApp: (cfg) => ({ cfg }),
    getFirestore: () => ({}),
    collection: (db, name) => ({ __path: name }),
    doc: (db, ...segs) => ({ __path: segs.join('/') }),
    query: (coll) => ({ __collection: coll.__path }),
    orderBy: (field) => ({ __orderBy: field }),
    serverTimestamp: () => 'SERVER_TIMESTAMP',
    arrayUnion: (...vals) => vals,
    setDoc: async (ref, data, options) => {
      if (fake.failNextOrderSetDoc && ref.__path.startsWith('orders/')) {
        fake.failNextOrderSetDoc = false;
        throw new Error('simulated network failure');
      }
      writes.push({ op: 'setDoc', path: ref.__path, data: JSON.parse(JSON.stringify(data)) });
      const prev = store.get(ref.__path) || {};
      store.set(ref.__path, options && options.merge ? { ...prev, ...data } : { ...data });
    },
    addDoc: async (coll, data) => {
      const id = `auto_${writes.length + 1}`;
      writes.push({ op: 'addDoc', path: `${coll.__path}/${id}`, data: JSON.parse(JSON.stringify(data)) });
      store.set(`${coll.__path}/${id}`, { ...data });
      return { id };
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
    // Orders currently in the fake store, as [{ id, data }].
    orders: () => [...store.entries()]
      .filter(([p]) => p.startsWith('orders/'))
      .map(([p, d]) => ({ id: p.slice('orders/'.length), data: d })),
  };
  return fake;
}

/* ---------- load the real app.js into a vm context ---------- */
function loadApp({ seedCheckoutId = null } = {}) {
  const localStorage = createLocalStorage();
  localStorage.setItem('sp-cart', '{}');
  if (seedCheckoutId) localStorage.setItem('sp-checkout', seedCheckoutId);

  const fake = createFakeFirestore();

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
    // toast timer must not run after placeOrder returns.
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
  // Rewrite ONLY the two CDN import statements into destructuring from
  // the stub. Everything else in app.js runs byte-for-byte.
  src = src
    .replace(
      /import \{ initializeApp \} from '[^']+';/,
      'const { initializeApp } = __firebase;',
    )
    .replace(
      /import \{[^}]*\} from 'https:\/\/www\.gstatic\.com\/firebasejs\/[^']+';/,
      'const { getFirestore, collection, query, orderBy, getDocs, doc, getDoc, setDoc, updateDoc, addDoc, serverTimestamp, arrayUnion } = __firebase;',
    );
  assert.ok(!src.includes("from 'https://www.gstatic.com"), 'Firebase imports were not stubbed');
  assert.ok(!src.includes('addDoc(collection(db'), 'unexpected addDoc call remains');

  // Hook code, appended in the SAME evaluated scope so it can reach the
  // module-level bindings. app.js itself has no test hook.
  src += `
;globalThis.__test = {
  setProducts(list) { products = list; },
  setCart(c) { cart = c; localStorage.setItem('sp-cart', JSON.stringify(c)); renderCart(); },
  getCart() { return cart; },
  placeOrder, cartLines, cartTotal,
  getClientOrderId() { return clientOrderId; },
  setClientOrderId(id) { clientOrderId = id; localStorage.setItem('sp-checkout', id); },
};`;
  vm.runInContext(src, sandbox, { filename: 'storefront/app.js' });
  return { sandbox, fake, localStorage, elements, t: sandbox.__test };
}

/* Boot is an async IIFE (settings/categories/products reads). Give its
 * microtasks a chance to finish before driving state, or its
 * `products = ...` assignment would overwrite the test's products. */
async function loadAppReady(options) {
  const app = loadApp(options);
  await sleep(50);
  return app;
}

/* ---------- the proving tests ---------- */

test('Stage 0: 2-product order has correct items, correct total, one order, cart cleared', async () => {
  const { fake, localStorage, t } = await loadAppReady({ seedCheckoutId: 'client-order-1' });
  t.setProducts([...PRODUCTS]);
  t.setCart({ ...CART });
  assert.equal(t.cartTotal(), 1250);

  await t.placeOrder(CUSTOMER);

  const orders = fake.orders();
  assert.equal(orders.length, 1, 'exactly one order document must exist');
  const order = orders[0];
  assert.equal(order.id, 'client-order-1', 'order doc id is the clientOrderId');
  assert.equal(order.data.clientOrderId, 'client-order-1');
  assert.equal(order.data.id, 'client-order-1');
  assert.deepEqual(plain(order.data.items), EXPECTED_ITEMS);
  for (const item of order.data.items) {
    for (const value of Object.values(item)) assert.notEqual(value, undefined, 'no undefined item value');
  }
  assert.equal(order.data.total, 1250);
  assert.equal(order.data.status, 'new');
  assert.equal(order.data.customerName, CUSTOMER.name);
  assert.equal(order.data.customerPhone, CUSTOMER.phone);
  assert.equal(order.data.customerAddress, CUSTOMER.addr);
  // The order must be written with setDoc, never addDoc (addDoc would
  // mint a new id per call and break idempotency).
  assert.equal(
    fake.writes.filter((w) => w.op === 'addDoc' && w.path.startsWith('orders/')).length,
    0,
  );
  // Cart cleared afterwards, and the checkout id is released for the
  // next checkout.
  assert.equal(localStorage.getItem('sp-cart'), '{}');
  assert.equal(t.cartLines().length, 0);
  assert.equal(localStorage.getItem('sp-checkout'), null);
  assert.equal(t.getClientOrderId(), null);
});

test('Stage 0: duplicate submission with the same clientOrderId creates no second order', async () => {
  const { fake, localStorage, t } = await loadAppReady({ seedCheckoutId: 'client-order-2' });
  t.setProducts([...PRODUCTS]);
  t.setCart({ ...CART });
  await t.placeOrder(CUSTOMER);
  assert.equal(fake.orders().length, 1);

  // Replay the same checkout: restore the cart and submit again with the
  // same idempotency key. (In the real flow the key is cleared after a
  // successful order, so re-seeding it here simulates a replayed/duplicate
  // submission; the property under test is that writing the same doc id
  // cannot create a second order document.)
  t.setCart({ ...CART });
  t.setClientOrderId('client-order-2');
  await t.placeOrder(CUSTOMER);

  const orders = fake.orders();
  assert.equal(orders.length, 1, 'still exactly one order document');
  assert.equal(orders[0].id, 'client-order-2');
  assert.deepEqual(plain(orders[0].data.items), EXPECTED_ITEMS);
  assert.equal(orders[0].data.total, 1250);
  assert.equal(localStorage.getItem('sp-cart'), '{}');
});

test('Stage 0: failed order keeps the clientOrderId, retry succeeds exactly once', async () => {
  const { fake, localStorage, t } = await loadAppReady({ seedCheckoutId: 'client-order-3' });
  t.setProducts([...PRODUCTS]);
  t.setCart({ ...CART });

  fake.failNextOrderSetDoc = true;
  await t.placeOrder(CUSTOMER); // placeOrder catches the failure itself

  assert.equal(fake.orders().length, 0, 'no order after a failed write');
  assert.equal(localStorage.getItem('sp-checkout'), 'client-order-3', 'id kept on failure');
  assert.equal(t.getClientOrderId(), 'client-order-3');
  assert.equal(t.cartLines().length, 2, 'cart kept on failure');
  assert.notEqual(localStorage.getItem('sp-cart'), '{}');

  // Retry with the same id — no re-seeding needed, it was kept.
  await t.placeOrder(CUSTOMER);

  const orders = fake.orders();
  assert.equal(orders.length, 1, 'retry creates exactly one order');
  assert.equal(orders[0].id, 'client-order-3');
  assert.deepEqual(plain(orders[0].data.items), EXPECTED_ITEMS);
  assert.equal(orders[0].data.total, 1250);
  assert.equal(localStorage.getItem('sp-cart'), '{}');
});

test('Stage 0: opening checkout generates and persists one clientOrderId', async () => {
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
