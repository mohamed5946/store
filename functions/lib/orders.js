/* Order transaction core (design doc file 27, Technical Plan v1.4 §6).
 *
 * The SINGLE implementation of price, stock, discount, and total
 * verification, used by both placeOrder and createManualOrder — so the
 * two order paths can never drift apart. Takes a Firestore interface
 * (real Admin SDK or the test fake); no firebase-admin import here, so
 * the unit tests run this exact code. `serverTimestamp` is injected by
 * the caller (admin.firestore.FieldValue.serverTimestamp() in prod, a
 * ms number in tests).
 *
 * Flow (one atomic transaction):
 *   idempotency check (order exists by clientOrderId -> return it)
 *   read products + inventory -> read discount (if a code was given)
 *   verify qty <= available -> price/total check (seenPrices/seenTotal)
 *   compute total from DATABASE prices -> reserve stock -> claim code
 *   create order (doc id = clientOrderId) -> update inStock ->
 *   movements entries -> audit entry.
 * Any failure aborts the whole transaction: no order, no stock move,
 * no code consumption (T8).
 */

const {
  OrderError, dedupeItems, validateOrderInput, computeTotal,
  checkSeenPrices, MAX_PRODUCTS_PER_ORDER,
} = require('./validation');

/* The unified order state machine (v1.4 Decision 23). Allowed
 * transitions; anything else is denied by the rules and rejected here. */
const ORDER_TRANSITIONS = {
  new: ['accepted', 'cancelled', 'expired'],
  accepted: ['preparing', 'cancelled'],
  preparing: ['ready', 'cancelled'],
  ready: ['in_transit', 'cancelled'],
  in_transit: ['delivered'],
  delivered: [],
  cancelled: [],
  expired: [],
};

function isAllowedTransition(from, to) {
  return (ORDER_TRANSITIONS[from] || []).includes(to);
}

/* Create an order inside ONE transaction. `db` is the Firestore
 * interface; `opts` carries the request (already shape-validated by the
 * caller). Returns { order, created } — created:false means the
 * idempotency check found the existing order and returned it (T5/T17).
 * Throws OrderError with a structured code on any validation failure. */
