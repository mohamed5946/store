# Store — product store system (private repo)

- **Admin app** (Flutter, Android, `com.valor.storeadmin`): invite-code gate
  first, then "إنشاء حساب" / "لدي حساب بالفعل", sign-in with email or phone
  + password. Manages brand name, categories, products (Spark-only images:
  on-device compressed base64 in the Firestore doc, or a pasted image link —
  Firebase Storage needs Blaze billing and is NOT used), orders, team, and
  analytics. Ships with an in-app diagnostics viewer.
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
