# Template gateway fixtures (spec entry 22)

Single fixture set both gateways run against (Flutter `test/templates_bundle_test.dart`,
PC `test/templates.test.js`, shell `storefront/bundle-gateway.js`).

- Source of truth: `storefront/templates/gateway-rules.json`. DO NOT edit a fixture
  to match an implementation — a fixture verdict that disagrees with an
  implementation is a flag to report, not a fix.
- Each fixture is one bundle: `manifest` + `sections/` (HTML fragments) +
  `styles` + `tokens` (+ `expected.verdict` / `expected.reasons`).
- `bundleHash` is SHA-256 over the canonical file set (manifest minus its own
  `bundleHash` field + sections + styles.css + tokens.json, lexicographic path
  order, JSON canonicalised with sorted keys; `preview.png` excluded).
- Regenerate with `node /tmp/gen-fixtures.mjs` (generator kept out of the repo
  on purpose — fixtures are the checked-in artefact, not the script).

## Counts (36 fixtures)

- Valid bundles (5): `valid-bazaar`, `valid-gallery`, `valid-scroll`,
  `valid-speclab`, `valid-boutique` — minimal valid per direction. "Minimal"
  means the mandatory products/delivery/contact sections + the direction's
  own section + tokens + styles; a one-section bundle cannot pass gateway
  check 2 (required sections), so no valid fixture has fewer.
- Slot contract (1 valid + 4 invalid): `slot-contract-valid` uses EVERY slot
  (15) and EVERY hook (8) from gateway-rules.json. Invalids:
  `invalid-unknown-slot`, `invalid-unknown-action`, `invalid-unknown-section`,
  `invalid-writes-products-grid` (writes into `#productsGrid` by id).
  The unknown-slot / unknown-action fixtures also serve as the two matching
  entries in the per-reason list below — one file, two categories, no copy.
- One invalid fixture per gateway rejection reason (26 + the 2 slot-contract
  files above = 28 in this group incl. `invalid-css-hides-confirm`):
  script tag, onclick / onerror-on-img / onload-on-svg event handlers,
  `javascript:` URL, iframe, form, meta, link, svg-with-script, missing
  tokens.json, missing delivery section, missing brand slot, motion animating
  blur / backdrop-filter / width / height, CSS `url()` outside declared
  origins, CSS `@import` outside declared origins, `dataNeeds` naming a
  nonexistent field, font origin outside the CSP allow-list, behaviour
  outside the whitelist, `shellMinVersion` newer than the live shell
  (1.0.0), hash mismatch.
- `old-shell-shape`: a NEW registry document as a cached old `app.js` sees
  it — the old v1 gateway must fail it, so the old shell falls back to
  classic (`expected.fallback: "classic"`, `oldGatewayPasses: false`).
- `invalid-css-hides-confirm`: CSS-scoping fixture — a bundle stylesheet
  hiding `#checkoutBtn` fails the gateway.

## Reason codes

`script-tag`, `event-handler`, `javascript-url`, `iframe`, `form`, `meta`,
`link`, `svg-scriptable`, `missing-tokens`, `missing-delivery`,
`missing-brand-slot`, `motion-blur`, `motion-backdrop-filter`,
`motion-width`, `motion-height`, `css-url-origin`, `css-import-origin`,
`data-needs-unknown-field`, `font-origin`, `behaviour-unknown`,
`shell-version`, `hash-mismatch`, `unknown-slot`, `unknown-action`,
`unknown-section`, `writes-products-grid`, `css-transactional-selector`.
