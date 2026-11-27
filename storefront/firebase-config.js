// Firebase Web config for the Store storefront (project store-3384c).
// These are Firebase identifiers for a public web app (the same values any
// visitor's browser receives) — not private secrets.
// Google Analytics 4 measurement ID (G-…) for per-day visit counts and
// aggregate journeys. EMPTY until Mohamed creates the GA4 property in
// the Google Analytics console and pastes the ID here — the builder
// cannot create it. The ID is a public measurement ID, not a secret.
// While empty, no GA4 call is made anywhere (the storefront, the
// visits card and the journey events all fail safe) and the visits /
// journeys part cannot be field-tested.
window.STORE_GA4_ID = '';

window.STORE_FIREBASE_CONFIG = {
  apiKey: 'AIzaSyA-66Gg5n92-wqyVJcjatmUJUYnQG_b7Qg',
  authDomain: 'store-3384c.firebaseapp.com',
  projectId: 'store-3384c',
  storageBucket: 'store-3384c.firebasestorage.app',
  messagingSenderId: '766975771796',
  appId: '1:766975771796:web:7e746d8f9c236513e8e081',
};
