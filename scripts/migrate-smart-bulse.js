/* One-off migration: Smart Bulse (local ERP snapshot) -> Firestore
 * (Technical Plan v1.4 §6, design doc file 37).
 *
 * Reads the Smart Bulse snapshot — the `saveAll()` shape
 *   { cfg, products, sales, purchases, customers, suppliers,
 *     returns, expenses, orders }
 * (the Electron `writeLocalSnapshot` file has the same shape minus
 * `cfg`; pass cfg separately with --config). Writes, in a LIVE run:
 *   inventory/{productId}  from products.stock / costPrice / minStock
 *                          (reserved = 0)
 *   products/{productId}   merged from the Smart Bulse product
 *                          (merge-guard: an existing Firestore product
 *                          whose updatedAt moved since the migration
 *                          started is NEVER overwritten — it is listed
 *                          for manual review instead)
 *   orders/{orderId}       translated through the v1.4 §6.1 mapping
 *                          table; unmatched records (no linked sale,
 *                          no known customer) are written with
 *                          migrationDraft: true + migrationNotes, for
 *                          manual review — never silently dropped.
 *   audit/mig_<batch>      one audit entry for the whole batch.
 * The `users` array is NEVER migrated (local accounts, may contain
 * passwords). Sales, purchases, suppliers, returns, and expenses are
 * NOT migrated (the store has no collections for them in v1.4).
 *
 * Stock note: Smart Bulse already deducts stock when a sale is
 * created, so the migrated inventory `stock` is the live value and
 * migrated orders do NOT reserve stock (reserved stays 0) — reserving
 * again would double-count the committed quantities.
 *
 * Usage (dry-run is the DEFAULT — nothing is written):
 *   node scripts/migrate-smart-bulse.js --snapshot <path> [--config <path>]
 *     [--batch <id>] [--live]
 * Live run needs Admin SDK credentials (GOOGLE_APPLICATION_CREDENTIALS
 * or a service-account JSON via --credentials). The script resolves
 * firebase-admin from functions/node_modules (already installed);
 * if that fails it asks for `npm install firebase-admin` in scripts/.
 *
 * The pure mapping functions are exported for the unit test
 * (scripts/migrate-smart-bulse.test.js) — run it with:
 *   node --test scripts/migrate-smart-bulse.test.js
 */

const fs = require('node:fs');
const path = require('node:path');

/* firebase-admin is resolved from functions/node_modules (the repo
 * already installs it there for the Cloud Functions). */
try {
  module.paths.push(path.join(__dirname, '..', 'functions', 'node_modules'));
} catch (_) { /* resolved at require time, with a clear error */ }

/* ---------- pure mapping (unit-tested) ---------- */

/* v1.4 §6.1 mapping table. late/delayed are derived flags, not
 * states — they map to in_transit (the order was shipped and is now
 * late) with the reason/delayedTo preserved + a migration note, so an
 * admin reviews them. Unknown statuses map to 'new' + a note. */
const ORDER_STATUS_MAP = {
  pending: 'new',
  shipped: 'in_transit',
  delivered: 'delivered',
  late: 'in_transit',
  delayed: 'in_transit',
};

function mapOrderStatus(sbStatus) {
  if (sbStatus === 'late' || sbStatus === 'delayed') {
    return { status: 'in_transit', flag: sbStatus };
  }
  const status = ORDER_STATUS_MAP[sbStatus];
  if (status) return { status, flag: null };
  return { status: 'new', flag: `unknown_status:${sbStatus}` };
}

/* Normalize an Egyptian phone to the merge key: digits only, 11
 * digits starting with 01 (or 12 starting with 20). Returns null
 * when the phone is not a plausible Egyptian mobile. */
