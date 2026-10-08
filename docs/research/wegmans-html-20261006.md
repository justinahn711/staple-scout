> Historical record captured October 6, 2026. Price-access conclusions below
> are superseded by the October 8 client-rendered JSON gate in
> [current Wegmans research](wegmans.md). Original catalog, environment and
> access/usage evidence is retained without relabeling it as price evidence.

# Wegmans source investigation — issue #1

Reviewed 2026-10-06. **Catalog evidence obtained; live price adapter blocked.**
Five public product pages returned HTTP 200 with product identity and quantity
information. None supplied a price offer, availability, or a verified Chantilly
price context. No price observations were imported or enabled.

## Access and reproducible evidence

The bounded direct check used unauthenticated GET requests with system curl,
TLS verification enabled, redirects followed, a 20-second timeout, and at most
two concurrent requests. No account login, cookies, keys, challenge handling,
or endpoint guessing was used. Five product pages and the store page completed
between 2026-10-06T11:33:27Z and 2026-10-06T11:33:29Z.

- [Developer portal](https://developer.wegmans.io/): HTTP 200 **after redirect**
  to `https://developer.wegmans.io/signin?returnUrl=%2F`, an HTML sign-in page.
  The direct check completed during 11:32:48–11:33:04 UTC. This is not a JSON
  API success or evidence that all Wegmans APIs require authentication.
- [Chantilly store](https://www.wegmans.com/stores/chantilly-va): HTTP 200,
  HTML. The visible address is 14361 Newbrook Drive, Chantilly, VA 20151.
  Embedded page data contains `"storeName":"Chantilly","storeNumber":133`.
  This confirms the **website store number**, not an undocumented API's store
  parameter or selection of that store for any product request.
- Each product URL in the table below returned HTTP 200 with
  `text/html; charset=utf-8`; none redirected.

Earlier Python requests failed on sandbox DNS resolution, then on the local
Python certificate trust configuration outside the sandbox. System curl
succeeded without disabling certificate verification. These are environment
failures, not evidence of a retailer block; exact diagnostics are retained.

The fixtures in [tests/fixtures/wegmans](../../tests/fixtures/wegmans) contain
genuine sanitized projections of those HTML responses, **not invented API
responses**. They preserve source URLs, request/completion timestamps, status,
content type, SHA-256 of the original response, selected original JSON-LD
fields, and short visible text excerpts. Full HTML, scripts, response headers,
cookies, product descriptions, and private data are not committed. Hashes allow
comparison against the captured response, not future dynamic responses.

## Five-product coverage

The identifier column is `Product.sku` from the page's
`script[type="application/ld+json"]`; it also agrees with the URL identifier.
These are catalog identities, not automatically approved staple substitutes.

| Sample / source URL | SKU | Raw `gtin13` string | Visible quantity | Safe interpretation |
|---|---|---|---|---|
| [Wegmans Vitamin D Whole Milk](https://www.wegmans.com/shop/product/94427-Milk-Vitamin-D-Whole) | `94427` | `00077890944271` | `1 gallon` | Fixed volume; 128 US fl oz if mapped using the US gallon convention |
| [Wegmans Grade AA Large Eggs, 12 Count](https://www.wegmans.com/shop/product/80133-Grade-AA-Large-Eggs-12-Count) | `80133` | `00077890801338` | `12 ct.` | 12 eggs; do not substitute nutrition-serving weight for count |
| [Wegmans Boneless, Skinless Chicken Breasts with Rib Meat, FAMILY PACK](https://www.wegmans.com/shop/product/57084) | `57084` | `02002867000009` | `Avg. 4.8 lbs` | Estimated variable package weight; not an actual purchase weight |
| [Wegmans Long Grain White Rice](https://www.wegmans.com/shop/product/47264-Long-Grain-White-Rice) | `47264` | `00077890297957` | `5 lb.` | Fixed weight, 80 oz; dry rice product |
| [Bananas, Sold by the Each](https://www.wegmans.com/shop/product/92685-Bananas-Sold-by-the-Each) | `92685` | `00000000040112` | `Avg. 0.38 lb` | Estimated weight per banana; billing basis remains unverified |

**Barcode anomaly:** all five fields named `gtin13` contain **14 digits**.
Preserve the exact strings and their source field name. They are not validated
GTIN-13/UPC identifiers. Do not cast to integers, strip leading zeros, repair
check digits, infer a fresh-produce PLU, or derive variable-weight prices from
them. A future mapping needs explicit validation and a documented identity
policy. The fixtures retain the original values rather than relabeling them.

Coverage achieved: **5/5 product identities and displayed quantities; 5/5 raw
barcode strings; 0/5 verified Chantilly prices; 0/5 availability values; 0/5
price conditions or effective periods.** Product presence is not stock evidence.

## Field mapping and missing information

| Destination concept | Evidence / rule |
|---|---|
| Product identifier and name | JSON-LD `sku` and `name`; preserve retailer namespace |
| Barcode | Raw JSON-LD `gtin13`, with the anomaly above |
| Quantity | Visible quantity text next to the product title; raw excerpt retained |
| Brand | JSON-LD `brand.name` when present; absent for bananas |
| Store identity | Store page identifies Chantilly #133; no corresponding store association in the product responses |
| Channel | Product pages display an `In Store` UI label, but this alone does not establish a location-specific in-store offer |
| Package/unit price and currency | Unknown; no JSON-LD `offers` on any of the five pages and no visible product price in the captured HTML |
| Availability | Unknown; do not use the observation API's `available=true` default |
| Conditions and promotional dates | Unknown, not equivalent to unconditional; a generic chicken marketing description is not a priced promotion |
| Retrieval time | Fixture `retrieved_at` is local request completion time, not source price freshness |
| Effective time | Unknown; no source-issued price effective timestamp or validity period found |

Do not call `POST /api/observations` for these catalog records: required price
and verified channel context are missing. In particular, do not map the `In
Store` label to an eligible shelf-price observation or average chicken/banana
weights to exact packages. An eventual adapter needs stable product identity
and explicit handling of estimated versus actual weights; the present API has
neither dedicated variable-weight metadata nor a separate effective timestamp.

Wegmans' [ordering information](https://www.wegmans.com/grocery-delivery-pickup)
states that ordering prices are approximately 15% above in-store prices.
This does not establish any sampled product's price or authorize conversion
between channels. Never divide an online price by 1.15 to invent a shelf price.

The [site terms](https://www.wegmans.com/terms), sections 3 and 10, describe
restrictions on systematic extraction without written consent and differences
by shopping mode. Public readability does not establish a supported recurring
integration. A supported API/access agreement remains a separate requirement.

## Exact blocker and next evidence needed

The previously reported working JSON request is absent from the project brief.
The inspected public developer entry provides sign-in instead of an accessible
endpoint contract. No authenticated or undocumented price endpoint was tested.
The positive catalog result does not remove this blocker.

To resume, obtain a nonsecret reproducible request or supported API documentation
containing:

1. Exact base URL, path/version, HTTP method, parameter/body names, and required
   header **names**, plus the permitted access mechanism. Do not supply account
   passwords, cookies, bearer tokens, or subscription-key values in the report.
2. The supported store identifier and evidence that it resolves to Chantilly at
   the verified address; establish whether website number `133` is that ID.
3. Explicit shopping-mode selection and response evidence for `in_store`,
   `pickup`, or `online`; no inference from the site header alone.
4. A sanitized successful response for these five products showing product
   identity, package/billing basis, currency, actual price, availability,
   promotion requirements, and any effective/source-update timestamps.
5. Supported usage/rate limits and access permission for the planned daily
   retrieval. Validate one bounded request before scheduling anything.

Stopping here is the research outcome. The live adapter remains not connected;
there is no claim that a supported API does not exist. Catalog fixtures can
support later parser work but cannot validate price parsing or price accuracy.

## Validation performed

- Checked all eight fixture JSON files parse and all five source SKUs/quantities
  match the saved public responses; confirmed the five barcode lengths are 14.
- Confirmed each product's original JSON-LD has no `offers`; fixtures preserve
  the original key list so omitted descriptions cannot be mistaken for offers.
- Confirmed embedded Chantilly store number/address and portal sign-in title.
- Reviewed the diff for credentials and raw response content; ran
  `git diff --check`. No backend code changed, so backend tests were not rerun.
