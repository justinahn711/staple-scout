# API contract

API routes use JSON and return validation errors as HTTP 422, missing records as
404, cross-origin writes as 403, and non-JSON write payloads as 415.
Monetary amounts and input quantities are decimal strings. Persistent storage defaults to `data/staple-scout.sqlite3`, with
`STAPLE_SCOUT_DB` override. Empty initial staples/prices, seeded store configuration.

- `GET /api/stores`: array `{id, name, location, channel, source_status, note,
  preferred_context_id, location_id, location_status, location_configured}`.
  `GET /api/stores/{store_id}` returns one such record; unknown stores return 404.
  IDs wegmans, walmart, target, hmart, lidl. Walmart tentative Chantilly #5969
  (`location_id: "5969"`); Wegmans Chantilly #133 is user-reported
  (`location_id: "133"`); Target Chantilly; H Mart Centreville. Lidl remains
  Unselected with no location ID. No IDs are guessed for the latter three.
  `location_status` is `user_reported`, `tentative`, or `unconfigured`;
  `location_configured` means the status is not unconfigured, including tentative
  selections. Neither field verifies a location or price source. All automated
  sources remain `not_connected`, and this API cannot edit source status.
- `PATCH /api/stores/{store_id}` accepts `{context?, context_id?, note?}`.
  Supply either `context_id` to select an existing context belonging to that store,
  or `context: {location, location_id?, channel?, location_status?}` to create or
  reuse an exact immutable context. Omit both to change only the note. Empty
  patches are no-ops; explicit null top-level fields are invalid. Returns the
  updated store record. A missing or wrong-store context ID returns 422.
  Context defaults: `location_id: null`, `channel: "in_store"`,
  `location_status: "user_reported"`. These are full context descriptions, not
  partial changes to the previous context. Labels are trimmed, nonblank strings
  up to 200 characters. Optional retailer location IDs are trimmed strings up to
  100 characters, starting with an ASCII letter/digit and containing only ASCII
  letters/digits, hyphens and underscores. IDs retain case and leading zeroes;
  syntax validation is not retailer verification. `channel` is a shopping
  preference, one of in_store/pickup/online. It does not rewrite or constrain the
  channel of manual evidence. Unconfigured contexts require the exact label
  `Unselected` and a null/omitted location ID; configured contexts cannot use that
  label (case-insensitive). Notes are trimmed strings up to 2000 characters and
  are retained on context switches unless explicitly changed.
- `GET /api/stores/{store_id}/contexts`: immutable history of
  `{id, store_id, location, location_id, channel, location_status,
  location_configured, is_current_context}` in ID order. No context edit/delete
  endpoint exists. Identity includes store, label, retailer location ID, channel
  preference and location status. Changing any of those fields creates/selects
  a different context; returning to an exact context reuses its ID and history.
- `GET /api/staples`: array `{id, name, basis, rules, needed}`.
- `POST /api/staples`: body `{name, basis, rules, needed?}`; returns created record.
  basis one of `oz`, `fl_oz`, `each`; rules string; needed boolean default true.
- `PATCH /api/staples/{id}`: partial same fields; returns updated record. Actual
  changes to name/basis/rules clear prior observation approvals; changing only
  needed or submitting unchanged values preserves approvals and price history.
- `DELETE /api/staples/{id}`: 204; remove dependent observations deliberately.
- `POST /api/observations`: `{staple_id, store_id, product_name, price,
  quantity, unit, pack_count, channel, observed_at, source_url?, available,
  approved, conditions?, context_id?}`. Supported input units oz/lb/g/kg/fl_oz/ml/l/each.
  `quantity` is per pack; `pack_count` integer default 1. price is entire purchase
  package. timestamp ISO with zone. channels in_store/pickup/online.
  approved defaults false, available defaults true. Conditions nonempty means
  not eligible for winner (MVP does not evaluate promotional requirements).
  `context_id` is a positive integer belonging to `store_id`, persisted and
  returned on every observation. An explicit noncurrent context is allowed for
  recording historical evidence but cannot supply a current winner. Explicit
  null or an unknown/wrong-store context returns 422. For backward compatibility,
  omission resolves the preferred context atomically at insertion time. Clients
  should send the ID they displayed to avoid an intervening preference change
  attaching evidence to a different location. Unconfigured observations remain
  recordable but permanently unconfigured; later configuring the store cannot
  upgrade their provenance. `approved` confirms the product meets staple rules,
  never that its location or price source was verified.
- `GET /api/observations?staple_id=1&store_id=wegmans&context_id=1`: complete
  observation history, including superseded and noncurrent records, in ID order.
  All filters are optional and combined with AND. Returns observation fields plus
  original `store_location`, `location_id`, `location_status`, and
  `location_configured`. Unknown store filters or nonpositive integer filters
  return 422; unmatched valid filters return an empty list.