async function createOrderTx(db, opts) {
  const {
    clientOrderId, items, discountCode, customer, source, createdBy,
    shippingCompanyId, notes, seenPrices, seenTotal, serverTimestamp,
  } = opts;

  const shapeError = validateOrderInput({ customer, items, discountCode });
  if (shapeError === 'ORDER_TOO_LARGE') {
    throw new OrderError('ORDER_TOO_LARGE', 'الطلب فيه منتجات أكتر من الحد المسموح', {
      maxProducts: MAX_PRODUCTS_PER_ORDER,
    });
  }
  if (shapeError) throw new OrderError('INVALID_INPUT', shapeError);

  const merged = dedupeItems(items);
  if (merged.length > MAX_PRODUCTS_PER_ORDER) {
    throw new OrderError('ORDER_TOO_LARGE', 'الطلب فيه منتجات أكتر من الحد المسموح', {
      maxProducts: MAX_PRODUCTS_PER_ORDER,
    });
  }

  const orderRef = db.collection('orders').doc(clientOrderId);
  let result;
  await db.runTransaction(async (tx) => {
    /* Idempotency FIRST: a retry with the same clientOrderId returns the
     * existing order — no stock work, no discount work, no duplicate. */
    const existing = await tx.get(orderRef);
    if (existing.exists) {
      result = { order: { id: existing.id, ...existing.data() }, created: false };
      return;
    }

    /* Read products + inventory (one read per line). */
    const lines = [];
    const dbPrices = {};
    for (const line of merged) {
      const productSnap = await tx.get(db.collection('products').doc(line.productId));
      if (!productSnap.exists) {
        throw new OrderError('INVALID_INPUT', 'منتج مش موجود في المتجر');
      }
      const product = productSnap.data();
      const price = Number(product.price);
      if (!Number.isFinite(price) || price <= 0) {
        throw new OrderError('INVALID_INPUT', 'سعر المنتج مش صحيح');
      }
      const invSnap = await tx.get(db.collection('inventory').doc(line.productId));
      const inv = invSnap.exists ? invSnap.data() : { stock: 0, reserved: 0 };
      const available = (inv.stock || 0) - (inv.reserved || 0);
      if (line.qty > available) {
        throw new OrderError('INSUFFICIENT_STOCK', 'الكمية المطلوبة أكبر من المتاح', {
          productId: line.productId, availableQty: Math.max(available, 0),
        });
      }
      lines.push({ productId: line.productId, name: product.name, price, qty: line.qty, available });
      dbPrices[line.productId] = price;
    }

    /* Discount: read the trusted record, verify, claim atomically. A
     * forged discount sent by the client is impossible — only the code
     * string is accepted, and it is recomputed from the database. */
    let discount = null;
    if (discountCode) {
      const code = String(discountCode).trim();
      const discSnap = await tx.get(db.collection('discounts').doc(code));
      if (!discSnap.exists) {
        throw new OrderError('DISCOUNT_INVALID', 'كود الخصم مش صحيح');
      }
      const record = discSnap.data();
      if (!record.active) throw new OrderError('DISCOUNT_INVALID', 'كود الخصم مش فعال');
      if (record.usedBy) {
        throw new OrderError('DISCOUNT_USED', 'كود الخصم ده اتستخدم قبل كده');
      }
      if (record.expiresAt && record.expiresAt < Date.now()) {
        throw new OrderError('DISCOUNT_INVALID', 'كود الخصم انتهت صلاحيته');
      }
      const percent = Number(record.percent);
      if (!Number.isInteger(percent) || percent < 1 || percent > 100) {
        throw new OrderError('DISCOUNT_INVALID', 'كود الخصم مش صحيح');
      }
      discount = { code, percent, ref: db.collection('discounts').doc(code) };
    }

    /* Total from the DATABASE prices, then the seen-price check: a price
     * or total that changed since the client loaded the page rejects the
     * order (PRICE_CHANGED / TOTAL_CHANGED) and creates nothing. */
    const computed = computeTotal(lines, discount);
    const seen = checkSeenPrices({ seenPrices, seenTotal, dbPrices, computed });
    if (seen && seen.error) throw seen.error;

    /* Reserve stock + update the derived inStock flag in the SAME
     * transaction, so the storefront and the admin apps never disagree
     * about availability (v1.4 §6.3). */
    const now = serverTimestamp();
    for (const line of lines) {
      const invRef = db.collection('inventory').doc(line.productId);
      const invSnap = await tx.get(invRef);
      const inv = invSnap.exists ? invSnap.data() : { stock: 0, reserved: 0 };
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
      tx.set(db.collection('products').doc(line.productId), {
        inStock: newAvailable > 0,
      }, { merge: true });
      tx.set(db.collection('movements').doc(), {
        productId: line.productId,
        type: 'order_reserve',
        qty: -line.qty,
        orderId: clientOrderId,
        source: source === 'admin_manual' ? 'createManualOrder' : 'placeOrder',
        actorUid: createdBy || null,
        createdAt: now,
      });
    }

    /* Claim the discount (one use only, atomically inside this tx). */
    if (discount) {
      tx.set(discount.ref, { usedBy: clientOrderId, usedAt: now }, { merge: true });
    }

    /* Create the order (doc id = clientOrderId). */
    const order = {
      id: clientOrderId,
      clientOrderId,
      customerName: String(customer.name).trim(),
      customerPhone: String(customer.phone).trim(),
      customerAddress: String(customer.address).trim(),
      items: lines.map((l) => ({ productId: l.productId, name: l.name, price: l.price, qty: l.qty })),
      subtotal: computed.subtotal,
      discountCode: discount ? discount.code : null,
      discountPercent: computed.discountPercent,
      discountAmount: computed.discountAmount,
      total: computed.total,
      status: 'new',
      paymentStatus: 'cod_pending',
      source,
      createdBy: createdBy || null,
      shippingCompanyId: shippingCompanyId || null,
      trackingNumber: null,
      notes: notes || null,
      createdAt: now,
      updatedAt: now,
      acceptedAt: null,
      deliveredAt: null,
      cancelledAt: null,
      cancelReason: null,
    };
    tx.set(orderRef, order);

    /* Audit entry inside the same transaction (enforced by construction).
     * The audit document's id IS the operationId — the ref is created
     * first so its id is known before the write. The order's audit
     * records the order id + the admin uid (for manual orders) + the
     * total — not the customer's full PII. */
    const auditRef = db.collection('audit').doc();
    tx.set(auditRef, {
      operationId: auditRef.id,
      actor: createdBy || 'anonymous',
      actorName: createdBy || 'storefront',
      timestamp: now,
      collection: 'orders',
      docId: clientOrderId,
      operation: source === 'admin_manual' ? 'manual_order_create' : 'create',
      changedFields: ['status', 'total'],
      oldValues: {},
      newValues: { status: 'new', total: computed.total },
      /* The docIds index map (same shape the client-written audit
       * entries carry, v1.2 §11): the rules read it, the apps read the
       * documents array — one audit shape regardless of the writer. */
      docIds: { [`orders/${clientOrderId}`]: ['status', 'total'] },
      newValuesByDoc: { [`orders/${clientOrderId}`]: { status: 'new', total: computed.total } },
      documents: [{
        collection: 'orders', docId: clientOrderId,
        changedFields: ['status', 'total'], oldValues: {}, newValues: { status: 'new', total: computed.total },
      }],
      source: source === 'admin_manual' ? 'createManualOrder' : 'placeOrder',
    });

    result = { order, created: true };
  });

  return result;
}

