/* One-time cleanup: delete every document in the `discounts` collection.
 *
 * The discount-code (promo code) feature was REMOVED 2026-11-27 by Mohamed's
 * decision («شيل لي كود الخصم خالص»). The code is gone from all three
 * clients, the rules, and the tests — but any `discounts/{code}` documents
 * created live before the removal still sit in Firestore. They are dead
 * data (nothing reads them any more) and must go so no trace of the
 * removed feature remains.
 *
 * Run once, at deploy time, by Mohamed (or the deploy run), AFTER the
 * removal build ships:
 *   node scripts/delete-discounts.js            (dry run — lists only)
 *   node scripts/delete-discounts.js --live     (actually deletes)
 *
 * Dry-run is the DEFAULT — it prints every `discounts` doc it WOULD
 * delete (id, percent, active, usedBy) and deletes nothing. A live run
 * needs Admin SDK credentials (GOOGLE_APPLICATION_CREDENTIALS or a
 * service-account JSON via --credentials). firebase-admin is resolved
 * from functions/node_modules (already installed); if that fails it asks
 * for `npm install firebase-admin` in scripts/.
 *
 * Safe to re-run: a second run finds zero docs and deletes nothing.
 * Legacy ORDERS that carry discountCode/discountPercent/discountAmount
 * fields are NOT touched by this script — the rules keep those keys in
 * the order allow-list (ignored) so old orders stay updatable.
 */

const fs = require('node:fs');
const path = require('node:path');

try {
  module.paths.push(path.join(__dirname, '..', 'functions', 'node_modules'));
} catch (_) { /* resolved at require time, with a clear error */ }

const args = process.argv.slice(2);
const live = args.includes('--live');
const credArg = args.find((a) => a.startsWith('--credentials='));
const credentialsPath = credArg ? credArg.slice('--credentials='.length) : null;

async function main() {
  let admin;
  try {
    admin = require('firebase-admin');
  } catch (e) {
    console.error('firebase-admin is not installed. Run `npm install firebase-admin` in scripts/ first.');
    process.exit(1);
  }

  if (!live) {
    // Dry run still needs read access to LIST the docs — same credentials.
    console.log('DRY RUN — listing only, deleting nothing. Pass --live to delete.');
  }

  if (credentialsPath) {
    const serviceAccount = JSON.parse(fs.readFileSync(credentialsPath, 'utf8'));
    admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
  } else if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    admin.initializeApp({ credential: admin.credential.applicationDefault() });
  } else {
    console.error('Live run needs Admin SDK credentials (GOOGLE_APPLICATION_CREDENTIALS or --credentials <service-account.json>).');
    process.exit(1);
  }

  const db = admin.firestore();
  const snap = await db.collection('discounts').get();
  if (snap.empty) {
    console.log('No documents in `discounts` — nothing to delete.');
    return;
  }

  console.log(`Found ${snap.size} document(s) in \`discounts\`:`);
  snap.forEach((d) => {
    const v = d.data() || {};
    console.log(`  - ${d.id}: percent=${v.percent ?? '—'} active=${v.active ?? '—'} usedBy=${v.usedBy ?? '—'}`);
  });

  if (!live) {
    console.log('Dry run done — nothing deleted. Re-run with --live to delete them.');
    return;
  }

  // Delete in batches of 400 (Firestore batch limit is 500).
  const docs = snap.docs;
  for (let i = 0; i < docs.length; i += 400) {
    const batch = db.batch();
    docs.slice(i, i + 400).forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }
  console.log(`Deleted ${docs.length} document(s) from \`discounts\`.`);
}

main().catch((e) => {
  console.error('FAILED:', e && e.message ? e.message : e);
  process.exit(1);
});
