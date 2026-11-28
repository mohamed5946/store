/* One-time registry seed: write the six template registry documents
 * (`templates/{id}`) from the on-disk bundle manifests.
 *
 * The five new templates (bazaar, gallery, scroll, speclab, boutique)
 * ship as versioned file bundles on Firebase Hosting, but their
 * registry documents do not exist in Firestore yet — nothing ever
 * wrote them: the admin apps only seed `templates/classic` (on first
 * activation), there is no in-app register flow, and no deploy step
 * writes them. Without a registry doc, activation throws
 * «القالب مش موجود» (TemplatesService.activateTemplate requires the
 * doc to exist) and the template cannot be reviewed, approved, or
 * activated at all.
 *
 * Run once, at deploy time, AFTER the bundles are live on Hosting:
 *   node scripts/write-template-registry.js            (dry run — lists only)
 *   node scripts/write-template-registry.js --live     (actually writes)
 *
 * After a bundle is FIXED and re-hashed, its registry doc must follow
 * the new hash or the shell refuses the bundle (gateway hash
 * mismatch -> fallback to classic). The plain run SKIPs existing
 * docs, so a re-hash needs the update mode:
 *   node scripts/write-template-registry.js --update            (dry run)
 *   node scripts/write-template-registry.js --live --update     (actually updates)
 * Update mode only touches docs whose stored bundleHash / version /
 * shellMinVersion differ from the manifest, and only while the doc
 * is still unapproved (status draft/preview, no approval record) —
 * an approved/active doc is REFUSED here: changing its hash would
 * silently invalidate its approval freeze, and that must go through
 * the admin re-approval flow instead. The update merges
 * {bundleHash, version, shellMinVersion, updatedAt} only — status,
 * approval, createdAt and everything else are preserved.
 *
 * Dry-run is the DEFAULT — it prints every doc it WOULD write (id,
 * version, shellMinVersion, bundleHash, status) and writes nothing.
 * A live run needs Admin SDK credentials (GOOGLE_APPLICATION_CREDENTIALS
 * or a service-account JSON via --credentials). firebase-admin is
 * resolved from functions/node_modules (already installed); if that
 * fails it asks for `npm install firebase-admin` in scripts/.
 *
 * Source of truth: the on-disk manifests
 * `storefront/templates/{id}/1.0.0/manifest.json` — the script reads
 * id / nameAr / nameEn / version / shellMinVersion / bundleHash from
 * them, so the registry can never drift from the deployed bundles.
 * Verified on-disk hashes at writing time (2026-11-27):
 *   bazaar   d0854a7ac8524ba84a6cd89d6af763881653cf14e7ae1a5f7afa71ac707d1b27
 *            (re-hashed 2026-11-27: fake-countdown section removed,
 *            shell price-row fix; was 9e6e0694b5f8548f45379cd0accb3ae8c9d1fa65a045fd8e3bd9bc31ae5905b5)
 *   gallery  36bebe143b99e739d06b7894d6d9e44327fc9f1af51c8f5620cbdaedb3a65bf7
 *   scroll   8f49c35706545dc0c187c67435fd209179769c0dde43185921b9daade2b4c7dd
 *   speclab  795a4b826d5a0def0dae957c2c7184e08844b73775497a5df4e1ff7b277db9fa
 *   boutique 74f512607c3a0798e7b86b6257494f6e8745259d92a1214108ea7dd9df19437a
 *   classic  3dd0030c445a80099425b4ad4493210c61e653fff0922001b78c826afd5cb703
 *
 * What it writes per doc: {id, nameAr, nameEn, version,
 * shellMinVersion, bundleHash, status, previewImageUrl, createdAt,
 * updatedAt}. The five new templates start as `draft` (the admin
 * review flow moves draft -> preview -> approved -> active);
 * classic is written as `active` (the brief's cutover step + the
 * app's own seed shape). No `approval` / `validation` yet — those
 * come from the admin review flow. Existing docs are SKIPPED, never
 * overwritten, by the plain run (safe to re-run); use --update after
 * a re-hash (see above).
 *
 * This script uses the Admin SDK, which bypasses Firestore rules —
 * no operationId / audit entry is needed for the write itself. The
 * docs are shaped to match `templateShapeOk` in firestore.rules, so
 * later client updates (approval, status transitions) pass the rules.
 * The pointer (`storeSettings/activeTemplate`) is NOT touched here —
 * it stays on classic (no pointer doc exists live); activation is
 * Mohamed's field test, one template at a time via `?preview=`.
 */