function normalizePhone(raw) {
  if (raw === undefined || raw === null) return null;
  let digits = String(raw).replace(/[\s\-()]/g, '');
  if (digits.startsWith('+')) digits = digits.substring(1);
  if (digits.startsWith('00')) digits = digits.substring(2);
  if (digits.length === 11 && digits.startsWith('01')) return digits;
  if (digits.length === 12 && digits.startsWith('20')) return `0${digits.substring(2)}`;
  if (digits.length === 10 && digits.startsWith('1')) return `0${digits}`;
  return null;
}

/* Merge the Smart Bulse customers by normalized phone. Smart Bulse
 * wins on conflict: the LAST record seen for a phone wins (the most
 * recently edited), and the merge is reported. Customers without a
 * usable phone are kept under their id (they cannot merge). */
function mergeCustomers(customers) {
  const byPhone = new Map();
  const byId = new Map();
  const merged = [];
  for (const c of customers || []) {
    const phone = normalizePhone(c.phone);
    byId.set(String(c.id), c);
    if (!phone) continue;
    if (byPhone.has(phone)) merged.push({ phone, kept: c.id, dropped: byPhone.get(phone).id });
    byPhone.set(phone, c);
  }
  return { byPhone, byId, merged };
}

/* Map a sale's payStatus to the Firestore COD paymentStatus. */
function mapPaymentStatus(payStatus) {
  if (payStatus === 'paid') return 'cod_paid';
  return 'cod_pending'; // unpaid / partial / unknown: cash still pending
}

/* Build the Firestore product + inventory writes for one Smart Bulse
 * product. `categoryId` is the matched Firestore category id (or ''
 * when unmatched — the report lists it). */
function buildProductWrites(product, { categoryId = '', batchId, nowMs }) {
  const stock = Math.max(0, Math.floor(Number(product.stock) || 0));
  const price = Number(product.price) || 0;
  const productDoc = {
    name: String(product.name || '').trim(),
    price,
    description: String(product.description || '').trim(),
    categoryId,
    images: [],
    inStock: stock > 0,
    updatedAt: nowMs,
    migrationBatch: batchId,
    source: 'migration',
  };
  const inventoryDoc = {
    productId: String(product.id),
    stock,
    reserved: 0,
    minStock: Math.max(0, Math.floor(Number(product.minStock) || 5)),
    costPrice: Number(product.costPrice) || 0,
    updatedAt: nowMs,
    migrationBatch: batchId,
  };
  return { productDoc, inventoryDoc };
}

/* Build the Firestore order write for one Smart Bulse order.
 * `sale` is the linked sale (or null when unmatched), `customer` is
 * the merged customer record (or null), `productNames` maps productId
 * -> name for the item lines. Returns { orderDoc, notes, draft }. */
