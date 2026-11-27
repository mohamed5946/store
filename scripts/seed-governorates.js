/* One-time seed: the 27 Egypt governorates + deletion/quota config
 * (incomplete-orders design, docs/incomplete-orders-schema.md).
 *
 * Writes, with merge (never overwrites an admin-edited active list):
 *   storeSettings/governorates  { entries: [{id, name, active}], updatedAt }
 *   storeSettings/deletion      { autoDeleteDays: 0 }  (0 = manual only)
 *   storeSettings/quota         { cutoffLevel: 'none' }
 *
 * Run once, locally, by Mohamed, before the storefront ships:
 *   node scripts/seed-governorates.js [--live]
 * Dry-run is the DEFAULT — it prints what it WOULD write and writes
 * nothing. A live run needs Admin SDK credentials
 * (GOOGLE_APPLICATION_CREDENTIALS or a service-account JSON via
 * --credentials). firebase-admin is resolved from
 * functions/node_modules (already installed); if that fails it asks
 * for `npm install firebase-admin` in scripts/.
 *
 * Idempotent: a second run merges the same 27 entries without
 * touching an admin's active flags — entries that already exist
 * keep their stored `active` value; only missing entries are added
 * (active: true) and missing names are filled in. The admin screens
 * (Flutter settings tab, PC settings page) are the ongoing editor,
 * not this script.
 */

const fs = require('node:fs');
const path = require('node:path');

try {
  module.paths.push(path.join(__dirname, '..', 'functions', 'node_modules'));
} catch (_) { /* resolved at require time, with a clear error */ }

/* The 27 governorates: stable ID -> Arabic name. The single source
 * of truth is docs/incomplete-orders-schema.md; this list must match
 * it exactly (same IDs, same names, same order). */
const GOVERNORATES = [
  { id: 'cairo', name: 'القاهرة' },
  { id: 'giza', name: 'الجيزة' },
  { id: 'alexandria', name: 'الإسكندرية' },
  { id: 'dakahlia', name: 'الدقهلية' },
  { id: 'red-sea', name: 'البحر الأحمر' },
  { id: 'beheira', name: 'البحيرة' },
  { id: 'fayoum', name: 'الفيوم' },
  { id: 'gharbia', name: 'الغربية' },
  { id: 'ismailia', name: 'الإسماعيلية' },
  { id: 'menofia', name: 'المنوفية' },
  { id: 'minya', name: 'المنيا' },
  { id: 'qalyubia', name: 'القليوبية' },
  { id: 'new-valley', name: 'الوادي الجديد' },
  { id: 'suez', name: 'السويس' },
  { id: 'asyut', name: 'أسيوط' },
  { id: 'sohag', name: 'سوهاج' },
  { id: 'qena', name: 'قنا' },
  { id: 'luxor', name: 'الأقصر' },
  { id: 'aswan', name: 'أسوان' },
  { id: 'sharqia', name: 'الشرقية' },
  { id: 'port-said', name: 'بورسعيد' },
  { id: 'damietta', name: 'دمياط' },
  { id: 'kafr-el-sheikh', name: 'كفر الشيخ' },
  { id: 'beni-suef', name: 'بني سويف' },
  { id: 'matrouh', name: 'مطروح' },
  { id: 'north-sinai', name: 'شمال سيناء' },
  { id: 'south-sinai', name: 'جنوب سيناء' },
];

/* Pure merge: the stored entries win on `active`; missing entries
 * are added (active: true); missing names are filled in. Exported
 * for the unit test — run it with `node --test
 * scripts/seed-governorates.test.js` (no Firebase needed). */
function mergeGovernorateEntries(stored) {
  const byId = {};
  (Array.isArray(stored) ? stored : []).forEach((e) => {
    if (e && typeof e.id === 'string' && e.id) byId[e.id] = e;
  });
  return GOVERNORATES.map((g) => {
    const prev = byId[g.id];
    return {
      id: g.id,
      name: (prev && typeof prev.name === 'string' && prev.name) ? prev.name : g.name,
      active: prev ? prev.active === true : true,
    };
  });
}

function parseArgs(argv) {
  const args = { live: false, credentials: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--live') args.live = true;
    else if (argv[i] === '--credentials' && argv[i + 1]) args.credentials = argv[++i];
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.live) {
    console.log('[seed-governorates] DRY RUN — nothing is written. Pass --live to write.');
    console.log('[seed-governorates] Would write storeSettings/governorates with '
      + GOVERNORATES.length + ' entries (all active: true).');
    console.log('[seed-governorates] Would write storeSettings/deletion { autoDeleteDays: 0 }.');
    console.log('[seed-governorates] Would write storeSettings/quota { cutoffLevel: \'none\' }.');
    return;
  }
  let admin;
  try {
    admin = require('firebase-admin');
  } catch (e) {
    console.error('[seed-governorates] firebase-admin is not installed. Run `npm install firebase-admin` in scripts/ (or use functions/node_modules).');
    process.exit(1);
  }
  if (args.credentials) {
    const svc = JSON.parse(fs.readFileSync(args.credentials, 'utf8'));
    admin.initializeApp({ credential: admin.credential.cert(svc) });
  } else {
    admin.initializeApp();
  }
  const db = admin.firestore();
  const govRef = db.collection('storeSettings').doc('governorates');
  const govSnap = await govRef.get();
  const stored = govSnap.exists ? (govSnap.data().entries || []) : [];
  const entries = mergeGovernorateEntries(stored);
  const activeCount = entries.filter((e) => e.active).length;
  await govRef.set(
    { entries, updatedAt: admin.firestore.FieldValue.serverTimestamp() },
    { merge: true },
  );
  console.log('[seed-governorates] storeSettings/governorates: '
    + entries.length + ' entries, ' + activeCount + ' active'
    + (govSnap.exists ? ' (merged — stored active flags kept)' : ' (created)'));
  const delRef = db.collection('storeSettings').doc('deletion');
  const delSnap = await delRef.get();
  if (!delSnap.exists) {
    await delRef.set({ autoDeleteDays: 0 });
    console.log('[seed-governorates] storeSettings/deletion: created { autoDeleteDays: 0 }.');
  } else {
    console.log('[seed-governorates] storeSettings/deletion: already exists — untouched.');
  }
  const quotaRef = db.collection('storeSettings').doc('quota');
  const quotaSnap = await quotaRef.get();
  if (!quotaSnap.exists) {
    await quotaRef.set({ cutoffLevel: 'none', dailyEstimate: 0 });
    console.log('[seed-governorates] storeSettings/quota: created { cutoffLevel: \'none\' }.');
  } else {
    console.log('[seed-governorates] storeSettings/quota: already exists — untouched.');
  }
}

if (require.main === module) {
  main().catch((e) => {
    console.error('[seed-governorates] failed:', e && e.message ? e.message : e);
    process.exit(1);
  });
}

module.exports = { GOVERNORATES, mergeGovernorateEntries };
