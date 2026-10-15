# Native keyword price search

Verified October 14, 2026. The shipping flow is staple name → queried product candidates → track fetched evidence → individual match review. Manual price entry and retailer IDs are optional fallback fields, not prerequisites.

## Wegmans

The public storefront loads an Algolia browser-search configuration from its published JavaScript. The native client discovers that configuration from the current page, keeps it only in memory, and submits one bounded `products_v2` query with `soldAtStores:133`, `fulfillmentInStore:133` and `excludeFromWeb:false`. No key is committed, persisted, logged, guessed or obtained from an account. The currently observed asset path is a performance hint; if it changes the client inspects only current same-origin script assets, bounded to 64 entries and a 20-second discovery window (a pending request has a 10-second timeout). Failure is explicit, with no key guessing or login.

Search index hits are discovery evidence only. Each returned numeric identity is validated with the existing exact-store request `https://www.wegmans.com/api/products/133/<productID>` before its price can be displayed as a candidate. Search is capped at five identities per query. Stock, package quantity, conditions and conservative Date/Age source time come from that exact-price parser.

A standalone Swift smoke check searched milk and returned five checked products, including product94427 and product55066. Both reported unavailable at the time of the check; price presence is not stock evidence. No app data was written. These results establish a working retrieval path, not a guarantee of future availability or permission for an automated bulk service.

## H Mart

The documented [VTEX full-text query](https://developers.vtex.com/docs/guides/how-search-parameters-work) uses `ft` with `_from=0` and `_to=4` on `https://www.hmart.com/api/catalog_system/pub/products/search/`. Each discovered product/SKU pair is checked through the existing exact product/SKU parser. A standalone Swift tofu search returned five checked online-reference products, including firm tofu16oz. No local shelf prices or stock are inferred. See the [Legacy Search API](https://developers.vtex.com/docs/api-reference/search-api).

## Failure, persistence and review

All five selected store contexts remain visible. Target, Walmart and Lidl are explicitly disconnected. Successful query pages are cached by normalized query, location, channel and UTC date for the app session. Partial/all exact-price failures are not cached, so explicit retry remains possible. Searches are user initiated and bounded; there are no automatic retry loops, account logins or challenge bypasses. This discovery is separate from the once-per-UTC-day tracked-product refresh.

Searching alone changes no persisted prices or approvals. Tracking saves real fetched price/source/context/time plus a pending product match. Duplicate tracking is idempotent; unchanged approved packages retain review. Package transitions include rejected variants in history so returning to an older package requires a fresh review. Unknown package size cannot be tracked as an exact package. Location changes invalidate old search results. Reports retain the existing ingestion-time cutoffs.

Verification uses offline URLProtocol fixtures and in-memory SwiftData. The separate live Swift smoke check writes no app database. Native UI visual verification remains pending because Simulator computer-use access was declined; no substitute screenshot or GUI access was attempted.
