# Incomplete Orders, Journeys, and Delivery Coverage — Schema

*   **Status:** Approved (2026-11-27) — canonical field list for
    `briefs/incomplete-orders-journey.md`. The builder, the rules
    (`firestore.rules`), and the tests all assert against this file.
    When a field here and a client disagree, this file wins.
*   **Schema version:** `1` on every new document (`schemaVersion: 1`).

## Shared values

*   **Egyptian mobile:** `^01[0125][0-9]{8}$` (11 digits, `010` /
    `011` / `012` / `015`). Both phones validate against it when
    present. An empty secondary phone is valid (absent).
*   **Dwell bands (stored tokens, ASCII):** `'<10s'`, `'10-60s'`,
    `'>60s'`. The UI renders them as "أقل من 10 ثواني" / "10–60
    ثانية" / "أكتر من دقيقة". Never per-second values.
*   **Draft statuses:** `new` | `contacted` | `no-answer` |
    `converted` | `dead`. Allowed transitions: `new → contacted |
    no-answer | converted | dead`; `contacted → no-answer |
    converted | dead`; `no-answer → contacted | converted |
    dead`. `converted` and `dead` are terminal — no transition out.
    Only an admin sets a status; the storefront never writes it.
*   **Line availability:** `ok` | `out` | `short`, with
    `availableQty` (int ≥ 0). `ok` means `stock - reserved >= qty`;
    `out` means `availableQty == 0`; `short` means `0 <
    availableQty < qty`.

## `checkoutDrafts/{sessionId}`

One document per browser session. The document ID is the session ID
(`store_session_id`, `s_…`); the document also carries it as
`sessionId`. The storefront owns the document while the visitor is
typing; admins own it after that (status, conversion, delete).

| Field | Type | Notes |
|---|---|---|
| `sessionId` | string | Equals the document ID. |
| `sessionToken` | string, non-empty, ≤ 128 | Random per browser, stored in localStorage as `sp-draft-token`. Rules: anonymous create only with a token; anonymous update only when the incoming token equals the stored token and the token field itself is unchanged. |
| `name` | string, ≤ 100 | May be `''` until typed. |
| `phone` | string | `''` until typed; a complete valid Egyptian mobile once entered. The draft escalates to server-synced only after a valid phone exists — before that it stays local-only. |
| `phone2` | string \| null | Optional backup phone; same validation when non-empty. |
| `governorate` | string \| null | Governorate stable ID (see below), or null until picked. |
| `detailedAddress` | string ≤ 500 \| null | Street / building / flat, without the governorate. |
| `address` | string ≤ 500 | Combined address in the old field: `"<governorate name> — <detailed>"` when both exist, else whatever the customer typed. Admin views read this when the new fields are empty. |
| `cart` | list of line, ≤ 20 lines | See line shape below. May be empty (draft not callable then). |
| `status` | string | One of the five statuses above; `new` on create. |
| `completeness` | int 0–100 | 25 points each: name present, valid phone, non-empty cart, address present (governorate + detailed, or the combined field). |
| `orderId` | string \| null | Set on conversion to the created order's ID (the order document ID equals the draft ID). |
| `mootOrderId` | string \| null | Set when the same phone already placed a real order (`orders` where `customerPhone == phone` and `createdAt >= draft.createdAt`). |
| `lastSyncAt` | timestamp | Last successful server sync (the admin list shows this, so a failed draft is distinguishable from an untyped one). |
| `createdAt` | timestamp | First server sync. |
| `schemaVersion` | int | `1`. |

**Cart line** `{productId, qty, priceAtDraft, availability,
availableQty}`: `productId` string non-empty; `qty` int 1–20;
`priceAtDraft` number ≥ 0 (the price the customer saw — never
trusted for money, conversion re-reads the database price);
`availability` one of `ok | out | short`; `availableQty` int ≥ 0.

**Triage minimum** (a draft appears in the incomplete-orders list
only when all three hold): non-empty cart + name present + full
valid phone. **Dedup:** by phone, newest first; same-session
drafts merge (one document per session).

## `journeySummaries/{sessionId}`

