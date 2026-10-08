# Wegmans Chantilly in-store evidence

Validated 2026-10-08. The anonymous public Wegmans product page showed
**In Store · Chantilly**, a price, and Sign In / Register. Its observed browser
resource inventory included `/api/products/133/94427`. Ordinary unauthenticated
GET requests to this exact public website endpoint returned JSON, without a key,
login, browser automation at refresh time, or challenge bypass. This is an
observed website interface, not a claim of an officially documented developer
API or a permanent access guarantee. Earlier research in PR18 found no prices
in initial HTML; the client-rendered product request supplies this new evidence.
The [historical October6 report](wegmans-html-20261006.md) and all eight original
research fixtures are preserved. Regression tests replay those projections and
diagnostics as negative cases: none can become price evidence, and the five
source barcode strings remain unchanged.

The [store JSON](https://www.wegmans.com/api/stores/store-number/133) confirms
storeNumber/id133, name Chantilly, 14361 Newbrook Drive, Chantilly VA20151.
Every captured product also identifies storeNumber133 and a
`price_inStore.channelKey` of `133-Instore`. Delivery and loyalty prices are
separate fields. We use only `price_inStore.amount` and preserve `in_store`;
this is the retailer website's stated channel, not a physical shelf spot check.
Pickup and delivery are unsupported by this adapter.

## Five-product gate

The sanitized API subset is `tests/fixtures/wegmans-products.json`. The
end-to-end live gate is `tests/fixtures/wegmans-live-gate.json`, with HTTP Date
2026-10-08T13:18:22Z and exact per-record retrieval times. Responses reported
`Cache-Control: max-age=0, no-cache, no-store`. Values are evidence at this time,
not a guarantee of present price or stock.

| Product ID | Product/package | Base in-store amount | Evidence qualification |
|---|---|---|---|
| [94427](https://www.wegmans.com/api/products/133/94427) | Vitamin D Whole Milk, 1 gallon | $3.39 | `isAvailable:false`, despite `isBuyable:true`; unavailable |
| [80133](https://www.wegmans.com/api/products/133/80133) | Grade AA Large Eggs, 12 ct. | $1.69 | Fixed 12-count, source availability true |
| [57084](https://www.wegmans.com/api/products/133/57084) | Boneless Skinless Chicken Breasts, family pack | $11.00 estimated | 4.8 lb approximate purchase weight, $2.29/lb source rate; loyalty alternative $9.56/$1.99 per lb, expires October18, eligibility unverified |
| [47264](https://www.wegmans.com/api/products/133/47264) | Long Grain White Rice, 5 lb. | $3.49 | Coupon IDs present without offer details; terms unresolved |
| [92685](https://www.wegmans.com/api/products/133/92685) | Bananas, sold by each | $0.19 estimated | 0.38 lb approximate weight, $0.49/lb source rate; coupon details missing |

The live gate produced five observations, including one unavailable and two
estimated quantities. It did not approve any match; consequently none could
win. Offline integration tests explicitly approve fixture matches and verify
only ordinary eligible eggs win shelf mode, while unavailable, estimated and
conditional records remain excluded. No in-store record can win pickup mode.

## Mapping and conservative limits

- `objectId`, `skuId`, `productID`, `productId`, `storeNumber`, and the in-store
  channel key must agree with the exact requested product/store. Missing or
  conflicting identities fail; no request-derived identity defaults are used.
- IDs are explicit ASCII numeric strings, at most50 selected products per call.
  The default registered source is `wegmans_in_store`, store133 only, seller
  Wegmans, channel in_store. Nonempty vendor-sale fields are refused.
- JSON numbers become Decimal before extraction. `amount` is the displayed
  whole-purchase price, not `formattedAmount` or `fulfillmentPrice`. The latter
  differs for weighed groceries. Delivery and conditional prices never replace
  a missing base price.
- Fixed `packSize` supports only explicit lb/oz/count/ct/gallon labels, optional
  trailing period. US gallons convert exactly to128 US fluid ounces. Multipacks,
  conflicting labels, ranges and other unknown units stay unresolved rather
  than using product-title guesses. Pack count is1 for these supported labels.
- For `isSoldByWeight:true`, the observed `packSize:1 lb.` is a billing basis.
  A positive `onlineApproxUnitWeight` with the source's pound unit-price label
  supplies only an estimated purchase weight; package total and printed unit
  rate are retained with an uncertainty explanation. Their rounded ratio may
  differ. Estimated/variable packages cannot win or produce exact outlay.
- Availability is false if either `isAvailable` or `isSoldAtStore` is false;
  true requires both true; missing flags remain unknown. `isBuyable` does not
  establish stock. Source stock is not guaranteed physical shelf inventory.
- UPC arrays remain source strings, including leading zeros. The primary
  source UPC is copied into the singular evidence barcode field; the complete
  list remains in the public fixture. IDs/packages define variants; barcode
  equality never merges products or approves substitutions.
- Form retains the most specific explicit catalog category. This is labeled
  as a catalog category, not an inferred fresh/frozen form. A changed category
  or package creates a pending variant; cosmetic product-name changes do not.
- Loyalty base/alternative amounts, expiry, trigger/discounted quantities and
  cart limits are retained as conditions. Coupon IDs with missing details,
  unsupported coupon schemas and nonzero deposits stay conditional. This
  conservative version can exclude an ordinary base price when coupon
  eligibility is unresolved; it never assumes the discounted price applies.
  Conditional expiry is not applied as the regular base-price expiry.
- HTTP Date and Age preserve the older observed-time bound separately from
  retrieval; malformed/future metadata fails. There is no source price-effective
  timestamp. Without HTTP Date, retrieval minus any valid Age is the available
  observation bound; this never claims when a retailer changed the price.
- Missing price, quantity or stock produces unresolved evidence. HTTP403/404,
  malformed identity, or network failures record safe source status and retain
  previous observations/timestamps. New successful unknown evidence suppresses
  an older automatic recommendation. No raw HTML, account data or exceptions
  are stored. See the common refresh contract for actionable error codes.

This gate covers exactly these five products, not the entire catalog. Missing
or replaced SKUs require explicit selection and review; the unavailable milk
is not silently substituted with a different product. Website contracts can
change. The adapter uses httpx with a bounded timeout and has no embedded keys,
login, automatic retries, search/discovery, browser fallback or background fetch.
The daily runner supports explicit staple/product pairs, but installing or
starting the app never activates it. Public readability verifies the data
contract, not permission for recurring extraction. The historical report records
site usage restrictions and the unresolved supported recurring-access question.
No recurring retailer fetch was installed or activated.

## Explicit live validation

From this checkout, run `uv run python -m scripts.smoke_wegmans --live`.
Without `--live` the command refuses to fetch. It always creates and removes a
new temporary database, isolates module-level initialization, fetches exactly
these five IDs, checks source provenance and pending matches, and prints only
normalized public evidence. It has no real-database argument. Offline tests
never call retailers; use `uv run pytest`.
