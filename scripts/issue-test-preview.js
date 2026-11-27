/* One-time test: issue a single real preview slug for the bazaar
 * template (1.0.0) so the ?preview= flow can be tested end-to-end
 * in a real browser. Created 2026-11-27 because Mohamed opened a
 * preview link from the Android app and saw the live (classic)
 * site instead of the draft template — the real-slug path had
 * never been tested before shipping.
 *
 * Run via the admin-seed.yml workflow (WIF identity), target
 * issue-test-preview — never run with a personal credential.
 *   node scripts/issue-test-preview.js
 *   node scripts/issue-test-preview.js --list   (read-only: list all
 *     previews docs — used to recover a slug if a run crashed after
 *     writing but before printing the URL; writes nothing)
 *
 * Writes exactly ONE document: previews/{slug} with
 * {templateId: 'bazaar', version: '1.0.0',
 *  issuedAt: serverTimestamp, issuedBy: 'selena-test',
 *  status: 'open'}.
 * Prints the full preview URL. Does NOT touch the pointer
 * (storeSettings/activeTemplate), the registry, the brand, or any
 * other collection. The slug stays OPEN — this script never revokes
 * it, so the browser test can use it.
 *
 * Slug shape matches generatePreviewSlug() in the Flutter app
 * (lib/services/templates_service.dart): 16 random bytes ->
 * base64url, no padding = 22 URL-safe chars, 128-bit unguessable.
 */

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

try {
  module.paths.push(path.join(__dirname, '..', 'functions', 'node_modules'));
} catch (_) { /* resolved at require time, with a clear error */ }

const STOREFRONT_BASE_URL = 'https://store-3384c.web.app';

function generatePreviewSlug() {
  // Same shape as the Flutter app: 16 random bytes -> base64url,
  // no padding (22 chars).
  return crypto.randomBytes(16).toString('base64url');
}

async function main() {
  let admin;
  try {
    admin = require('firebase-admin');
  } catch (e) {
    console.error('firebase-admin is not installed. Run `npm ci --prefix functions` first.');
    process.exit(1);
  }

  const credArg = process.argv.find((a) => a.startsWith('--credentials='));
  if (credArg) {
    const serviceAccount = JSON.parse(fs.readFileSync(credArg.slice('--credentials='.length), 'utf8'));
    admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
  } else if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    admin.initializeApp({ credential: admin.credential.applicationDefault() });
  } else {
    console.error('Needs Admin SDK credentials (GOOGLE_APPLICATION_CREDENTIALS or --credentials <service-account.json>).');
    process.exit(1);
  }

  const listOnly = process.argv.includes('--list');

  const slug = generatePreviewSlug();
  const db = admin.firestore();

  if (listOnly) {
    const snap = await db.collection('previews').get();
    console.log(`[issue-test-preview] LIST — ${snap.size} previews doc(s):`);
    snap.forEach((d) => {
      const v = d.data() || {};
      console.log(`[issue-test-preview]   ${d.id} templateId=${v.templateId} version=${v.version} status=${v.status} issuedBy=${v.issuedBy}`);
    });
    process.exit(0);
  }

  const ref = db.collection('previews').doc(slug);
  await ref.set({
    templateId: 'bazaar',
    version: '1.0.0',
    issuedAt: admin.firestore.FieldValue.serverTimestamp(),
    issuedBy: 'selena-test',
    status: 'open',
  });

  // Read back to prove the write landed before printing the URL.
  // (Admin SDK: DocumentSnapshot.exists is a PROPERTY, not a method.)
  const snap = await ref.get();
  if (!snap.exists) {
    console.error(`[issue-test-preview] FAILED — previews/${slug} does not exist after write.`);
    process.exit(1);
  }
  const d = snap.data();
  console.log(`[issue-test-preview] WROTE previews/${slug}: templateId=${d.templateId} version=${d.version} status=${d.status} issuedBy=${d.issuedBy}`);
  console.log(`[issue-test-preview] PREVIEW_URL=${STOREFRONT_BASE_URL}/?preview=${slug}`);
  process.exit(0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
