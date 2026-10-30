# Store — product store system (private repo)

- **Admin app** (Flutter, Android, `com.valor.storeadmin`): invite-code gate
  first, then "إنشاء حساب" / "لدي حساب بالفعل", sign-in with email or phone
  + password. Manages brand name, categories, products (multi-image
  gallery), orders, team, and analytics. Ships with an in-app diagnostics
  viewer.
- **Product images — Cloudinary free plan** (no card, no backend, no
  secret): uploads use an UNSIGNED preset (HTTP POST to
  `api.cloudinary.com`, fields `file` + `upload_preset`); the app holds only
  cloudName + uploadPreset (placeholders until Mo supplies them). The
  product doc stores `images: [{url, publicId}]`, cover = images[0].
  Removing an image deletes its doc entry only — the file stays on
  Cloudinary as an orphan until cleaned from the dashboard (the destroy API
  needs the api_secret and is never called from the app). Preset
  restrictions to apply at creation: folder `store-products`, allowed
  formats jpg/png/webp, unsigned. Firebase Storage is NOT used (it needs
  Blaze billing, which is forbidden).
- **Storefront** (`storefront/`): static mobile-first website, Firebase
  Hosting-ready (`firebase.json`). Cart + cash-on-delivery checkout.
  Analytics boundary: a visitor's contact info is saved to a checkout
  attempt ONLY after they complete the info step — never from unsubmitted
  typing.
- **Backend**: Firebase project `store-3384c` (Spark, no billing).
  `firestore.rules` in this repo is the ruleset to publish (Mo publishes it
  via the console; it is not live until published).

## Build
CI (`.github/workflows/build.yml`) runs analyze + tests under UTC and
Africa/Cairo + builds a stable-signed universal release APK and publishes
it to the `latest` release. Required secrets: `KEYSTORE_BASE64`,
`KEYSTORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`.