One capped summary per browser session. The document ID is the
session ID. It links to a draft or an order only when the session
leaves one; anonymous sessions are listed by session and time.

| Field | Type | Notes |
|---|---|---|
| `sessionId` | string | Equals the document ID. |
| `draftId` | string \| null | Session ID of the linked draft (same value), once a draft exists. |
| `orderId` | string \| null | Order ID once an order is placed from this session. |
| `startedAt` | timestamp | Session start. |
| `totalSecondsBand` | string \| null | Dwell band for the whole session (`<10s` / `10-60s` / `>60s`). |
| `products` | list of entry, ≤ 20 | See entry shape below. The 21st product is dropped; the overflow is recorded as `overflowCount`, never a 21st entry. Oldest entries are kept first. |
| `overflowCount` | int ≥ 0 | Products beyond the 20-entry cap. |
| `updatedAt` | timestamp | Last flush. |
| `schemaVersion` | int | `1`. |

**Product entry** `{productId, dwellBand, actions[]}`: `productId`
string non-empty; `dwellBand` one of the three stored tokens (the
timer runs only while the tab is visible — hidden-tab time is
excluded); `actions` list of strings, ≤ 10 entries, each a plain
action name (`view`, `add_to_cart`, `checkout_start`, …). Unknown
action types are stored as plain strings and rendered as text by
old admin code — never a failure.

**Flush rule:** at intent milestones (product view, add to cart,
checkout start) and best-effort on `pagehide`. A crash between
flushes loses only the tail, never the whole session.

## `storeSettings/governorates`

One document, the single stored governorate list. The storefront
reads it once per session (short in-memory cache); the dropdown
shows only `active: true` entries. Admin apps edit it (merge only).

| Field | Type | Notes |
|---|---|---|
| `entries` | list, ≤ 27 | `{id, name, active}` per governorate. |
| `updatedAt` | timestamp | Last admin edit. |

**The 27 governorates** (stable ID → Arabic name; all `active:
true` by default):

| ID | Name | ID | Name | ID | Name |
|---|---|---|---|---|---|
| `cairo` | القاهرة | `giza` | الجيزة | `alexandria` | الإسكندرية |
| `dakahlia` | الدقهلية | `red-sea` | البحر الأحمر | `beheira` | البحيرة |
| `fayoum` | الفيوم | `gharbia` | الغربية | `ismailia` | الإسماعيلية |
| `menofia` | المنوفية | `minya` | المنيا | `qalyubia` | القليوبية |
| `new-valley` | الوادي الجديد | `suez` | السويس | `asyut` | أسيوط |
| `sohag` | سوهاج | `qena` | قنا | `luxor` | الأقصر |
| `aswan` | أسوان | `sharqia` | الشرقية | `port-said` | بورسعيد |
| `damietta` | دمياط | `kafr-el-sheikh` | كفر الشيخ | `beni-suef` | بني سويف |
| `matrouh` | مطروح | `north-sinai` | شمال سيناء | `south-sinai` | جنوب سيناء |

**Fallbacks:** document missing or unreadable → the full 27 above
(hardcoded in every client). Document loads with zero active →
the form shows "التوصيل غير متاح حالياً — لم يتم إعداد مناطق
التوصيل بعد" and checkout stays blocked. Submit re-checks the
chosen governorate against the live list; a deactivated value is
rejected with the delivery message.

## `storeSettings/deletion`

One document, the single deletion config both admins read.

| Field | Type | Notes |
|---|---|---|
| `autoDeleteDays` | int 0–365 | `0` = manual delete only until Mohamed sets a number. |
| `lastRunAt` | timestamp \| null | Last runner run (idempotency guard: one run per day). |
| `lastRun` | map \| null | `{deleted, kept}` counts from the last run. |

**Runner (PC admin on start, after sign-in):** reads the config;
skips when `lastRunAt` is today; deletes drafts with `createdAt`
older than X days; then enforces the count cap (keep the newest
100 drafts, delete the rest); writes the run record back to the
same config document; returns the counts. When X is 0 it only
enforces the count cap. Two admins open at once cannot delete the
same draft twice (the run record is the guard; deletes are by
document ID).