function buildOrderWrite(order, { sale, customer, productNames, batchId, nowMs }) {
  const notes = [];
  let draft = false;
  const { status, flag } = mapOrderStatus(order.status);
  if (flag === 'late' || flag === 'delayed') {
    notes.push(`Smart Bulse status '${flag}' is a derived flag, not a state — mapped to in_transit, review the delay`);
  } else if (flag) {
    notes.push(`Unknown Smart Bulse status '${order.status}' — mapped to new`);
    draft = true;
  }

  let items = [];
  let total = 0;
  let discountAmount = 0;
  if (sale) {
    items = (sale.items || []).map((line) => ({
      productId: String(line.productId),
      name: productNames.get(String(line.productId)) || '',
      price: Number(line.unitPrice) || 0,
      qty: Math.floor(Number(line.qty) || 0),
    })).filter((l) => l.qty > 0);
    total = Number(sale.total) || 0;
    discountAmount = Number(sale.discountAmt) || 0;
  } else {
    draft = true;
    notes.push(`Linked sale ${order.saleId || '(none)'} not found — no items/total; value kept as the total`);
    total = Number(order.value) || 0;
  }

  const customerName = (customer && customer.name) || order.customerName || '';
  const customerPhone = (customer && normalizePhone(customer.phone)) || '';
  const customerAddress = (customer && customer.address) || '';
  if (!customer) {
    draft = true;
    notes.push(`Customer ${order.customerId || '(none)'} not found in the snapshot`);
  }

  const createdAt = (sale && sale.date) || order.shipDate || null;
  const orderDoc = {
    id: String(order.id),
    clientOrderId: String(order.id),
    customerName: String(customerName).trim(),
    customerPhone: String(customerPhone).trim(),
    customerAddress: String(customerAddress).trim(),
    items,
    subtotal: total + discountAmount,
    discountCode: null,
    discountPercent: 0,
    discountAmount,
    total,
    status,
    paymentStatus: sale ? mapPaymentStatus(sale.payStatus) : 'cod_pending',
    source: 'migration',
    createdBy: null,
    shippingCompanyId: null,
    trackingNumber: null,
    notes: String(order.notes || '').trim() || null,
    createdAt,
    updatedAt: nowMs,
    acceptedAt: null,
    deliveredAt: status === 'delivered' ? createdAt : null,
    cancelledAt: null,
    cancelReason: null,
    migrationBatch: batchId,
    migrationDraft: draft,
    migrationNotes: notes,
  };
  if (order.reason) orderDoc.migrationReason = String(order.reason);
  if (order.delayedTo) orderDoc.migrationDelayedTo = String(order.delayedTo);
  if (order.shipDate) orderDoc.migrationShipDate = String(order.shipDate);
  if (order.dueDate) orderDoc.migrationDueDate = String(order.dueDate);
  if (order.receivedDate) orderDoc.migrationReceivedDate = String(order.receivedDate);
  return { orderDoc, notes, draft };
}

/* ---------- CLI ---------- */

