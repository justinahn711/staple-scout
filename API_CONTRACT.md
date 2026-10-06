# Initial API contract

API routes use JSON and return validation errors as HTTP 422, missing records as
404, cross-origin writes as 403, and non-JSON write payloads as 415.
Monetary amounts and input quantities are decimal strings. Persistent storage defaults to `data/staple-scout.sqlite3`, with
`STAPLE_SCOUT_DB` override. Empty initial staples/prices, seeded store configuration.

- `GET /api/stores`: array `{id, name, location, channel, source_status, note}`.
  IDs wegmans, walmart, target, hmart, lidl. Walmart tentative Chantilly #5969;
  Wegmans Chantilly #133 is user-reported; Target Chantilly; H Mart Centreville;
  Lidl location unselected. All automated sources `not_connected`.
- `GET /api/staples`: array `{id, name, basis, rules, needed}`.
- `POST /api/staples`: body `{name, basis, rules, needed?}`; returns created record.
  basis one of `oz`, `fl_oz`, `each`; rules string; needed boolean default true.
- `PATCH /api/staples/{id}`: partial same fields; returns updated record. Actual
  changes to name/basis/rules clear prior observation approvals; changing only
  needed or submitting unchanged values preserves approvals and price history.
- `DELETE /api/staples/{id}`: 204; remove dependent observations deliberately.
- `POST /api/observations`: `{staple_id, store_id, product_name, price,
  quantity, unit, pack_count, channel, observed_at, source_url?, available,
  approved, conditions?}`. Supported input units oz/lb/g/kg/fl_oz/ml/l/each.
  `quantity` is per pack; `pack_count` integer default 1. price is entire purchase
  package. timestamp ISO with zone. channels in_store/pickup/online.
  approved defaults false, available defaults true. Conditions nonempty means
  not eligible for winner (MVP does not evaluate promotional requirements).
- `GET /api/comparisons?needed_only=false&stores=wegmans,walmart`: array of
  `{staple: {...}, offers: [...], winner_id: number|null}`.
  Each offer includes observation input fields, `id`, `store_name`, `store_location`,
  `unit_price` decimal string|null, `basis`, `eligible` boolean,
  `exclusion_reasons` string array. Winner lowest unit price among eligible,
  available, approved, fresh (<48h), unconditional in_store observations.
  Online/pickup observations remain visible with an exclusion reason. Never
  claim they are verified shelf prices. Freshness reevaluated on every request.
  An Unselected store location is excluded with `location_not_configured` until
  store configuration is implemented. Only the latest observation per
  (staple, store, product_name, canonical quantity, unit, pack_count, channel)
  is shown. This temporary variant identity will be replaced with stable product IDs.
- `GET /api/health`: `{status: "ok"}`.

The service exposes `create_app(db_path=None)` and module `app` from
`staple_scout.main`. `/` redirects to the generated API explorer at `/docs`.
The shopper interface is a future milestone.

No auth in this local-only initial version. JSON writes require same-origin when
Origin is provided. CORS disabled. Docs at `/docs`.
