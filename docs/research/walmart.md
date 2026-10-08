# Walmart source investigation — issue #7

Reviewed 2026-10-06. **Research complete with blocked integration outcome.**
There is no verified current Chantilly #5969 product offer in this result.
The direct public store request returned human-verification HTML. Search-index
evidence identifies five products, but it describes other stores or an unknown
location and cannot supply fresh local prices. Keep the live adapter blocked.

## Direct request and stop condition

One unauthenticated GET was made with system curl, TLS verification enabled,
redirects followed, and a 20-second timeout:

```sh
curl --silent --show-error --location --max-time 20 \
  'https://www.walmart.com/store/5969-chantilly-va/shopping-services'
```

The request completed around 2026-10-06T11:37:07Z. The final HTTP status was
**200**, content type `text/html; charset=utf-8`, and the final URL had path
`https://www.walmart.com/blocked`. Its query contained `url` (the encoded
requested path), `uuid`, `vid`, and `g`; query values were removed from the
committed evidence. The page title was **“Robot or human?”** and its text
requested a hold-button human check. HTTP 200 therefore was not source success.

Stopped that retrieval path immediately. No CAPTCHA interaction, account login,
browser fingerprint changes, proxy, key guessing, or alternate endpoint probes
were attempted. The five products were inspected through already indexed
official pages, not by obtaining a successful direct product response.

[direct-store-block.json](../../tests/fixtures/walmart/direct-store-block.json)
records the sanitized result and raw-body SHA-256. Its approximate retrieval
timestamp is the local curl output file's modification time. Full HTML,
challenge scripts/identifiers, headers, cookies, and private data are excluded.

## Store identity

