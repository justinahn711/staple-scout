# Native Lidl source research

Research date: 2026-10-16 (America/New_York).

## Selected location and regional identity

The selected store is Lidl `US01112`, 14445 Chantilly Crossing Lane,
Chantilly, Virginia 20151-2116. Its current official store payload identifies
the store as `US01112` and its `marketingData` as `offerRegion` `1112`,
named `Region US1112`. The sanitized `lidl-chantilly-store.json` fixture
records those fields, the source URL, capture date, and site build.

Offer region 1469 does **not** identify this store in the current source. The
same official store payload associates 1469 with Lidl `US01469` at 2901
Gallows Road in Falls Church. Earlier project research treated 1469 as
Chantilly's region; that mapping was stale or mistaken. The native client
therefore requires both selected store `US01112` and product region
`Region US1112`, and never falls back to 1469. Test fixtures assign
deliberately different prices to regions 1112 and 1469 so an accidental
cross-store selection fails visibly.

The store page also links a dated weekly ad, but Lidl exposes a separate
ordinary product catalog. This client uses the catalog and does not treat the
weekly flyer as complete regular-price inventory.

## Public catalog contract

The normal search form submits `GET /q/search?q=<term>`. Its public
JavaScript and server-rendered page publish this request shape:

```text
GET https://www.lidl.com/q/api/search?assortment=US&locale=en_US&version=v2.0.0&q=milk&newArticleFlag=1
Accept: application/mindshift.search+json;version=2
```

No account, cookie, private credential, guessed key, challenge bypass, proxy,
or browser fingerprint was required. The published media type returned HTTP
200; omitting it returned 401.

Products expose stable `code`, `erpNumber`, `itemId`, and `productId`
values, a canonical `/p/.../p<productId>` path, `regionsV2`,
`regionsPrices`, and `renderedTs`. The client requires all identities to
agree, selects exactly one online `Region US1112`, follows its
`regionPriceId`, and uses only that group's `currentPrice`. It never uses
the unregionalized price or another region.

An exact numeric query returns a public redirect such as
`/p/whole-milk/p11675058`. The client verifies the trailing ID, loads the
canonical page, and parses the public `__NUXT_DATA__` payload for the same
identity and regional fields. Every exact fetch performs both requests again;
the client keeps no product-price cache. The shared search layer owns its
bounded daily successful-search cache, while the library owns refresh budget.

## Representative checks

Five keyword requests on October 16 returned current `Region US1112`
records. These checks validate source coverage, not staple matching or stock.

| Query | First regional result | Product ID | Price | Package | Source window (end exclusive) |
| --- | --- | ---: | ---: | --- | --- |
| milk | whole milk | 11675058 | $3.47 | 128 fl.oz. | 2026-10-15T05:34:43.560Z–2026-11-13T06:00Z |
| eggs | Italiamo egg pasta | 11675781 | $1.99 | 8.8 oz. | 2026-10-15T05:35:48.823Z–2026-11-13T06:00Z |
| rice | microwaveable rice | 11673832 | $1.29 | 8.8 oz. | 2026-10-15T05:39:57.217Z–2026-11-13T06:00Z |
| bread | 100% whole wheat bread | 11674404 | $1.89 | 20 oz. | 2026-10-15T05:35:15.258Z–2026-11-13T06:00Z |
| chicken breast | Just Bare frozen oven roasted chicken breast bites | 11972853 | $10.56 | 19.2 oz. | 2026-10-15T06:24:14.438Z–2026-11-13T06:00Z |

The misleading first result for `eggs` is why search results remain
candidates for user matching. The fixtures preserve a generic $3.48 milk
price, a $3.47 US1112 price, and a deliberately distinct $8.88 US1469 price.

## Price, time, package, and availability semantics

This is a regional **in-store catalog price**. It is not proof of shelf stock,
an online purchase price, or an unconditional regular price. Public product
data marks these retail products for in-store use and separately exposes
regional `currentPrice`, old price, and Lidl Plus fields. The client uses
`currentPrice`, reports an old price as a condition when present, and never
substitutes a Lidl Plus price.

The client requires `startDate` and an explicit `endDateExclusive`; it
does not reinterpret the inclusive-looking `endDate`. It rejects a price
unless the retrieval instant is in `[startDate, endDateExclusive)`, stores
those exact bounds as `validFrom` and `validUntil`, and uses `renderedTs`
as `observedAt`. An expired payload is never retimed.

Only fully matched, fixed package strings are parsed with `Decimal`. Text
with extra billing terms, such as `16 oz per lb`, stays variable and
excluded. Ambiguous variant flags are rejected unless the devalued JSON leaf
is a real JSON boolean.

The region's `ONLINE` status and generic `IN_STORE` badge do not establish
stock at US01112. Every result has `available: nil` and a source exclusion
for unknown local stock, preventing it from winning a cheapest-store
comparison. The standalone client remains globally disabled until parent
integration.

## Flyer boundary

The previously observed flyer endpoint remains reference-only dated evidence.
It has incomplete product coverage and may omit conditions. The client neither
combines it with catalog results nor interprets flyer products as current
local stock.

Official sources:

- <https://www.lidl.com/s/en-US/stores/chantilly/chantilly-crossing-lane-14445/>
- <https://www.lidl.com/q/search?q=milk>
- <https://www.lidl.com/p/whole-milk/p11675058>
