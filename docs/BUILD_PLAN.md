# Build plan

For actionable GitHub tasks and the recommended execution order, see the
[work queue](WORK_QUEUE.md). This document describes product milestones; the
queue sequences foundation, source research, adapters, and interface work.

## Product goal

For groceries needed this week, find the cheapest acceptable product among the
stores the user already visits, with enough evidence to trust the comparison.
Start with 10–15 user-selected staples, then grow to 30–50. Fetch at most daily.

Retailers: Wegmans, Walmart, Target, H Mart, Lidl. Costco has been removed.
Default substitution policy: approve matches individually until the user chooses
otherwise. A store brand is neither automatically approved nor rejected.

## M0 — Local comparison foundation (initial delivery)

- Persistent SQLite database and Python API.
- Create/edit/remove staples, including acceptable-substitute notes and a needed flag.
- Record products and dated prices without inventing retailer data.
- Normalize multipacks and compatible weight, volume, or count units.
- Exclude unapproved, stale, unavailable, conditional, or non-shelf observations
  from the shelf-price winner, while explaining exclusions.
- Filter comparisons to stores the user plans to visit.
- Tests for normalization, eligibility, history, validation, and persistence.
- Private GitHub repository, locked dependencies, and continuous integration.

Acceptance: two manually entered eligible observations can be compared correctly;
an outdated or incompatible cheaper observation cannot produce a false winner.
The initial UI is the generated API explorer, not the shopper-facing app.

## M1 — Source validation and first two live adapters

Priority candidates: Wegmans Chantilly and Walmart Chantilly. Do a bounded
feasibility check before committing to an endpoint or promising daily coverage.

For five representative products per candidate source, establish:

- Endpoint/access requirements and permitted supported access path.
- Retailer product ID, barcode if available, size, pack count, and form.
- Location actually used by the response, seller, and shopping channel.
- Which field is regular price, offer price, and unit price.
- Availability semantics, promotion conditions, and timestamp provenance.
- Behavior for missing, unavailable, or malformed products.

Walmart must exclude third-party sellers and shipping-only offers. Wegmans must
preserve in-store versus ordering mode. A source that yields pickup-only prices
can power a separate pickup comparison; it cannot silently enter shelf rankings.

Store a sanitized response fixture and field mapping for each tested source.
Use httpx first, Playwright only if required. Never add automated account logins
or bypass challenges. If a source cannot reliably expose the necessary context,
keep it disconnected and proceed with another validated source.

Acceptance: five real products per connected store produce traceable normalized
observations; tests replay fixtures; failures preserve the previous observation
and its timestamp. No credentials or private payloads enter git.

## M2 — Shopper interface and repeatable matching

Phone-friendly web app; platform remains a proposed default pending confirmation.

- My staples: add/edit staples and approve product variants.
- Compare: package price, normalized price, location, channel, date, and conditions.
- This week's list: filter to needed staples and selected stores, group winners
  by store, keep missing comparisons visible.
- Source status: distinguish no match, no price, failed refresh, stale price,
  and source not connected. Do not collapse these into "out of stock".
- Product identity: store IDs/barcodes and package variants.
- Separate approved staple-to-product matches from individual observations.
- On changed staple rules, require reapproval of affected product matches.
- Add a pickup-only comparison mode before using online pickup offers as winners.

Acceptance: add a staple, approve a candidate, and identify a valid purchase from
a phone-size screen without reading API field names. Keyboard use, labels,
loading states, errors, empty states, and narrow-screen layouts work.

## M3 — More stores and daily refresh

Add Target, then H Mart and Lidl according to feasibility and staple coverage.
Resolve Lidl's exact location. Treat H Mart online catalog prices as online;
shelf spot checks validate only those products at that place and time.

Add per-source timeouts, modest retries, backoff, daily caching, refresh logs,
and a Mac scheduled job. Prevent overlapping runs and duplicate observations.
Use observed price time separately from retrieval attempt time. A sleeping Mac
cannot guarantee exact-time refreshes; show the last successful refresh.

Acceptance: one unavailable retailer does not stop other stores; repeated runs
do not duplicate observations; the comparison view accurately reflects freshness.

## M4 — Weekly usefulness

- Weekly report of lowest eligible unit prices, observed price drops, and gaps.
- Desired quantities and whole-package purchase cost, including excess quantity.
- Selected-store grouping before any travel optimization.
- Alerts only after a trustworthy baseline and channel-specific comparisons exist.

"Deal" means a supported active offer or a decrease against this app's observed
history. Do not invent a historical reference price or claim savings without a
comparable baseline. Membership offers require explicit eligibility and terms.

## Deferred

Costco, receipts, LLM matching, automated substitute approval, public accounts,
checkout, automated login, travel optimization, complex coupon stacking,
gift-card reward optimization, and multi-household synchronization.

## Decisions still needed

- The user's initial 10–15 staples, brands, package preferences and constraints.
- Whether store brands can be eligible by default for any particular staple.
- Exact Lidl location and confirmation of Walmart Chantilly #5969.
- Web app versus native iPhone; weekly report format.
- Whether local pickup is an acceptable purchase channel as well as shelf shopping.
- Whether the project stays on the Mac or later moves to a private hosted service.

These do not block the local data and comparison foundation. They do affect the
first real catalog, ranking modes, interface and deployment choices.
