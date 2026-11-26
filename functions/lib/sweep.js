/* Reservation sweep + scheduled Firestore export
 * (Technical Plan v1.4 §5.6, §5.14).
 *
 * sweepExpiredReservations: every hour, releases reservations whose
 * 24-hour TTL expired while the order is still in 'new' status. The
 * release requires the order to still be 'new' AND the TTL expired
 * inside the transaction, so a re-run is a no-op (idempotent by
 * construction, v1.4 §5.4). Single-field query (status only — no
 * composite index needed); the TTL is filtered in code.
 *
 * scheduledFirestoreExport: weekly export of Firestore to Cloud Storage
 * (the safety net for manual recovery — never applied automatically).
 * Uses the Firestore Admin REST API (exportDocuments) with an access
 * token from the Admin SDK credentials. Writes the outcome to
 * health/{check} either way, so a failed export is visible, not silent.
 */

const { toMillis, RESERVATION_TTL_MS } = require('./validation');
const { releaseReservationTx } = require('./orders');

/* Release every expired 'new' order. Returns { released, checked }. */
async function sweepExpiredReservations(db, { now, serverTimestamp }) {
  const snap = await db.collection('orders').where('status', '==', 'new').limit(500).get();
  let checked = 0;
  let released = 0;
  for (const doc of snap.docs) {
    const order = { id: doc.id, ...doc.data() };
    checked += 1;
    if (now - toMillis(order.createdAt) <= RESERVATION_TTL_MS) continue;
    const did = await db.runTransaction(async (tx) => {
      const fresh = await tx.get(db.collection('orders').doc(order.id));
      if (!fresh.exists) return false;
      const current = { id: fresh.id, ...fresh.data() };
      if (current.status !== 'new') return false;
      if (now - toMillis(current.createdAt) <= RESERVATION_TTL_MS) return false;
      await releaseReservationTx(db, tx, current, {
        movementType: 'reservation_expire',
        newStatus: 'expired',
        now: serverTimestamp(),
        actorUid: 'sweep',
        source: 'sweep',
      });
      return true;
    });
    if (did) released += 1;
  }
  return { released, checked };
}

/* Weekly Firestore export via the Admin REST API. `fetchImpl` and
 * `getAccessToken` are injected so the unit tests can stub the network;
 * in prod they are the global fetch and the Admin SDK credential. */
async function exportFirestore(db, {
  projectId, bucket, now, serverTimestamp, fetchImpl, getAccessToken,
}) {
  const date = new Date(now).toISOString().slice(0, 10);
  const outputUriPrefix = `gs://${bucket}/firestore-exports/${date}`;
  let status = 'ok';
  let detail = `Export started to ${outputUriPrefix}`;
  try {
    const token = await getAccessToken();
    const res = await fetchImpl(
      `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default):exportDocuments`,
      {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ outputUriPrefix }),
      },
    );
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new Error(`exportDocuments ${res.status}: ${text.slice(0, 200)}`);
    }
    const body = await res.json().catch(() => ({}));
    detail = `Export started: ${body.name || outputUriPrefix}`;
  } catch (e) {
    status = 'degraded';
    detail = `Export failed: ${e.message}`;
  }
  await db.collection('health').doc('firestore-export').set({
    check: 'firestore-export', status, detail, checkedAt: serverTimestamp(),
  }, { merge: true });
  return { status, detail };
}

module.exports = { sweepExpiredReservations, exportFirestore };