function parseArgs(argv) {
  const args = { live: false, batch: null, snapshot: null, config: null, credentials: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--live') args.live = true;
    else if (a === '--snapshot') args.snapshot = argv[++i];
    else if (a === '--config') args.config = argv[++i];
    else if (a === '--credentials') args.credentials = argv[++i];
    else if (a === '--batch') args.batch = argv[++i];
    else if (a === '--project') args.project = argv[++i];
    else throw new Error(`Unknown argument: ${a}`);
  }
  if (!args.snapshot) throw new Error('Missing --snapshot <path> (the Smart Bulse snapshot JSON)');
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const batchId = args.batch || `mig_${new Date().toISOString().slice(0, 16).replace(/[-:T]/g, '')}`;
  const startedAt = Date.now();

  const snapshot = JSON.parse(fs.readFileSync(args.snapshot, 'utf8'));
  let cfg = snapshot.cfg || null;
  if (args.config) cfg = JSON.parse(fs.readFileSync(args.config, 'utf8'));
  const products = snapshot.products || [];
  const sales = snapshot.sales || [];
  const customers = snapshot.customers || [];
  const orders = snapshot.orders || [];
  const users = snapshot.users || [];
  if (users.length > 0) {
    console.log(`NOTE: ${users.length} local user(s) in the snapshot are NEVER migrated (may contain passwords).`);
  }
  if (cfg) console.log(`Config: company=${cfg.companyName || ''} currency=${cfg.currency || ''} lowStockLimit=${cfg.lowStockLimit ?? ''}`);

  const { byPhone, byId, merged } = mergeCustomers(customers);
  const salesById = new Map(sales.map((s) => [String(s.id), s]));
  const productNames = new Map(products.map((p) => [String(p.id), String(p.name || '')]));

  /* --- plan the writes (pure, no Firestore) --- */
  const productWrites = products.map((p) => ({
    id: String(p.id),
    ...buildProductWrites(p, { batchId, nowMs: startedAt }),
  }));
  const orderWrites = orders.map((o) => {
    const sale = o.saleId ? salesById.get(String(o.saleId)) || null : null;
    const customer = (o.customerId && byId.get(String(o.customerId))) || null;
    return { id: String(o.id), ...buildOrderWrite(o, { sale, customer, productNames, batchId, nowMs: startedAt }) };
  });
  const drafts = orderWrites.filter((o) => o.draft);
  const plan = {
    batchId,
    snapshot: args.snapshot,
    startedAt: new Date(startedAt).toISOString(),
    counts: {
      products: products.length,
      customers: customers.length,
      customersMerged: merged.length,
      sales: sales.length,
      orders: orders.length,
      draftOrders: drafts.length,
      usersSkipped: users.length,
    },
    mergedCustomers: merged,
    draftOrders: drafts.map((o) => ({ id: o.id, notes: o.notes })),
    products: productWrites.map((p) => ({ id: p.id, productDoc: p.productDoc, inventoryDoc: p.inventoryDoc })),
    orders: orderWrites.map((o) => ({ id: o.id, orderDoc: o.orderDoc })),
  };

  console.log(`\nMigration batch ${batchId} — ${args.live ? 'LIVE' : 'DRY RUN (nothing written)'}`);
  console.log(`  products: ${products.length} (product + inventory each)`);
  console.log(`  customers: ${customers.length} (${merged.length} merged by phone)`);
  console.log(`  sales: ${sales.length} (linked, not migrated)`);
  console.log(`  orders: ${orders.length} (${drafts.length} draft — see below)`);
  if (drafts.length > 0) {
    console.log('  draft orders (manual review):');
    for (const d of drafts) console.log(`    - ${d.id}: ${d.notes.join('; ')}`);
  }
  if (merged.length > 0) {
    console.log('  merged customers (Smart Bulse wins):');
    for (const m of merged) console.log(`    - phone ${m.phone}: kept ${m.kept}, dropped ${m.dropped}`);
  }

  const planPath = path.join(__dirname, `migration-plan-${batchId}.json`);
  fs.writeFileSync(planPath, JSON.stringify(plan, null, 2));
  console.log(`  plan written to ${planPath}`);

  if (!args.live) {
    console.log('\nDry run only. Review the plan, then re-run with --live to write it.');
    console.log('Live run needs Admin SDK credentials (GOOGLE_APPLICATION_CREDENTIALS or --credentials <service-account.json>).');
    return;
  }

  /* --- live run (Admin SDK, bypasses rules) --- */
  let admin;
  try {
    admin = require('firebase-admin');
  } catch (e) {
    throw new Error('firebase-admin is not installed. Run `npm install firebase-admin` in scripts/ (or make sure functions/node_modules exists).');
  }
  if (args.credentials) {
    const serviceAccount = JSON.parse(fs.readFileSync(args.credentials, 'utf8'));
    admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
  } else {
    admin.initializeApp();
  }
  const db = admin.firestore();

  /* Match Smart Bulse category names to Firestore category ids (one read). */
  const catSnap = await db.collection('categories').get();
  const categoryByName = new Map();
  for (const d of catSnap.docs) {
    const name = String(d.data().name || '').trim().toLowerCase();
    if (name) categoryByName.set(name, d.id);
  }
  const unmatchedCategories = new Set();

  let writtenProducts = 0;
  let writtenInventory = 0;
  let skippedProducts = [];
  let writtenOrders = 0;
  const docIds = {};

  /* Products + inventory, in batches of 400 (Firestore batch cap 500). */
  const productOps = [];
  for (const p of productWrites) {
    const sbProduct = products.find((x) => String(x.id) === p.id);
    const categoryName = String(sbProduct.category || '').trim().toLowerCase();
    let categoryId = '';
    if (categoryName) {
      if (categoryByName.has(categoryName)) categoryId = categoryByName.get(categoryName);
      else unmatchedCategories.add(sbProduct.category);
    }
    productOps.push({ ...p, categoryId });
  }
  for (let i = 0; i < productOps.length; i += 400) {
    const chunk = productOps.slice(i, i + 400);
    const batch = db.batch();
    for (const p of chunk) {
      /* Merge-guard: never overwrite a Firestore product whose
       * updatedAt moved since the migration started. */
      const existing = await db.collection('products').doc(p.id).get();
      if (existing.exists) {
        const updatedAt = existing.data().updatedAt;
        const updatedMs = updatedAt && updatedAt.toMillis ? updatedAt.toMillis() : 0;
        if (updatedMs > startedAt) {
          skippedProducts.push({ id: p.id, reason: 'updatedAt moved during the migration — manual review' });
          continue;
        }
      }
      const productDoc = {
        ...p.productDoc,
        categoryId: p.categoryId,
        updatedAt: admin.firestore.Timestamp.fromMillis(startedAt),
      };
      const inventoryDoc = {
        ...p.inventoryDoc,
        updatedAt: admin.firestore.Timestamp.fromMillis(startedAt),
      };
      batch.set(db.collection('products').doc(p.id), productDoc, { merge: true });
      batch.set(db.collection('inventory').doc(p.id), inventoryDoc, { merge: true });
      docIds[`products/${p.id}`] = Object.keys(productDoc);
      docIds[`inventory/${p.id}`] = Object.keys(p.inventoryDoc);
      writtenProducts += 1;
      writtenInventory += 1;
    }
    await batch.commit();
  }

  /* Orders, in batches of 400. */
  for (let i = 0; i < orderWrites.length; i += 400) {
    const chunk = orderWrites.slice(i, i + 400);
    const batch = db.batch();
    for (const o of chunk) {
      const doc = { ...o.orderDoc };
      /* createdAt: the sale date (ISO string) -> Timestamp; the
       * numeric updatedAt stays a number (the app reads both). */
      if (typeof doc.createdAt === 'string') {
        doc.createdAt = admin.firestore.Timestamp.fromDate(new Date(doc.createdAt));
      }
      doc.updatedAt = admin.firestore.Timestamp.fromMillis(startedAt);
      if (doc.deliveredAt && typeof doc.deliveredAt === 'string') {
        doc.deliveredAt = admin.firestore.Timestamp.fromDate(new Date(doc.deliveredAt));
      }
      batch.set(db.collection('orders').doc(o.id), doc, { merge: true });
      docIds[`orders/${o.id}`] = Object.keys(doc);
      writtenOrders += 1;
    }
    await batch.commit();
  }

  /* One audit entry for the whole batch (Admin SDK — the rules do not
   * gate it; docIds is capped at 500 entries to stay well under the
   * 1 MB document limit). */
  const docIdEntries = Object.entries(docIds).slice(0, 500);
  await db.collection('audit').doc(batchId).set({
    operationId: batchId,
    actor: 'migration',
    actorName: 'migration',
    timestamp: admin.firestore.Timestamp.fromMillis(startedAt),
    collection: 'migration',
    docId: batchId,
    operation: 'migration',
    changedFields: ['migration'],
    oldValues: {},
    newValues: { products: writtenProducts, inventory: writtenInventory, orders: writtenOrders, drafts: drafts.length },
    docIds: Object.fromEntries(docIdEntries),
    newValuesByDoc: {},
    documents: [],
    source: 'migrate-smart-bulse',
  });

  console.log('\nLive run done:');
  console.log(`  products written: ${writtenProducts} (skipped: ${skippedProducts.length})`);
  console.log(`  inventory written: ${writtenInventory}`);
  console.log(`  orders written: ${writtenOrders} (${drafts.length} draft)`);
  if (skippedProducts.length > 0) {
    console.log('  skipped products (manual review):');
    for (const s of skippedProducts) console.log(`    - ${s.id}: ${s.reason}`);
  }
  if (unmatchedCategories.size > 0) {
    console.log('  unmatched categories (products written with an empty categoryId):');
    for (const c of unmatchedCategories) console.log(`    - ${c}`);
  }
  console.log(`  audit entry: audit/${batchId}`);
}

if (require.main === module) {
  main().catch((e) => {
    console.error(`Migration failed: ${e.message}`);
    process.exit(1);
  });
}

module.exports = { mapOrderStatus, normalizePhone, mergeCustomers, mapPaymentStatus, buildProductWrites, buildOrderWrite, parseArgs };