## `storeSettings/quota`

One document, the quota meter and manual cut-off.

| Field | Type | Notes |
|---|---|---|
| `cutoffLevel` | string | `none` \| `journeys` \| `drafts`. `journeys` stops journey-summary writes; `drafts` also pauses draft sync (the local copy keeps working); order writes are never cut. Manual flip by Mohamed in admin. |
| `dailyEstimate` | int ≥ 0 | Estimated Firestore writes today (drafts + journey summaries). |
| `updatedAt` | timestamp | Last meter update. |

**Budget:** ~500 writes/day now (2.5% of the 20,000/day Spark
limit); ~5,000/day at 10× traffic (25%). Visits and aggregate
journeys cost zero writes (GA4).

## `feedback` — source values

The one-way card keeps its 5 fields (`name`, `email`, `phone`,
`message`, `createdAt`) and gains an optional sixth:

| Field | Type | Notes |
|---|---|---|
| `source` | string \| absent | `direct` (contact form / admin filing) \| `exit-feedback` (desktop exit popup) \| `footer-feedback` (footer link). Absent means `direct` (old shape). |
| `name` / `phone` | string | Required (non-empty, phone 10–15 digits) for `direct`; may be empty for `exit-feedback` / `footer-feedback` (the visitor may answer anonymously). `message` stays required (10–2000 chars) in every shape. |

## `orders` — dual-shape addition

Old-shape orders (one phone, one address) stay valid. New-shape
orders add three optional fields, written by the storefront submit
and by draft conversion:

| Field | Type | Notes |
|---|---|---|
| `customerPhone2` | string \| null | Backup phone, same Egyptian-mobile validation when non-empty. |
| `governorate` | string \| null | Governorate stable ID. |
| `detailedAddress` | string \| null | Detailed address without the governorate. |

`customerAddress` (the old field) always carries the combined
string. Admin views read the old field when the new fields are
empty. Rules key counts: old shape 25/26 keys, new-money shape
28–30, plus 0–3 dual fields (max 33 keys total).

## Conversion transaction (both clients, same spec)

One transaction, one idempotency key (the order document ID equals
the draft ID), in order:

1.  Read the draft; if its status is `converted`, return the
    existing order (`orderId`); if `dead`, refuse.
2.  Moot check: query `orders` where `customerPhone == draft.phone`
    (limit 10, client-side filter `createdAt >= draft.createdAt` —
    no composite index). If one exists, mark the draft moot with
    `mootOrderId` and return it instead of creating.
3.  Re-read products + inventory inside the transaction; re-check
    stock (`qty <= stock - reserved`) and the current database
    price per line. On stock-out return the out-of-stock result
    (`INSUFFICIENT_STOCK`, with `productId` + `availableQty`);
    on a price change return the price-changed result
    (`PRICE_CHANGED`, with current prices). Never create an order.
4.  Reserve stock, claim the discount (drafts carry no code —
    `discountCode: null`), create the order (source
    `admin_manual`, `createdBy` = admin UID, audit operation
    `manual_order_create`, audit docIds covering `status`, `total`,
    the money fields, and `items` when any line carries a
    base price), write the movements, and mark the draft
    `converted` with `orderId` — all in the same transaction.
5.  A double-tap returns the existing order (step 1), never a
    second order.

## GA4 (visits + aggregate journeys)

*   Measurement ID lives in `storefront/firebase-config.js` as
    `window.STORE_GA4_ID` (empty until Mohamed creates the GA4
    property and pastes the ID — the builder cannot create it).
*   Events fired from the storefront: `view_item`, `add_to_cart`,
    `begin_checkout` (same milestones as the Firestore journey
    flush). No GA4 call is made when the ID is empty; the
    storefront works before the property exists.
*   A visit is one unique visitor per day in Egypt time. Admin and
    preview traffic is excluded. Counts come from GA4 only — no
    Firestore write is spent on counting, and no Firestore visit
    count is ever invented. The admin dashboards link out to GA4.
