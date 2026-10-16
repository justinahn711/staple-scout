# Native Walmart source gate — October 16, 2026

**Local-price integration remains blocked.** The native iPhone app must not produce a live Walmart candidate from the evidence captured here.

## Ordinary public website check

One unauthenticated GET of the [Chantilly5969 shopping-services page](https://www.walmart.com/store/5969-chantilly-va/shopping-services), with redirects followed, TLS verification and a20-second timeout, returned HTTP200 HTML titled “Robot or human?”. A human-verification prompt was present. This is not a successful catalog or price response. The retrieval path stopped; no challenge was attempted, alternate hidden route guessed, account used, fingerprint changed or proxy introduced.

The sanitized gate record is `iOS/Packages/StapleScoutKit/Tests/StapleScoutKitTests/Fixtures/walmart-access-gate.json`. It records the response hash, actual file retrieval time, title, zero verified prices and disabled adapter state. Raw HTML, redirect identifiers, cookies and keys are not committed. No fixture or indexed price was imported into an app database.

## Relevant supported API lead

Walmart I/O's [Online Pickup & Delivery introduction](https://www.walmart.io/docs/opd/stores/grocery-introduction) describes product details plus localized prices and availability by ZIP code. The [services overview](https://www.walmart.io/docs/dv-dsd-api/v1/try-our-apis-with-swagger) lists OPD as subscription based. This is a better source candidate for the requested integration than the Marketplace seller catalog APIs examined previously.

The official [store-locator contract](https://walmart.io/docs/opd/quick-start-guide/catalog-store-service-locator) requires Walmart developer consumer/client credentials and an OAuth token. Its documented token route is `POST https://developer.api.walmart.com/api-proxy/service/identity/oauth/v1/token`; the store-service route is `POST /affil/storeservice/v1/storeServiceLocator`, with a postal-code payload and an optional pickup filter. These are documentation facts, not successful live calls. No protected API or authentication call was made, and no credentials were requested in chat.

Store-locator documentation alone does not establish the exact authorized product/offer request or response, a currently valid OPD subscription, or a successful store5969 price. Shipping/catalog snapshots and Marketplace buy-box prices cannot substitute for pickup pricing. Secrets must never be embedded in the shipping iPhone binary or committed to this repository.

## Concrete unblock requirements

1. Approved OPD developer access and its permitted read-only product-price contract. Do not send passwords or API keys in chat.
2. A normal authorized store-locator response that establishes the chosen5969 store/access point, followed by five exact local product/offer checks.
3. Verified first-party seller, pickup channel, package/billing basis, currency/price, availability, conditions and source freshness. Marketplace, shipping-only, wrong-store and unresolved offers must fail closed.
4. Sanitized real response fixtures and offline tests before enabling native keyword search or tracked-product refresh.

Until then, #10 remains blocked by #7/source access. No speculative or simulated Walmart adapter is added. Research is useful progress, but does not satisfy the original live-source acceptance criteria. The standalone native source identifier does not enable retrieval.

## Validation

The gate fixture parses, records zero live prices and explicitly disables comparison eligibility. Reviewed sanitization and `git diff --check`. This branch changes research evidence only; no backend or native networking behavior changes, and no user database or simulator was accessed.
