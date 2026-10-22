# Public-pilot price source decision — issue #41

Reviewed **October 21, 2026**, America/New_York. Outcome: **research complete;
all five retailers remain disabled for public fetching/display**. This is a
source decision, not a new adapter, permission grant, public beta, or deployment.
It does not complete the unresolved Target #4 or Walmart #10 integrations.
Walmart and Target remain requested coverage; removing either or reducing the
catalog/cadence needs an explicit owner decision.

The existing [local prototype](../SHARED_PRICE_PILOT.md) stays separate. Its
personal `local-research` option and tested Swift fetchers are not evidence that
their results can be redistributed to testers. No code, source capability,
credentials, account, subscription, user library or scheduler changed here.

## Evidence and decision rules

**Published** below means a statement in the linked primary documentation, read
on the review date; the document's own update date is recorded where available.
**Prior check** means dated project evidence, not a fresh price observation.
**Decision/inference** is our conservative engineering choice. **Open** means
the documentation or available access did not settle the question; it is not a
claim that no suitable agreement or API exists.

This pass read public documentation/store pages. Web retrieval can return cached
pages, so its read date does not establish current product-price freshness.
It made **zero authenticated provider calls and zero new retailer price queries**.
No key/account was available; no account or paid trial was created. The earlier
human-verification stop conditions in [Walmart PR35](https://github.com/justinahn711/staple-scout/pull/35)
and [Target PR36](https://github.com/justinahn711/staple-scout/pull/36) were retained,
without retrying challenges or collecting credentials.

For public enablement, both gates must pass: (1) usable, reproducible evidence for
the exact product/store/channel, and (2) an applicable agreement covering public
display, shared caching, historical retention/deletion and attribution. A free
plan, anonymous response, affiliate approval, source hyperlink or browser API key
alone does not establish both. The decisions here are not legal conclusions.

## Retailer decision matrix

| Retailer | Candidate and exact intended context | Available evidence / maintenance risk | Public decision and missing gate |
|---|---|---|---|
| Wegmans | Existing public website product JSON; Chantilly **133**, 14361 Newbrook Dr; `in_store` only | Prior native exact checks and keyword search work. Website JSON/search configuration can change; no published daily quota or service guarantee established. | **Disabled**. Obtain applicable written access/display/cache/retention terms, attribution and rate limits before sharing. |
| Walmart | Preferred official lead: Walmart I/O **OPD**; potential alternative: SerpApi Walmart Product. Chantilly **5969**, 4368 Chantilly Shopping Center Dr; **pickup**, not shelf | Official store identity confirmed; no accepted five-product local response. OPD needs private-partner approval; user has none. Website was challenged in PR35. Provider schema is a lead, not a successful local test. | **Disabled**. Approved OPD access and an agreement permitting this comparison/history use, or a suitable provider agreement plus five real local checks. |
| Target | Potential technical lead: SerpApi Target Search; direct RedSky remains an internal website dependency. Chantilly **1827**, 14391 Chantilly Crossing Ln | Official store identity confirmed. PR36 could not bind price, seller and fulfillment completely. Provider supports store-scoped searches but may return online prices/ranges and incomplete seller/size evidence. | **Disabled**. Resolve public display/cache/retention rights and provider access; pass five-product store/seller/channel gate. No available public native-app price-feed agreement established. |
| H Mart | Existing VTEX catalog; **online reference**, no local store code | Prior exact `productId:itemId` checks preserve barcodes and online stock; Centreville shelf/pickup coverage and fresh-produce completeness remain unverified. API shape/sellers can change. No published H Mart extraction quota established. | **Disabled**. Obtain applicable permission/terms, retention and attribution rules. Keep online-only status even if a few shelf prices match. |
| Lidl | Existing regional catalog; Chantilly **US01112**, 14445 Chantilly Crossing Ln; **Region US1112**, `in_store` catalog evidence | Prior native discovery/exact smoke works; local stock stays unknown. Offer dates, regional identity and page payloads need validation. Region 1469 is Falls Church, not Chantilly. No published catalog quota established. | **Disabled**. Establish public catalog reuse/cache/history terms and attribution. Even with permission, unknown stock cannot win comparisons. |

The official [Walmart store page](https://www.walmart.com/store/5969-chantilly-va)
and [Target store page](https://www.target.com/sl/chantilly-store/1827) identify
those physical stores and pickup services. This confirms the proposed IDs and
addresses, **not** any API response's selected context or product stock. Walmart
5969 remains the app's intended working location until the owner's preference
and an authorized locator/offer response agree. [Wegmans' store page](https://www.wegmans.com/stores/chantilly-va)
confirms the address; store 133/product evidence is in the prior implementation.

### What existing working sources actually establish

| Source | Identity, quantity and availability | Time, price type and conditions |
|---|---|---|
| Wegmans, prior checks October 8/14 | Exact product IDs plus store 133 and `133-Instore`; UPC strings; explicit package size. Estimated/unknown weights and incomplete stock flags remain uncertain. | Base in-store price, conservative HTTP Date/Age observation bound, separate retrieval time; loyalty/coupon terms retained. No markup reversal or automatic substitute approval. |
| H Mart, prior checks October 8/14 | Exact product/SKU composite, barcode string, explicit size; seller HMart - US. Online catalog availability does not establish Centreville stock; produce/category gaps remain explicit. | Online price, source HTTP Date/Age and retrieval time; unresolved discount terms remain conditions. Existing native parser retains `PriceValidUntil` text in conditions when supplied, but does not set a structured `validUntil`; that gap needs resolution before public reuse. |
| Lidl, prior checks October 16 | Exact product and selected region 1112; fixed package parsing only. No local-stock field: `available=nil` plus exclusion. | Regional current price, `renderedTs` observation, separate retrieval, explicit start/end-exclusive window; no Lidl Plus substitution. Conditional/unknown evidence cannot become an unconditional shelf offer. |

These are inherited test/research facts, not new measurements or public licenses.
See [native search evidence](native-search.md), [native Lidl research](lidl-native.md)
and the source parsers. VTEX publishes a [Legacy Search API](https://developers.vtex.com/docs/api-reference/search-api),
but platform API documentation does not grant reuse of a merchant's catalog.
H Mart's [online/store pricing explanation](https://support.hmart.com/hc/en-us/articles/4408935803411-Why-is-there-a-price-difference-between-in-stores-and-online)
(updated March 8, 2023) says prices may differ; no shelf reclassification follows.

## Display, cache, retention and attribution

| Candidate / dated primary terms | Published statement relevant to this app | Unresolved public-pilot condition |
|---|---|---|
| [Wegmans terms](https://www.wegmans.com/terms), updated October 5, 2025, §§3/10 | Restrict commercial use, systematic downloading/storage and automated retrieval without express prior written consent; distinguish shopping modes and promotions. | Obtain terms covering this native comparison app and shared evidence/history, permitted cadence, attribution/brand use, cache TTL, deletion and historical retention. A 48-hour app freshness threshold is not permission to retain content for 48 hours. |
| [Walmart affiliate agreement](https://affiliates.walmart.com/terms), updated June 2026, §§1/3/8/13 | Enrollment is discretionary. The agreement prohibits affiliate price-tracking/alerting functionality; price information must be supplied by Walmart and kept accurate, and product updates are required within 24 hours of source changes. | Do not treat ordinary affiliate acceptance as approval for this app. Clarify an applicable OPD/comparison agreement, approved fields, required links/disclosures, refresh and historical-retention rights. These program terms are not a conclusion about every possible Walmart data arrangement. |
| [Target terms](https://www.target.com/c/terms-conditions/-/N-4sr7l), updated September 10, 2026, License & Access / Prohibited Uses | Personal noncommercial license; commercial content storage/use and systematic extraction are restricted. | Obtain an applicable agreement for public comparison, cache/history, exact price channels and attribution. Its approved-agent provisions do not supply Thrifty Market with a store-price feed agreement. |
| [H Mart Conditions of Use](https://support.hmart.com/hc/en-us/articles/4408061858579-Conditions-of-Use), updated March 8, 2023 | Content exploitation/publication is restricted; the described copying exception requires H Mart permission and sale-related use. | Confirm applicable current catalog terms and permission for third-party price display, online geography, cache TTL, retained history/deletion, attribution and quotas. No permission was obtained here. |
| [Lidl US terms hub](https://www.lidl.com/c/terms-conditions/s10092716) and [Lidl Plus terms](https://www.lidl.com/c/lidl-plus-terms-conditions/s10093660), Plus updated June 17, 2026 | The hub links program terms. Plus is for personal/noncommercial use. | **Scope distinction:** Plus membership terms are not a public regional-catalog API license. No sufficient public catalog display/cache/history grant or attribution schedule was established in this bounded review. Obtain one; do not assume silence grants reuse. |
| [SerpApi terms](https://serpapi.com/legal), updated August 27, 2026, §§2/12/13 | Restrict unauthorized use/service resale; Legal Shield addresses collection, not downstream use. The terms exclude Free/Starter/Developer from that shield. | Confirm that this app's public redistribution/comparison and shared cache/history are permitted, who authorizes retailer content, cache/retention/deletion limits and attribution. Do not expose a raw resale API or infer rights from marketing badges. |

No reviewed source establishes an approved **app-specific attribution or
retention policy** for this pilot. Proposed UX would show retailer, physical
store or online-reference scope, source URL, observation/retrieval times and
conditions; that is evidence transparency, not a substitute for permission or
an agreed trademark/license notice. Provider-side retention also matters: free
SerpApi calls must not be assumed to have enterprise ZeroTrace protection.

## Walmart and Target: candidates and the missing five-product gate

### Official and affiliate routes

Walmart's [OPD introduction](https://www.walmart.io/docs/opd/stores/grocery-introduction)
publishes localized pricing/availability for third-party applications, with
Impact enrollment, an access request and private-partnership assessment. It
does not promise automatic acceptance, a free price quota or permission for this
particular comparison/history product. The user confirmed no approved OPD access
on October 16. The current store-locator documentation rendered only an app shell
in this review; the OAuth/locator details recorded in PR35 remain prior evidence,
not a successfully revalidated protected call. No OPD call was attempted.

[Target Partners](https://partners.target.com/) / [its FAQ](https://partners.target.com/faqs)
rendered JavaScript-only shells in this review. No accessible app-specific local
price-feed agreement, field contract, rate limit or cache/retention grant was
established. This is an **unresolved lead**, not proof that Target has no partner
option. Retailer seller-management APIs and affiliate links are not replacements
for a verified local consumer-price contract.

### SerpApi: strongest documented technical proof-of-concept candidate, unapproved

This ranking is an inference from the published interfaces and bounded free
allowance, not measured reliability or a public-use recommendation. Both engines
require a private API key. No account/key is available, so **0/5 accepted local
products per retailer** were obtained here. Published examples are not Chantilly
fixtures and must not be replayed as live observations.

| Gate | Walmart Product documentation | Target Search documentation |
|---|---|---|
| Request / response location | `engine=walmart_product`, `product_id`, `store_id=5969`; require response `search_information.location.store_id`, not request echo | `engine=target`, `q`, `store_id=1827`; require `search_information.store_id/store_name`; documented default 1771 is not Chantilly |
| Exact product/package | `us_item_id`, product ID, UPC, title/specifications; actual size/count must be unambiguous | Exact child `tcin`, parent variant ID, title. Package/UPC completeness is not guaranteed by this search schema; unresolved size remains unknown |
| Seller and channel | Inspect `seller_id/name`, selected offer, `pickup_option`, shipping and `offer_type` together; first-party and pickup price must be bound | Schema does not establish first-party seller for every result. Per-channel fulfillment exists, but price notes can say online purchase and prices may be ranges; neither store stock nor the lowest range value proves a shelf/pickup price |
| Stock/terms/time | Generic `in_stock` alone is insufficient. Preserve price/currency, offer terms and provider capture metadata; provider creation time is not retailer effective time | Keep each fulfillment state, deals/price notes and provider capture time. Unknown retailer effective time remains unknown |

Primary interface references: [Walmart Product API](https://serpapi.com/walmart-product-api),
[Walmart Search API](https://serpapi.com/walmart-search-api),
[Target Search API](https://serpapi.com/target-search-api), all read October 21.
The Walmart example includes a Marketplace seller; a retailer domain cannot
establish first-party status. The Target example's online-purchase note must
survive ingestion even when `in_store` or `pickup` says in stock. The supported
schema is a starting point, not a guarantee every required field is returned.

Reproducible future checks, **after access and permitted-use gates are resolved**:

1. Confirm the owner's Walmart 5969 context and authorized locator/store response;
   require Target 1827 in actual provider results. Disable defaults/fallbacks.
2. Independently discover and select milk, eggs, chicken breast, rice and bananas
   at each retailer. Historical Walmart item IDs 10450114/124080159/27935840/
   10315395/44390948 are discovery leads only; reconfirm exact package and offer.
   Target TCINs for these five have not been established; do not invent them.
3. Obtain five minimal real responses per retailer. Record UTC capture time,
   retailer/source URL, selected store, exact child ID/barcode, seller, price type,
   currency/decimal amount, size/count/billing basis, channel stock, conditions
   and validity/effective times if supplied. Preserve missing values explicitly.
4. Reject wrong-store, Marketplace, shipping-only, ranged/ambiguous or unbound
   prices. Unknown stock/size/terms cannot win. Preserve source dates across
   cache hits; never retime an example, cache response or failed request as fresh.
5. Record provider-reported usage before/after, retries/additional details and
   source failures. Sanitize credentials/query keys from fixtures and logs; then
   build offline extraction and exclusion tests before proposing enablement.

No executable request template containing an API key, protected request or
fabricated product-price fixture is committed. The machine-readable research
record stores only decisions, documented quotas and **unmeasured estimates**.

## Quotas, credit units and cost estimates

### Published provider limits

[SerpApi pricing](https://serpapi.com/pricing), read October 21: Free **250 successful
searches/month**, **50/hour**; Starter **$25/month / 1,000**; Developer
**$75/month / 5,000**; Production **$150/month / 15,000**. Its FAQ counts a
successful empty result as one search regardless of result count; cached/error/
failed searches do not count. A successful result our app rejects can still cost
a credit. The product/search docs describe a one-hour exact-parameter provider
cache. Neither cached-result delivery nor a provider timestamp renews source
evidence. These are one account's pooled allowances, not a separate free quota
per retailer. Paid prices here exclude taxes and hosting; no purchase is proposed.

Generic extraction alternatives are less proven for this product:

| Candidate | Published free / next paid threshold | Decision / estimated unit conversion |
|---|---|---|
| [ZenRows pricing](https://www.zenrows.com/pricing), page modified October 13; [official SDK](https://github.com/ZenRows/zenrows-python-sdk) | 5,000 credits/month; entry Build 45,000 at **$19/month**. The displayed **$16** is an annual monthly equivalent, not month-to-month. | Standard1, JS5, premium10, JS+premium25 credits/request. Thus 5,000 buys at most200 successful25-credit pages. Actual mode/count for these stores is **unmeasured**; this transport does not establish store/offer fields or public reuse rights. Not selected; no challenge/proxy workflow was tested. |
| [Apify pricing](https://apify.com/pricing), read October 21 | $5/month free usage; Starter$19/month including$19 usage, then usage charges; free compute$0.20/CU | No fixed free product count: Actor event/usage fees, proxy bandwidth and storage vary. No particular US local-price Actor was validated. For any future candidate, bill total event+compute+proxy+storage costs, not just returned rows. Public reuse rights remain unresolved. |

### Explicit assumptions and arithmetic

Let **U** be unique exact product/store/channel contexts across users, **F** the
refresh cycles in the period, **A** billable calls needed per context, and **D**
additional discovery/detail calls. Estimated provider searches = `U × F × A + D`.
The table uses **30 days**, `A=1`, `D=0`, all operations successful and uncached
at the provider. It is an optimistic planning baseline, **not measured usage**.
One Target search need not resolve an exact offer; extra calls can increase A/D.

| Catalog interpretation | U | Daily refresh / 30 days | Four refresh cycles / month |
|---|---:|---:|---:|
| 30 offers total across any stores | 30 | 900 | 120 |
| 50 offers total across any stores | 50 | 1,500 | 200 |
| 30 products at both Walmart and Target | 60 | 1,800 | 240 |
| 50 products at both Walmart and Target | 100 | 3,000 | 400 |
| 30 products at all five stores | 150 | 4,500 | 600 |
| 50 products at all five stores | 250 | 7,500 | 1,000 |

All-five rows describe total context operations, **not** SerpApi coverage of all
five retailers. Current direct exact clients use one request per Wegmans/H Mart
identity and two per Lidl identity, before discovery. With the unverified
Walmart/Target minimum of one each, all-five daily coverage would require at
least **5,400–9,000 HTTP operations / 30 days**. This is a code/documentation
estimate; direct-site quotas, success rates and public permissions are unknown.

At 25 credits/page, the Walmart+Target daily rows would need 45,000–75,000 ZenRows
credits before overhead, so the free allowance does not establish that workload.
Apify's actual unit spend cannot be estimated responsibly without a specific
Actor/run measurement. OPD quotas/fees remain approval/contract questions.

**Decision/inference:** a free SerpApi account could support a tightly bounded
candidate proof, not the requested daily 30–50-product/two-retailer service. The
daily two-retailer baseline exceeds Starter and fits Developer only before
unmeasured overhead. Four weekly cycles for 30 products at both stores would use
240, leaving 10 free searches; a fifth cycle alone exceeds 250. At most 8 distinct
contexts/day use 240/month before discovery. These are possible scope alternatives,
not approved reductions. Even zero-priced testing still needs account permission,
acceptable data use and a passing evidence gate. A 100-operation refresh also
exceeds the free 50/hour throughput and needs pacing.

Shared caching saves repeated requests for the **same** U; 25–50 people at identical
stores/products need not multiply U. Different stores, channels, products or
uncached queries do. A 31-day month, cold searches, variants, pagination and
failures require additional accounting. The prototype's 50/day and 250/month limits
count logical adapter attempts; they neither supply these larger catalogs nor
measure actual provider credits. Its search and price caches are separate, so
discovery can repeat exact checks. No scheduler or larger budget is enabled here.

## Concrete owner-input gates

1. **Walmart access:** owner decides whether to request private OPD/Impact access
   and an agreement expressly covering comparison/history. No existing approval
   or credentials were available; do not paste secrets into chat/issues.
2. **Provider proof:** owner may authorize creating an account and bounded free
   candidate run only after acceptable use/display/cache/history terms are
   resolved. We created none. Store keys in server secrets, never the iPhone.
3. **All five source agreements:** establish field/scope rights, attribution,
   permitted requests, cache TTL and historical retention/deletion. Ask whether
   derived unit prices/comparison ranking, price-drop history and sharing among
   beta users are covered. Provider collection assurances alone are insufficient.
4. **Evidence completeness:** obtain five accepted Walmart and Target offers with
   first-party seller and exact-channel price; otherwise report unavailable.
   H Mart online-only and Lidl unknown-stock exclusions remain required.
5. **Scope/budget:** choose daily 30–50 products at both requested stores with a
   verified usage allowance, or explicitly choose a smaller/slower pilot. No
   vendor payment or removal of Walmart/Target is authorized by this research.

Until these inputs and validations exist, retain all five public-source decisions
as disabled. Issue 41 may close for its documented research outcome; adapters,
source-access issues and public-pilot readiness remain separate.

## Validation performed

Read primary pages linked above and dated existing PR35/36/native evidence;
checked the source decision record and arithmetic independently using Python
integer/Decimal calculations. ZenRows' HTML JSON-LD distinguished annual and
monthly pricing when the web renderer could not read its Markdown representation.
No third-party pricing directory or example response was treated as local evidence.
The structured [decision and budget record](public-pilot/source-decision.json)
contains no retailer price fixtures, keys, private responses or user data.
Documentation/JSON only: no runtime changes, so no backend/Swift/Xcode tests or
live retailer tests were necessary. The staged diff passed `git diff --cached --check`; JSON, local links and all
calculation scenarios passed validation. Future source changes require new checks
and dated evidence.
