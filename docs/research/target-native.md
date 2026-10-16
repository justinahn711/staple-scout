# Native Target source gate

Inspected 2026-10-16 against the ordinary public Target website. **Native
keyword search and exact-price lookup remain blocked, so no Target networking
adapter is included.**

## Verified public context

- `https://www.target.com/sl/chantilly-store/1827` returned HTTP 200 and
  identified Target store 1827 at 14391 Chantilly Crossing Ln, Chantilly, VA
  20151-2118.
- `https://www.target.com/sl/chantilly/1827/grocery` returned HTTP 200. Its
  server-rendered data explicitly set `storeIdOverride` to `1827` and included
  the Chantilly location and address.
- That grocery page included some curated recommendation records whose
  fulfillment objects named location 1827 and distinguished pickup,
  curbside, and in-store-only availability. These records demonstrate that the
  storefront can render store-scoped recommendations. They do not provide an
  arbitrary keyword-search contract. Their single price object was not bound
  to a specific fulfillment channel, and the records inspected did not prove
  a first-party seller. They therefore cannot be imported as either shelf or
  pickup observations.

## Search blocker

The public `https://www.target.com/s?searchTerm=milk` page returned HTTP 200
and its server location variables selected store 1827, but product search was
deferred to a client request. The current page JavaScript and public
configuration identify the RedSky `plp_search_v2` route and construct its
store parameters from the selected location, including pricing store 1827.
The public configuration value was read only in memory and was not printed,
saved, or committed.

One request matching that published route and parameter construction returned
HTTP 435 with Target's human-verification document: "Before we continue" and
"Press & Hold to confirm you are a human." The challenge was not attempted or
bypassed. No alternate credentials, cookies, proxies, fingerprints, guessed
keys, or undocumented parameter variants were used.

## Exact-product blocker

The Target product URL linked by the Chantilly grocery page for TCIN 95116850
(`Thomas Plain Bagels - 18oz/6ct`) returned HTTP 200. Its server-rendered data
verified the TCIN, title, 18-ounce/six-count package description, primary
barcode, and the server location variables for store 1827. The price and
fulfillment modules were placeholders marked for deferred client enrichment;
the response contained no `current_retail`, seller identity, store option, or
pickup availability for this product. The exact-price path therefore depends
on the same client-side access that cannot be exercised without encountering
the human-verification gate.

## Decision

The source gate requires reproducible keyword discovery and exact-product
evidence that binds product identity, package quantity, first-party seller,
price, chosen store, channel, availability, conditions, and observation time.
The public pages currently prove only parts of that contract, while the request
that supplies the missing search and offer data is challenged. Search-index
text and curated recommendation prices are not relabeled as current Chantilly
offers.

No `TargetClient`, fixtures, source registration, capability change, or live
request tests were added. Target should remain disconnected until ordinary
public access can return the full contract for store 1827 without challenge
interaction or another supported source becomes available.

The bounded check used five live Target page/API requests, sequentially with
20-second timeouts, plus the JavaScript assets referenced by the public search
page. No automated account login or user data was involved.
