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
  `{staple: {...}, offers: [...], winner_id: number|null}`.
  Each offer includes observation input fields, `id`, `store_name`, original
  `store_location`, `location_id`, `location_status`, `location_configured`,
  `is_current_context`, `unit_price` decimal string|null, `basis`, `eligible` boolean,
  `exclusion_reasons` string array. Winner lowest unit price among eligible,
  available, approved, fresh (<48h), unconditional in_store observations.
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
`staple_scout.main`. `/` redirects to the generated API explorer at `/docs`.
The shopper interface is a future milestone.

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
