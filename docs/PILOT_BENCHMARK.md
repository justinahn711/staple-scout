# Chantilly pilot benchmark: version 1

Issue [#42](https://github.com/justinahn711/staple-scout/issues/42), under
[roadmap #40](https://github.com/justinahn711/staple-scout/issues/40).

This is a **provisional test catalog**, not the owner's shopping list, approved
substitution preferences or verified retailer inventory. Its 40 rows provide a
fixed denominator before [validation #50](https://github.com/justinahn711/staple-scout/issues/50).
No live retailer requests, public-source approvals, shelf checks or pilot results
were produced by this issue. **All live entry gates remain unmeasured.**

The canonical structured definition is
[`pilot-catalog.json`](../iOS/Packages/StapleScoutKit/Tests/StapleScoutKitTests/Fixtures/pilot/pilot-catalog.json).
The separate [`pilot-comparison-cases.json`](../iOS/Packages/StapleScoutKit/Tests/StapleScoutKitTests/Fixtures/pilot/pilot-comparison-cases.json)
contains invented offline prices, product IDs and barcodes under
`https://fixtures.invalid/`. They are explicitly synthetic; they are never retailer
requests, current grocery prices, application sample data or database seeds.
Only the test bundle loads these files. The default application library stays empty.

## Frozen catalog and substitution rules

`chantilly-40-v1` has stable IDs P001–P040. Weight compares in oz, volume in fl oz,
and count in each. Exact metric/imperial conversion is permitted only within the
same dimension. Package quantities below are **per inner pack**; total purchase
quantity is quantity × pack count, and an offer price must cover the entire
purchase package. Gross shipping weight and drained weights are not interchangeable
with net package contents. The full required form/specification is recorded for
every row in the JSON.

For this benchmark only, a name brand or store brand may be a candidate after an
explicit review of that row's required form, attributes and package. A barcode,
similar name, retailer listing rename or store-brand label never grants approval.
Every new match begins pending; rejected matches remain excluded. Fixed package
sizes and pack counts must match the target after exact unit conversion; a new
size is a new reviewed package, not an automatic substitute. This restrictive
benchmark choice is not an inferred preference for any shopper. Personal users
keep their own requirements and approvals on device.

Variable/estimated rows carry a nominal weight reference and desired amount,
**not an exact package weight or purchase cost**. They stay in the denominator and
are currently excluded from exact unit-price/outlay winners by the existing engine.
This intentionally makes unsupported fresh-food coverage visible.

| ID | Provisional staple | Basis | Target package | Quantity kind |
|---|---|---|---|---|
| P001 | Whole milk | fl_oz | 128 fl_oz | fixed |
| P002 | 2% milk | fl_oz | 128 fl_oz | fixed |
| P003 | Large eggs | each | 12 each | fixed |
| P004 | Salted butter | oz | 16 oz | fixed |
| P005 | Plain Greek yogurt | oz | 32 oz | fixed |
| P006 | Cheddar block | oz | 8 oz | fixed |
| P007 | Shredded mozzarella | oz | 8 oz | fixed |
| P008 | White sandwich bread | oz | 20 oz | fixed |
| P009 | Flour tortillas | each | 10 each | fixed |
| P010 | Long-grain white rice | oz | 32 oz | fixed |
| P011 | Long-grain brown rice | oz | 32 oz | fixed |
| P012 | Dry spaghetti | oz | 16 oz | fixed |
| P013 | Old-fashioned oats | oz | 18 oz | fixed |
| P014 | All-purpose flour | oz | 80 oz | fixed |
| P015 | Granulated sugar | oz | 64 oz | fixed |
| P016 | Canola oil | fl_oz | 48 fl_oz | fixed |
| P017 | Extra-virgin olive oil | fl_oz | 500 ml | fixed |
| P018 | Canned black beans | oz | 15 oz | fixed |
| P019 | Canned chickpeas | oz | 15 oz | fixed |
| P020 | Canned diced tomatoes | oz | 14.5 oz | fixed |
| P021 | Creamy peanut butter | oz | 16 oz | fixed |
| P022 | Strawberry preserves | oz | 18 oz | fixed |
| P023 | Ground coffee | oz | 12 oz | fixed |
| P024 | Black tea bags | each | 20 each | fixed |
| P025 | Frozen broccoli florets | oz | 12 oz | fixed |
| P026 | Frozen green peas | oz | 12 oz | fixed |
| P027 | Frozen blueberries | oz | 12 oz | fixed |
| P028 | Firm tofu | oz | 14 oz | fixed |
| P029 | Soft tofu | oz | 16 oz | fixed |
| P030 | Instant ramen multipack | oz | 6 × 3 oz | fixed |
| P031 | Brown-rice rice paper | oz | 200 g | fixed |
| P032 | Fresh chicken breast | oz | 1 lb nominal; desire 2 lb | variable |
| P033 | 90% lean ground beef | oz | 16 oz | fixed |
| P034 | Frozen sliced pork belly | oz | 16 oz | fixed |
| P035 | Loose bananas | oz | 1 lb nominal; desire 2 lb | variable |
| P036 | Bagged Gala apples | oz | 3 lb | fixed |
| P037 | Bagged russet potatoes | oz | 5 lb | fixed |
| P038 | Loose yellow onions | oz | 1 lb nominal; desire 2 lb | estimated |
| P039 | Bagged carrots | oz | 16 oz | fixed |
| P040 | Frozen pork-and-vegetable dumplings | oz | 24 oz | fixed |

These specifications are deliberately frozen for the first run. If personal staples
or unavailable package sizes require changes, publish a new catalog version before
measuring it. Keep the previous results; do not remove difficult rows after seeing
prices or silently change the denominator.

### Historical product identity references

Three references link to existing committed extraction fixtures, not new live
verification: Wegmans whole milk `94427` with barcode string `00077890944271`,
Wegmans variable-weight chicken `57084` with barcode string `02002867000009`, and
H Mart brown-rice rice paper product/SKU `332:332`. Their source files and status
are included in the catalog. Barcode strings retain leading zeros. The H Mart
fixture's test EAN is not asserted as a verified retail barcode, so that catalog
reference has a null barcode. No retailer IDs or barcodes were invented for the
other 37 rows. Reconfirm package/identity, seller, availability and context during
validation; no historical fixture price, stock flag or date becomes current evidence.

## Requested contexts versus validated evidence

| Retailer | Requested context | Current personal native support | Public-pilot limitation |
|---|---|---|---|
| Wegmans | Chantilly `133` | `in_store` | Public-use access still unapproved; no pickup adapter |
| Walmart | Tentative Chantilly `5969` | None | Confirm the physical store, response location, Walmart seller and local fulfillment; access unresolved |
| Target | Proposed Chantilly `1827` | None | Confirm the physical store, response location and price type; access unresolved |
| Lidl | Chantilly `US01112`, price region `US1112` | Regional `in_store` offers | Unknown local stock excludes winners; no pickup adapter; public-use access unapproved |
| H Mart | No physical store code; national `online` | National online reference | Never Centreville shelf/pickup evidence; public-use access unapproved |

The matrix is a set of requested measurement contexts, not an assertion that every
store supports both channels. A configured ID or requested location parameter is
insufficient proof of the returned store. Match response/provider evidence to the
verified physical store and channel. H Mart shelf spot checks cannot establish
local pricing for the entire national catalog. Lidl regional offer prices do not
establish stock. [Source decision #41](https://github.com/justinahn711/staple-scout/issues/41)
and the existing source gates must establish usable access before any source is
enabled for testers, including Wegmans, H Mart and Lidl.

## Fixed coverage accounting

Measure `in_store` and `pickup` separately; never combine channels to manufacture a
cheapest-store comparison. Before the live run, declare the **one primary pilot
comparison channel** and freeze its source/context/version list. The other mode
still receives its own coverage report; passing both modes is not a requirement.
Unsupported store/channel combinations remain gaps rather than silently shrinking
one mode's denominator. Do not turn online-only provider data into a local cell.

- Each mode: 40 staples × 4 requested local retailers = **160 local cells**.
- Both requested modes: **320 cells**, reported as two separate 160-cell matrices.
- H Mart online: **40 additional reference cells**, reported separately and never
  included in local coverage numerators or local winner eligibility.
- Per retailer/mode: **40 cells**, including no match, missing price, unsupported,
  blocked, failed, stale, unknown stock, unavailable and conditional results.
- Joint comparison coverage: number of the **40 staples** with at least two
  eligible offers from distinct validated physical stores in the same mode.
  Two SKUs, packages, providers or offers from one physical store count once.

For each local cell record discovery result, exact-identity result, review state,
evidence validity, winner eligibility and a primary gap reason. Retain all
applicable exclusion reasons. Do not conflate catalog discovery with a usable
recommendation. Track four separate rates: discovery/40; exact identity/40;
current eligible local evidence/40; and jointly comparable staples/40. Price
accuracy is measured only where independent reference evidence exists; report its
own audited count and denominator instead of labeling unverified rows accurate.
Deduplicate multiple offers before counting one store–staple cell.

The offline test constructs 32 eligible Walmart and 32 eligible Target cells with
28 shared staples, while Wegmans/Lidl and unsupported rows remain gaps. This is
**64/160 = 40% local cell coverage**, not 64/64 or 100%. It demonstrates denominator
and engine behavior using synthetic manual evidence; it does not claim either
retailer has working source access. A missing result never means a zero price.

## Pilot entry thresholds, declared before validation

These are proposed measurable defaults for the requested scope, not measured
outcomes or permission to activate a beta. Record any owner-approved threshold or
scope change before rerunning the benchmark, with its reason and catalog version.

| Gate in the predeclared primary channel | Required result | Current result |
|---|---|---|
| Source access and provenance | Public-use display/cache/retention permission; validated exact store/channel/seller; Walmart **and** Target included | Not run; source access unresolved |
| Comparable local sources | At least 2 distinct validated physical stores, with eligible evidence in the same channel | Not measured |
| Mandatory-retailer coverage | Walmart ≥32/40 and Target ≥32/40 current eligible staple cells (80% each) | Not measured |
| Overall local coverage | ≥64/160 eligible cells (40%); disabled stores remain in the denominator | Not measured |
| Useful shared coverage | ≥28/40 staples (70%) with 2 distinct eligible local stores | Not measured |
| Critical evidence accuracy | 100% of audited records correct for identity/package, seller, location/channel, currency, time/offer validity, conditions and stock handling; zero ineligible winners | Not measured |
| Package-price accuracy | 100% of audited amounts equal the same-context independent source reference; unresolved mismatch is a no-go | Not measured |
| Unit/outlay arithmetic | Exact Decimal conversion/whole-package totals; the audit export rounds unit prices to 6 decimal places with error ≤0.000001 per basis unit; assess app display rounding separately | Offline fixture checks only |
| Independent real checks | ≥10 distinct audited staples for **each** mandatory retailer; choose before fetching, including a multipack, count item and a variable/estimated case; never cherry-pick cheapest successes | Not run |
| Freshness/repeatability | 2 complete runs on separate UTC days; score each independently; every winner observed <48h ago and within its offer window and any stricter source TTL | Not run |

The spot-check list may include an excluded item: recording its honest exclusion
is a successful evidence check, but it is still a coverage gap. An unavailable
or online-only Walmart/Target outcome is not a passed local gate. Do not quietly
drop either requested retailer to start a narrower pilot; record the blocker and
obtain an explicit scope decision. Budget, authentication, operations and beta
readiness remain separate roadmap gates; these catalog thresholds do not replace them.

## Evidence accuracy rubric

A dated audit row must contain the catalog ID and version; a stable candidate
identity and reviewed match; retailer product/SKU ID; barcode **string** or explicit
unknown; package/form, net quantity/unit, pack count and quantity-kind; retailer and
seller; physical-store identity and response evidence; fulfillment/channel and
price type; Decimal USD package amount (or explicit unknown); source URL/provider
record; source observation/effective time, retrieval time, and benchmark cutoff;
availability; conditions; offer start and exclusive end when supplied; attribution
and public-source decision reference. Record evidence retention limits before
capturing material. Keep secrets and private retailer/account responses out of Git.

- **Identity/package:** compare exact product, form, pack count and net amount.
  Same barcode is identity evidence, not permission to substitute or proof of
  equal package size at another store. Do not strip leading zeros or infer a
  barcode from a name. Unknown or ambiguous identity is a gap until reviewed.
- **Price/seller/channel:** compare the package total and seller in the same
  selected store and fulfillment mode. Do not compare a unit-price label to a
  package total; exclude shipping-only, Marketplace, loyalty/coupon/must-buy
  conditions and unidentified eligibility from local winners. Compare pretax
  base price consistently; retain required deposits/fees and mark unsupported
  compulsory charges as conditions, rather than subtracting them silently.
- **Time/terms/stock:** retain original source and retrieval times. Serving from
  cache is not a new observation. Missing or invented source time, future time,
  stale observations, expired/not-started offers, unknown stock and unavailable
  stock cannot be counted as eligible. Label source limitations explicitly.
- **Arithmetic:** independently calculate net quantity × pack count, unit-price
  conversion and ceiling(desired/whole package) with decimal arithmetic. Report
  unit-price winner separately from purchase-cost winner and excess amount.
  Never convert across weight, volume and count. Variable/estimated quantities
  have no exact package outlay; unknown values remain unknown.

Audit every returned candidate's metadata automatically against this rubric and
retain the audited denominator. Independently verify at least the preselected 10
items per mandatory source by its supported source evidence and, when claiming
local shelf accuracy, a same-store shelf check within 24 hours of the source
observation. For pickup, use the same store, seller and pickup fulfillment view.
If the independent reference lacks stock, source time, package or local context,
record which fields cannot be confirmed; do not call the record 100% accurate.
Any critical mismatch blocks entry until investigated and the complete affected
run is rescored. Exact source/observation semantics are chosen in #41; this issue
does not establish them from a store homepage or receipt-free assumption.

## Synthetic fixture coverage and boundaries

The 24 cases exercise the existing `ComparisonEngine`, not a parallel ranking
implementation: valid fixed weight/volume/count; metric conversion; multipack
whole-package cost; wrong planned store and previous location; wrong channel;
missing price; unknown/unavailable stock; membership/must-buy conditions;
exclusive-end expiry; not-started/future/stale evidence; estimated/variable
weight; online H Mart; unknown-stock Lidl; pending and rejected matches.

The wrong-store/location tests prove filtering of already modeled evidence.
They do not replace adapter/transport tests that reject a mismatched **response**
before ingestion. Existing `RetailClientTests`, `SharedMarketClientTests` and
`LidlClientTests` retain responsibility for source parsing and context validation.
The source decision, provider-credit, cache, authentication and public deployment
issues remain independent. No live price, source approval or performance conclusion
can be inferred from a passing synthetic test.

## Later bounded live validation protocol

1. Finish #41's source-access decision and each enabled adapter's five-product
   gate. Confirm response locations, supported channel, public-use conditions and
   exact quota units; prepare disabled-source and evidence-retention policy first.
2. In #50, record the immutable catalog version, primary channel, independent
   spot-check IDs, source/adapter versions, verified locations, UTC cutoff/window
   and approved request/credit cap. Reserve for search expansion and candidate
   validation before fetching; if the cap is insufficient, stop and record the
   unresolved cells. Do not poll, scrape account pages or bypass challenges.
3. Run explicit, bounded discovery only for these staples. Review every candidate
   against its row's specification; do not auto-approve any live substitute.
   Use temporary benchmark storage, not the owner's app library. Record all
   missing/blocked/unknown outcomes as gaps in the full matrices.
4. Perform the independent source/shelf/pickup spot checks described above.
   Preserve dated sanitized field-level traceability within the approved retention
   policy. Owner observations must identify the exact store, product, package,
   channel, date/time and offer restrictions; ambiguous photos or missing fields
   stay unresolved. No retailer login is automated.
5. Repeat on a second UTC day with one scheduled refresh at most per day;
   preserve failures and original timestamps. Calculate each run's accuracy,
   coverage and gaps independently; do not union different-day prices to pass.
6. Publish #50's observed results, request/credit costs, discrepancies and go/no-go
   record. All required unknowns remain blockers; #51 separately handles beta
   preparation/activation. Nothing in this issue starts a scheduler or sends
   messages, purchases a service or deploys the server.

Owner inputs needed **later**, not to finish this offline benchmark: actual
personal staples and substitute preferences if replacing this provisional list;
source/developer approvals or vendor clarification if #41 needs them; same-store
shelf observations where public shelf accuracy cannot otherwise be established;
and budget/hosting/device/beta activation decisions at their roadmap gates.
Do not request credentials, session cookies or retailer account access in an issue.

## Verification

`PilotBenchmarkTests` validates catalog uniqueness, dimensions, pack kinds, complete
rules, historical identity traceability, all 24 synthetic outcomes using the
shipping engine, and the fixed 160-cell coverage example. Run it explicitly with:

```sh
swift test --package-path iOS/Packages/StapleScoutKit --filter PilotBenchmarkTests
```

Run the full Swift package suite before review. This change adds documentation
and test resources/tests only; it changes no app UI, source client, backend,
Xcode configuration, production database or app startup behavior.