- `GET /api/comparisons?needed_only=false&stores=wegmans,walmart&channel=in_store&include_previous_contexts=false`: array of
  `{staple: {...}, offers: [...], winner_id: number|null, channel: string,
  gap: string|null}`. `gap` is `no_observations` or `no_eligible_offers` when
  `winner_id` is null, and null when a winner exists.
  Each offer includes observation input fields, `id`, `store_name`, original
  `store_location`, `location_id`, `location_status`, `location_configured`,
  `is_current_context`, `unit_price` decimal string|null, `basis`, `eligible` boolean,
  `exclusion_reasons` string array. Winner is the lowest unit price among
  eligible, available, approved, fresh (<48h), unconditional observations in
  the selected channel; this is a unit-price winner, not package outlay.
  `channel` accepts `in_store` (shelf, default) or `pickup`; unknown values
  return 422. Only observations matching the requested channel can win.
  Online observations remain visible with an exclusion reason. Never
  claim they are verified shelf prices. Freshness reevaluated on every request.
  Only preferred-context observations are shown by default. With
  `include_previous_contexts=true`, older contexts also appear but are excluded
  with `location_not_current`. Unconfigured contexts are excluded with
  `location_not_configured`, even after the retailer gains a configured context.
  Only the latest observation per (staple, store, context_id, product_name,
  canonical quantity, unit, pack_count, channel) is shown. A different context
  cannot supersede that context's latest observation. This temporary variant
  identity will be replaced with stable product IDs. Switching back can restore
  a still-fresh approved observation as a winner; freshness and approval are
  always rechecked. Rule changes clear approvals across all contexts.
- `GET /api/health`: `{status: "ok"}`.

The service exposes `create_app(db_path=None)` and module `app` from
`staple_scout.main`. `/` serves the local shopper setup interface; `/docs`
remains available for the developer API explorer. The setup interface manages
staples, saved store locations, manual price evidence and product-match reviews.

No auth in this local-only initial version. JSON writes require same-origin when
Origin is provided. CORS disabled. Docs at `/docs`.

## Database compatibility

SQLite `PRAGMA user_version` is now 1. The original unversioned schema (version 0)
upgrades atomically at application initialization. Existing stores each gain one
immutable context reflecting their recorded location at migration time; all old
observations bind to that context, preserving their IDs, prices, timestamps,
channels, approval flags and remaining fields. Unselected stores stay
unconfigured. No observations or staples are seeded into a new database.

Schema changes, data copying and the version advance share one explicit writer
transaction. Failures roll back all three; restarting safely retries. Concurrent
initializers serialize, successful upgrades are not rerun, and newer unsupported
schema versions are refused. The original schema did not capture earlier
location changes, so the migration cannot recover any such lost provenance.
Existing JSON fields remain available; context and provenance fields are additive.

## Product variants and match review

`POST /api/variants` accepts `retailer`, exactly one of `retailer_product_id` or
`manual_identity`, optional `barcode` (text), `package_quantity`, `package_unit`,
`pack_count`, and `form`. Retailer product IDs are stable across listing renames.
Manual identities are explicit and are never merged by name or barcode. `GET
/api/variants` optionally filters by retailer; exact identity and package/form imports are idempotent and return the existing variant. Quantities are decimal strings and canonicalized, so `16.0` and `16` are the same configuration. Different package quantity/unit/count or form creates a new variant version with no inherited review.

`GET /api/staples/{id}/matches` returns variant details and persistent `pending`,
`approved`, or `rejected` status. `PUT /api/staples/{staple_id}/matches/{variant_id}`
accepts `{"status":"approved"|"rejected"|"pending"}`. No match is inferred.
Changing staple name, basis, or rules sets reviews to pending while retaining
price history. Package/form changes require a new immutable variant and review.

Schema version 2 adds variants, matches, and observation associations. Legacy
observations retain IDs and all provenance; each receives a distinct pending
manual identity. Migration is one transaction and rolls back on failure.

`POST /api/observations` optionally accepts `variant_id`. Its retailer and package
must match the observation; an inconsistent reference returns 422 without saving.
With an explicit variant, `approved` is retained only as historical input: it
cannot override pending/rejected match state. Once approved via the match-review
endpoint, the review applies to later observations even when their `approved`
input is false. Reviews store an aware UTC approval time.

Omitting `variant_id` creates a new manual identity for this entry. In that case
only, explicit `approved:true` records the user's review of the new product.
Names and barcodes never merge manual entries. Reuse the returned `variant_id`
to record a later price for the same product; repeated source imports must use an
explicit retailer/manual identity. Every observation response and history record
includes `variant_id` and current `match_status`. The original `approved` field
is not the current review status. Comparison eligibility uses match state.