const fs = require('node:fs');
const path = require('node:path');

try {
  module.paths.push(path.join(__dirname, '..', 'functions', 'node_modules'));
} catch (_) { /* resolved at require time, with a clear error */ }

const args = process.argv.slice(2);
const live = args.includes('--live');
const update = args.includes('--update');
const credArg = args.find((a) => a.startsWith('--credentials='));
const credentialsPath = credArg ? credArg.slice('--credentials='.length) : null;

const TEMPLATE_IDS = ['bazaar', 'gallery', 'scroll', 'speclab', 'boutique', 'classic'];

async function main() {
  let admin;
  try {
    admin = require('firebase-admin');
  } catch (e) {
    console.error('firebase-admin is not installed. Run `npm install firebase-admin` in scripts/ first.');
    process.exit(1);
  }

  if (!live) {
    console.log('DRY RUN — listing only, writing nothing. Pass --live to write.');
  }

  if (credentialsPath) {
    const serviceAccount = JSON.parse(fs.readFileSync(credentialsPath, 'utf8'));
    admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
  } else if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    admin.initializeApp({ credential: admin.credential.applicationDefault() });
  } else {
    console.error('Live run needs Admin SDK credentials (GOOGLE_APPLICATION_CREDENTIALS or --credentials <service-account.json>).');
    console.error('Dry run also needs read access to check which docs already exist.');
    process.exit(1);
  }

  const db = admin.firestore();
  const FieldValue = admin.firestore.FieldValue;

  for (const id of TEMPLATE_IDS) {
    const manifestPath = path.join(__dirname, '..', 'storefront', 'templates', id, '1.0.0', 'manifest.json');
    let manifest;
    try {
      manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    } catch (e) {
      console.error(`Cannot read manifest for ${id}: ${manifestPath} (${e.message})`);
      process.exit(1);
    }
    if (manifest.id !== id) {
      console.error(`Manifest id mismatch for ${id}: manifest says ${manifest.id}`);
      process.exit(1);
    }
    if (!/^[0-9a-f]{64}$/.test(manifest.bundleHash || '')) {
      console.error(`Bad bundleHash for ${id}: ${manifest.bundleHash}`);
      process.exit(1);
    }
    const doc = {
      id,
      nameAr: manifest.nameAr,
      nameEn: manifest.nameEn,
      version: manifest.version,
      shellMinVersion: manifest.shellMinVersion,
      bundleHash: manifest.bundleHash,
      status: id === 'classic' ? 'active' : 'draft',
      previewImageUrl: `https://store-3384c.web.app/templates/${id}/1.0.0/preview.png`,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    };
    const ref = db.collection('templates').doc(id);
    const snap = await ref.get();
    if (snap.exists) {
      if (!update) {
        console.log(`SKIP ${id} — already exists (status: ${snap.data().status}, hash: ${snap.data().bundleHash})`);
        continue;
      }
      const stored = snap.data() || {};
      if (stored.bundleHash === doc.bundleHash && stored.version === doc.version && stored.shellMinVersion === doc.shellMinVersion) {
        console.log(`SKIP ${id} — already up to date (status: ${stored.status}, hash: ${stored.bundleHash})`);
        continue;
      }
      // A change IS needed: never rewrite an approved/active doc's
      // hash here — that would silently invalidate its approval
      // freeze. Re-approval goes through the admin flow.
      if ((stored.status !== 'draft' && stored.status !== 'preview') || stored.approval) {
        console.error(`REFUSE ${id} — status is '${stored.status}'${stored.approval ? ' with an approval record' : ''}; a hash change here must go through admin re-approval, not this script.`);
        process.exit(1);
      }
      console.log(`${live ? 'UPDATE' : 'WOULD UPDATE'} templates/${id}: hash ${stored.bundleHash} -> ${doc.bundleHash} (status stays ${stored.status})`);
      if (live) {
        await ref.set(
          { bundleHash: doc.bundleHash, version: doc.version, shellMinVersion: doc.shellMinVersion, updatedAt: FieldValue.serverTimestamp() },
          { merge: true },
        );
      }
      continue;
    }
    console.log(`${live ? 'WRITE' : 'WOULD WRITE'} templates/${id}: version=${doc.version} shellMin=${doc.shellMinVersion} hash=${doc.bundleHash} status=${doc.status}`);
    if (live) {
      await ref.set(doc);
    }
  }

  console.log(live ? 'Done.' : 'Dry run done — nothing written.');
  process.exit(0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