/* Release a reservation (shared by the sweep and by cancel paths).
 * `tx` is the active transaction; `order` is the order document data.
 * The caller already verified the order is still in 'new' status and
 * the TTL expired (sweep) or the admin cancelled it. Updates inventory,
 * inStock, movements, and the order status — all in the same tx. */
async function releaseReservationTx(db, tx, order, { movementType, newStatus, now, actorUid, source }) {
  for (const line of order.items || []) {
    const invRef = db.collection('inventory').doc(line.productId);
    const invSnap = await tx.get(invRef);
    if (!invSnap.exists) continue;
    const inv = invSnap.data();
    const newReserved = Math.max((inv.reserved || 0) - line.qty, 0);
    const newAvailable = (inv.stock || 0) - newReserved;
    tx.set(invRef, { reserved: newReserved, updatedAt: now }, { merge: true });
    tx.set(db.collection('products').doc(line.productId), {
      inStock: newAvailable > 0,
    }, { merge: true });
    tx.set(db.collection('movements').doc(), {
      productId: line.productId,
      type: movementType,
      qty: line.qty,
      orderId: order.id,
      source,
      actorUid: actorUid || null,
      createdAt: now,
    });
  }
  const orderRef = db.collection('orders').doc(order.id);
  const update = { status: newStatus, updatedAt: now };
  if (newStatus === 'expired') update.cancelReason = 'reservation_expired';
  tx.set(orderRef, update, { merge: true });
  const auditRef = db.collection('audit').doc();
  tx.set(auditRef, {
    operationId: auditRef.id,
    actor: actorUid || 'sweep',
    actorName: actorUid || 'sweep',
    timestamp: now,
    collection: 'orders',
    docId: order.id,
    operation: 'status_change',
    changedFields: ['status'],
    oldValues: { status: order.status },
    newValues: { status: newStatus },
    docIds: { [`orders/${order.id}`]: ['status'] },
    newValuesByDoc: { [`orders/${order.id}`]: { status: newStatus } },
    documents: [{
      collection: 'orders', docId: order.id,
      changedFields: ['status'], oldValues: { status: order.status }, newValues: { status: newStatus },
    }],
    source,
  });
}

module.exports = { createOrderTx, releaseReservationTx, isAllowedTransition, ORDER_TRANSITIONS };