Latest offers are selected per staple, variant, location context and channel,
using observation time and ID. A renamed listing for the same variant supersedes
its earlier price; a different package remains a separate variant. Existing
legacy rows get separate pending manual matches, regardless of their historical
approval flags, and require explicit review before winning. No price/source/date
or location data is rewritten by this migration. Rule changes invalidate current
reviews without removing product or price history. Variant identity/configuration
and observation-to-variant assignments are immutable.


## Requested quantities and whole-package outlay

Staples optionally store `desired_quantity` (positive decimal string) and
`desired_unit`. Both must be provided together and match the staple's comparison
dimension. PATCH validates the merged saved record: changing basis cannot leave
an incompatible saved desired quantity. PATCH both fields to null to clear the
request. Changing only desired quantity/unit or needed preserves match reviews.

Comparison `winner_id` remains the unit-price winner, also returned as
`unit_price_winner_id`. With a desired quantity, `purchase_cost_winner_id` identifies
the cheapest whole-package outlay among offers eligible in the selected channel.
For eligible fixed-size offers, `packages_needed` is the ceiling of requested
amount divided by total package amount (per-pack size times pack count),
`purchase_cost` is total package price times packages needed, and
`excess_quantity`/`excess_unit` describe the leftover amount in the requested unit.
Each multipack's observation price is the price of the entire purchase package.
Ties use the observation ID. No mixing packages, travel, coupons or promotion
optimization occurs. Decimal arithmetic uses exact finite conversions to grams,
milliliters or count before ceiling; displayed fractional conversions may repeat.

No desired quantity preserves unit-price behavior, sets the purchase winner to
null and returns `purchase_gap: "quantity_not_requested"`. A request with no
eligible offer returns null and `purchase_gap: "no_eligible_offers"`.

Observations accept `quantity_kind: "fixed"|"estimated"|"variable"`, default
`fixed` for the existing exact-size contract. Estimated/variable weights are
visible but excluded with `uncertain_quantity`; they cannot produce exact package
outlay or win either comparison. Incompatible units and all existing freshness,
review, stock, location, channel and condition rules still apply.

Schema v3 adds desired staple quantities and quantity kind to observations in an
atomic migration. Existing desired quantities start null and existing package
quantities retain the original fixed-size interpretation. No stored prices or
observation dates are changed.


## Shopper setup interface

`GET /` serves accessible setup screens; static assets are local and no frontend
build step or third-party CDN is required. Staples include weekly need, product
rules, comparison basis and optional paired desired quantity/unit. Location
selection and manual prices use exact immutable context IDs. Reusing a product
variant prefills/locks package fields and keeps review separate from price entry.
A new manual product can be reviewed explicitly; existing products use match
review endpoints. Forms preserve values after validation/network errors and show
pending/success/error states. Requirement edits explain reapproval; deletion
requires an in-page confirmation describing its history consequence. No sample
prices, fabricated substitutes, source login or background fetch is introduced.
## Explicit source refreshes (schema v4)

`create_app(db_path=None, adapters=None)` accepts a server-owned registry of
`AdapterRegistration` values. The default registry is empty in this foundational
change; no retailer is automatically fetched or marked connected. A registration
requires an explicit verification gate, permitted channels, seller allowlist and
HTTP timeout (at most 30 seconds). This is not a client-controlled approval field.

`GET /api/sources` lists registered identities/channels and validation status.
`POST /api/refresh` accepts `source_id`, exact immutable `context_id`, `channel`,
`requests: [{staple_id, retailer_product_id}]` (1–50), and `idempotency_key`.
Context ownership and staple existence are checked before fetching. The selected
context remains exact even when a store's preferred context changes. Online
reference sources must use an online context rather than claiming a local shelf.

A source returns bounded, runtime-validated `OfferEvidence`: stable record and
retailer product IDs, barcode text if supplied, decimal price and package quantity
(or explicit null), unit, pack count, form, stock (true/false/unknown), seller,
channel/location ID, aware observed/retrieved times, public source URL, conditions
and optional validity window. Currency is USD. Binary floating-point money,
invalid/future timestamps, credential-bearing URLs, mismatched seller/location/
channel/product, conflicting records and oversized results fail the whole source
batch. Unknown fields cannot silently become prices or zero-sized packages.
Adapters must pass the bounded timeout to their HTTP client; there are no retries
or background fetches in this change.

Refresh responses and `GET /api/refresh-runs[?source_id=...&limit=50]` or
`GET /api/refresh-runs/{id}` expose separate attempt/finish timestamps, safe error
codes and per-record validated evidence. Status is `running`, `succeeded`,
`partial` (unknown fields or requested records omitted), or `failed`. Unknown
price/quantity/availability remains an `unresolved` result, not a made-up
observation. Explicit false stock is `unavailable`. Source validity does not
change stock: an expired offer may be accepted as evidence but is excluded from
comparison with `offer_expired` (or `offer_not_started` before its valid window).

