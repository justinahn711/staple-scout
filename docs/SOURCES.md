# Retailer source evidence

Updated October 8, 2026 (America/New_York). The registry includes validated
Wegmans Chantilly in-store evidence and H Mart online reference evidence. App
startup performs no retailer request. Other sources remain disconnected pending
their separate validation gates; see each research PR for its current evidence.

| Retailer | Location | Current evidence | Integration state |
|---|---|---|---|
| Wegmans | Chantilly #133 verified | Anonymous public product JSON confirms store/channel; five-product gate passed | `wegmans_in_store`, in_store only |
| Walmart | Chantilly Supercenter #5969, tentative user location | Official local store page lists grocery pickup and delivery | Not connected |
| Target | Chantilly #1827 verified in research PR22 | Normal browsing reaches human verification; five-product price gate incomplete | Not connected |
| H Mart | Centreville shelf context; online catalog separate | Five exact product/SKU online references validated; no local shelf correspondence | `hmart_online`, online reference only |
| Lidl | User-selected Chantilly US01112 | Research PR25 documents regional/flyer evidence and unresolved regular-price/stock semantics | Not connected |

## Wegmans

- [Developer portal](https://developer.wegmans.io/): public entry is sign-in; this
  does not establish that the product pricing API is accessible to this project.
- [Chantilly store](https://www.wegmans.com/stores/chantilly-va).
- [Ordering information](https://www.wegmans.com/grocery-delivery-pickup): Wegmans
  says online ordering prices are about 15% above in-store prices. Preserve the
  actual channel; never derive shelf prices by dividing by a blanket markup.

See [Wegmans evidence and limits](research/wegmans.md) for the observed public
website request, five-product fixture, stock/promotion/weight semantics and
explicit disposable-database live smoke command. The developer portal is not
needed for this validated website path. No physical shelf verification or recurring-access permission is claimed.
The historical issue1 report and all original research fixtures are retained
separately from the newer JSON price evidence.

## Walmart

- [Chantilly shopping services](https://www.walmart.com/store/5969-chantilly-va/shopping-services)
  identifies store #5969 at 4368 Chantilly Shopping Center Dr.
- [Pricing FAQ](https://corporate.walmart.com/askwalmart): store prices may vary.

Next: establish a stable request for local pickup offers and product identity.
Confirm the response location and seller. Exclude Marketplace and shipping-only
offers. Mark pickup prices as pickup until actual shelf observations support a
separate shelf record. Online visibility is not evidence that automated retrieval
will be dependable.

## Target

- [Pricing details](https://www.target.com/help/article/000194850): online and
  in-store prices can differ, with location and promotional distinctions.

Next: reproduce the brief's RedSky request, verify Chantilly location, and identify
the relevant pricing field. Keep internal endpoint maintenance isolated inside
one adapter. Do not hardcode or publish a guessed access key.

## H Mart

- [Online/store price differences](https://support.hmart.com/hc/en-us/articles/4408935803411-Why-is-there-a-price-difference-between-in-stores-and-online).
- [Regional differences](https://support.hmart.com/hc/en-us/articles/4408935824915-Why-do-products-and-prices-vary-by-state).
- [Online catalog](https://www.hmart.com/).

H Mart states online and store prices can differ and that inventory/pricing varies
by region. Equal API prices across two locations do not prove national coverage
or local shelf accuracy. A spot check needs exact product/size, store, date, and
promotion context; three matching items cannot validate the entire catalog.

Next: reproduce the VTEX request and preserve online channel plus barcodes.

## Lidl

- [US website](https://www.lidl.com/).
- [myLidl deals](https://www.lidl.com/mylidl-deals?category=all): includes membership
  offers and "must buy" quantities.

Next: choose the actual store, test regular-price coverage as well as weekly
offers, and retain effective dates and purchase conditions. A promotional flyer
alone does not establish complete staple coverage.

## Evidence required to enable any adapter

Keep a sanitized fixture, extraction mapping, source URL, confirmed store/channel,
verification date, and known gaps. Return unknown when quantity or price context
is unresolved. Log failures without updating a saved price's observation date.
Do not commit cookies, login details, session tokens, or personal account data.
