# Lidl Chantilly source research

Reviewed 2026-10-08 (America/New_York). Selected location is Lidl store
`US01112`, at 14445 Chantilly Crossing Lane, Chantilly, VA 20151-2116. The official
store page returned HTTP 200 and exposes the address in both Schema.org JSON-LD
and visible page text. Its metadata links to the official Weekly Ad page
`/c/offers-leaflets/s10092873`.

The public store payload identifies offer region `1469` and exposes a
`/p/api/storestock` path, but does not include product records in this page
response. The Weekly Ad page also returned HTTP 200, but explicitly presents a store
selection/regionalization overlay before showing offers. The response did not
contain product offer records, prices, effective dates, or regular-price
catalog data for the selected store. No login, challenge bypass, guessed store
key, or private endpoint was used. Therefore this research does not establish
five representative staple prices or regular-price coverage, and no Lidl
adapter should be enabled.

The store fixture preserves exact address evidence and the offer-page access
result. A normal GET to the payload-exposed `/p/api/storestock` path returned
HTTP 404 (`The current request is not defined by this API`) at
2026-10-08T04:14:00Z. CUA could not perform the UI selection because the
configured environment reported `Browser is not available: chrome`; no
selection or prices were fabricated. It is not a price fixture. A future bounded attempt needs the supported
store-selection flow or a documented public regional feed, then must capture
five items with product identity, package size, regular versus promotional
price, effective dates, membership eligibility and must-buy quantity. Flyer
images alone cannot establish complete regular-price coverage.

Sources: [Chantilly store](https://www.lidl.com/s/en-US/stores/chantilly/chantilly-crossing-lane-14445/), [Weekly Ads](https://www.lidl.com/c/offers-leaflets/s10092873).