Repeated identical keys return the original outcome without fetching or inserting
again; reusing a key for another request returns 409. A new key records a new
measurement even when its price is unchanged. Network/storage failures preserve
all prior observations and source results; errors never store retailer exception
text. Each source is independent, so its failure cannot roll back another source.

Imports create/reuse an exact immutable retailer/package/form variant and pending
matches only for the explicitly requested staples. Approval is never inferred
from titles or barcodes; existing review remains authoritative for the same
variant. A changed package creates a new pending version. Barcode identity
conflicts fail safely. Imported observations/history expose original `source_id`,
`source_record_id`, `retrieved_at`, seller and validity metadata. Latest successful
source product state excludes older automatic offers after changed/unknown
packages, unknown prices/stock, or explicit unavailability. Failed attempts do
not refresh old observation timestamps or affect eligibility. Manual evidence
retains its separate provenance.

Schema v4 adds run/result/import-link tables atomically. Existing manual prices,
reviews, contexts and desired quantities are unchanged; failed upgrades roll back
and can be retried. This foundation does not verify or enable any retailer source,
activate a scheduler, approve matches, or read receipts.

### H Mart online capability

The default registry now includes verified `hmart_online`, supporting only
`online` evidence from seller `HMart - US`. App startup never fetches. Configure
an explicit H Mart online context with `location_id:null`, then request selected
`productId:itemId` identities. Source URLs refer to the public exact-product
endpoint. The existing Centreville context and shelf/pickup source remain
unverified; `stores.source_status` does not imply online stock verifies a shelf.
`GET /api/sources` is the authoritative per-source channel capability list.
See `docs/research/hmart.md` for captured evidence, smoke results, conservative
package/form handling and incomplete category/produce coverage.

## Daily refresh and source status (schema v5)

`python -m staple_scout.scheduler --db <path> --config <json>` explicitly invokes
the validated-source daily runner. `--dry-run` validates structure without HTTP
or a claim; `--status` reads registered source attempt/success/failure status.
Manual and launchd invocations share one durable UTC-day claim per database and a
retained flock sidecar. Fifty requests total, five entries, at most three
transient attempts with bounded backoff. No force flag, automatic source login,
job installation/activation or notification delivery. See `docs/scheduling.md`.

`GET /api/source-status[?context_id=...&channel=...]` returns one entry per
registered source: `source_id`, `last_attempt`, `last_success`, `last_failure`.
Each nonnull status includes run ID, context, channel, attempt/finish timestamps,
status and safe error code. Last success requires accepted/unavailable source
evidence; an entirely unresolved partial fetch does not replace it. Attempt
success does not rewrite observed price timestamps or verify a local channel.

Schema v5 adds durable day-claim state atomically and preserves all source/manual
history. After a crash, that day's unfinished claim remains visible and cached;
the next day can run once the process lock releases. HTTP429/5xx, transport errors
and timeouts have classified transient codes for bounded retries; malformed
source evidence, other HTTP errors and invalid configurations are not retried.

## Comparison and shopping screens

The local shell adds Compare prices and This week tabs. Both use explicit shelf/pickup, planned-store and needed filters. An empty store selection never silently expands to all stores. Offer eligibility and both winner IDs come from the API; the frontend does not rank prices. Shopping groups unit-price winners and keeps coverage gaps visible. Source attempts/success/failures are filtered to the selected channel and preferred location. Online H Mart remains separate. No retail refresh is triggered by opening these screens.

## Saved weekly reports (schema v6)

The chosen format is a local web report; opening or generating one sends no notifications and fetches no retail prices. `POST /api/reports` accepts an aware, nonfuture `as_of`, 1–5 unique `stores`, shelf `in_store` or `pickup` channel, and `needed_only` (default true). `GET /api/reports/{id}` returns the saved result; `/reports/{id}` opens the web view.

The first normalized request freezes current staple requirements, approvals and preferred contexts with cutoff-scoped recorded evidence. Repeating the same UTC cutoff, sorted stores, channel and need filter returns that identical saved snapshot even after later edits/deletions. This does **not** reconstruct historical user settings. Manual rows use observation time; imports additionally require source retrieval and successful run completion at or before the cutoff. Future source state cannot retroactively suppress an older report. Freshness and validity are evaluated at the cutoff.

Reports retain comparisons, explicit exclusions and gaps, selected contexts, source-health attempt/success/failure, eligible unit-price choices grouped by store, and separate exact package-outlay choices. Price drops compare the latest eligible observation against its immediately previous observation for the same variant, staple, context, channel and source. The earlier price must be available, fixed-size and unconditional with applicable terms. Different packages/channels/locations and guessed reference prices never produce a drop or aggregate savings. Snapshot schema/version and original observation IDs make each claim auditable. Report rows are immutable and independent of deleted staple foreign keys.
