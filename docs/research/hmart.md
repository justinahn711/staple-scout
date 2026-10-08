# H Mart online catalog research

Reviewed 2026-10-08 (America/New_York). Outcome: **online reference source is viable; shelf/pickup adapter remains disabled**. An unauthenticated HTTPS request to the official VTEX endpoint returned HTTP 206 JSON (`resources: 0-4/538`) at 2026-10-08T04:10:07Z. The fixture captures five rice-query records with product/item IDs, barcodes, package text, seller, price, availability, quantity and price-valid-until. No key, login, or challenge bypass was used.

The normalized fixture `tests/fixtures/hmart/catalog-rice.json` and API-shaped subset `tests/fixtures/hmart/raw-catalog-rice.json` record the five products. They are online observations with API-reported availability but no store/region location, so they must not enter shelf or pickup ranking. Retrieval time is 2026-10-08T04:10:07Z; each record's `PriceValidUntil` is preserved separately.

The earlier Hapi snack page is not used as API evidence. The API sample is rice-category only, not evidence of complete staple or fresh-produce coverage. Produce remains an explicit gap: no produce record was queried and the response provides no store-level stock evidence. H Mart documents that online/store prices and regional offers vary, so online prices cannot be relabeled as Centreville shelf prices.

The future common adapter needs retailer product ID, barcode as a string, canonical name, exact package size/form, pack count, seller, Decimal price/currency, availability, conditions, channel, location, source URL, source-effective timestamp, and retrieval timestamp. The API supplies these identity/offer fields but no store/region context. Unknown quantity or variable-weight produce must remain unknown.

The endpoint is implementable as an online-only reference adapter after the common ingestion contract exists. It still needs explicit handling for HTTP 206 pagination, stale/expired `PriceValidUntil`, and the absence of store/region context. Sources: [VTEX search response](https://www.hmart.com/api/catalog_system/pub/products/search/?ft=rice&_from=0&_to=4), [Hapi](https://www.hmart.com/hapi), [online/store price FAQ](https://support.hmart.com/hc/en-us/articles/4408935803411-Why-is-there-a-price-difference-between-in-stores-and-online), [regional variation FAQ](https://support.hmart.com/hc/en-us/articles/4408935824915-Why-do-products-and-prices-vary-by-state).

## Implemented reference adapter (2026-10-08)

`hmart_online` is now a verified **online-only** registration. Constructing the
app/registry performs no HTTP request. Refresh still requires an explicit online
location context with no retailer location ID and explicit selected staple/product
pairs. The Centreville shelf context stays separate and its price source stays
unconnected. The registration cannot fetch shelf or pickup prices.

Identities are `productId:itemId` (for example `8011:8027`), because VTEX product
and SKU IDs differ. The adapter queries the documented public search endpoint
with `fq=productId:<productId>`, then filters that exact SKU. A bounded ordinary
request verified product8011/item8027 at 2026-10-08T12:22:49Z. The end-to-end
five-product adapter smoke then succeeded in a disposable database; its validated,
whitelisted evidence is in `tests/fixtures/hmart/live-composite-gate.json`.
Every imported match started pending and online records could not win either
local comparison mode. No raw tokens or checkout payloads enter these fixtures.

The HTTP Date and Age metadata retain a conservative original response time
separately from local retrieval time; cached payloads do not get silently retimed
to retrieval. `PriceValidUntil` is retained and expiration is reevaluated by the
common comparison path. HTTP errors, malformed stock/time/identity and unexpected
products fail safely. Only seller1 / HMart - US is accepted; another seller is a
coverage gap. Response count and HTTP timeout are bounded; no login or retries.

Package size uses the first explicit printed size when clear. Alternate metric
labels must describe approximately the same package; ranges, multipacks, kits,
unknown sizes and conflicting labels stay unresolved. Barcode source text stays
text. Form retains the source Refrigerated/storage field (for these five records,
Dry), independently of cosmetic product titles. Missing storage is explicitly
Unspecified; a later storage/form change creates a new pending variant. The
source field is copied from the original captured raw response into the
sanitary fixture; product identity and match review still determine whether a
rice paper, snack or rice bag satisfies a staple. Source price/list-price differences and unverified discount terms are
kept in conditions. Online stock never claims Centreville availability.

Coverage remains the five-product rice-category gate, including rice paper and
snacks. It is not a complete staple or produce catalog, and those category gaps
must stay visible to users. The API supports explicit selected identities, not
automatic substitute discovery. Product matches always require human review.

Implementation reference: [VTEX Legacy Search API](https://developers.vtex.com/docs/api-reference/search-api).