The indexed [official Chantilly shopping-services page](https://www.walmart.com/store/5969-chantilly-va/shopping-services)
identifies Walmart Supercenter **#5969**, **4368 Chantilly Shopping Center Dr,
Chantilly, VA 20151**, and advertises pickup, delivery, and shipping services.
The retrieval tool labeled this page as crawled three weeks earlier.

This verifies the intended store's public identity, not selection of that store
for product requests or the user's final store preference. The page's statement
about pickup prices matching store prices cannot establish any sampled price or
override the project's rule to keep pickup and shelf observations separate.

## Five-product search-index evidence

The following are **indexed display facts, not current price observations**.
Canonical product URLs were opened through the web retrieval tool. It reported
crawl ages of one to three weeks; no live HTTP response or precise crawl time
was supplied for these products. Currency shown was USD.

| Product / source | Item ID from URL | Quantity evidence | Indexed displayed price | Indexed location / seller |
|---|---|---|---|---|
| [Great Value whole milk](https://www.walmart.com/ip/10450114) | `10450114` | 1 gallon / 128 fl oz | $3.32 package | Sacramento Gerber Rd Supercenter / Walmart.com |
| [Great Value cage-free large white eggs](https://www.walmart.com/ip/124080159) | `124080159` | 12 eggs | $1.67 package, out-of-stock display | No pickup store established / seller not established |
| [Freshness Guaranteed boneless skinless chicken breasts](https://www.walmart.com/ip/27935840) | `27935840` | Title: 2.75–7.0 lb tray; variable weight | $11.92 average package; $2.57/lb | Sacramento Gerber Rd Supercenter / Walmart.com |
| [Great Value long-grain enriched rice](https://www.walmart.com/ip/10315395) | `10315395` | 5 lb / 80 oz bag | $3.37 package | Sacramento Gerber Rd Supercenter / Walmart.com |
| [Fresh banana](https://www.walmart.com/ip/44390948) | `44390948` | Each ordered; final billing by weight | $0.10 each estimate, previously $0.20; $0.25/lb | Morgan Hill Supercenter / Walmart.com |

The milk, chicken, rice, and banana offer areas name Walmart.com as seller.
That is evidence for those displayed offers only; the Walmart domain or a
Great Value brand name does not establish the seller of every offer. The egg
seller remains unknown. No Marketplace offers were accepted into comparisons.

Shipping is shown as out of stock for milk, eggs, rice, and bananas; chicken
shipping is unavailable. Pickup times appear for four products **at the other
named stores**; eggs instead require checking nearby locations. A shipping
stock state must not be treated as pickup stock state. Relative pickup times
in indexed content cannot be interpreted as availability today.

Useful source inconsistencies reinforce that limitation: the banana search
result showed Sacramento and $0.20 while the canonical indexed page showed
Morgan Hill and a $0.10 reduction. Milk likewise differed between indexed
variants. Do not combine fields across page variants or choose the lowest
value from inconsistent contexts. The fixture retains the canonical-page
evidence listed in the table.

## Mapping and coverage

- **Identity:** 5/5 official product URLs and names identified. URL item IDs
  are Walmart identifiers, not UPCs. Barcode coverage is **0/5 verified**; the
  inspected text did not provide a verified barcode mapping, and no raw
  product JSON was retrieved. This does not assert barcodes are absent upstream.
- **Quantity:** three fixed package quantities; chicken and bananas require
  variable-weight handling. Chicken page title and legacy URL/feature weight
  ranges differ; none is an actual package weight. Never divide its average
  price by an arbitrary weight-range endpoint. Eggs compare by count.
- **Prices/channel/store:** 5/5 indexed price displays, **0/5 verified current
  Chantilly pickup or shelf prices**. The pages label prices as online purchase
  prices. Other-store pickup context does not imply nationwide pricing.
- **Availability:** **0/5 current Chantilly values**. Missing availability is
  unknown, not the observation API's default `available=true`.
- **Conditions:** banana reduction is visible, but effective dates and complete
  promotion rules are unknown. Four pages show one-time purchase alongside
  subscription; do not assume subscription is required, subtract membership
  savings, or treat a generic benefits banner as a product discount.
- **Time:** `inspected_on` and the inspection window describe when indexed
  evidence was read, not retailer retrieval, stock freshness, or price validity.
  Source effective timestamps remain unknown. These records cannot be imported
  with today's `observed_at` to pass the app's 48-hour freshness requirement.

The three files in [tests/fixtures/walmart](../../tests/fixtures/walmart) are
explicitly separated into direct challenge evidence and **search-index evidence**.
`indexed-products.json` contains factual transcriptions and short exact source
lines, not a fabricated upstream API schema or successful HTML response. Its
null HTTP status is intentional. No prices or fixtures were loaded into the app.

## Supported API lead and exact unblock requirements

Walmart's official [Item Search API documentation](https://developer.walmart.com/global-marketplace/docs/item-search-for-the-walmart-catalog)
documents `GET https://marketplace.walmartapis.com/v3/items/walmart/search` for
Marketplace item setup/catalog matching and requires `WM_SEC.ACCESS_TOKEN`.
That documentation is not evidence of anonymous access or a store #5969 pickup
price/inventory feed. The API was not called and no credentials were requested.

Resume only with a supported access path and a nonsecret reproducible request
that establishes all of the following together: documented endpoint/method and
access requirements; selection and response verification of store #5969 at the
address above; offer seller identity; pickup versus shipping mode; exact product
and package/billing basis; currency/price; availability; promotion requirements;
and source freshness/effective dates where supplied. Header names and redacted
response fixtures are useful; account credentials, cookies, and tokens must not
be committed. A local manual shelf entry remains a separate evidence source.

No supported, reliable store-local retrieval was demonstrated in the bounded
check. This does not claim that Walmart has no suitable partner API. Do not
enable recurring retrieval or unblock a production adapter from this report.

## Validation

Validated all three JSON evidence files, five distinct official item URLs,
decimal price strings, explicit unknown barcodes/timestamps, and exclusion of
every product from Chantilly coverage. Checked the direct body for the recorded
challenge title and instruction, reviewed sanitization, and ran the staged
whitespace check. No backend code changed; backend tests were not rerun.
