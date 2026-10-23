# Provider reservations for the local shared-price prototype

Issue #44 adds durable accounting at the potential provider HTTP request boundary.
The executable remains localhost-only, with all provider caps **zero** and all
sources disabled. There is no provider key, subscription, live adapter, activation
flag or nonzero-cap environment setting. Positive policies exist for offline
fixtures. This does not establish public retailer reuse permission or a usable
Walmart/Target feed. Personal native retailer clients are separate.

## Published policy and conservative accounting

SerpApi is the unapproved technical candidate considered by the source research.
Its [pricing page](https://serpapi.com/pricing), checked October 22, 2026, advertises
250 monthly searches and 50/hour on the free plan. It counts successful searches
once regardless of result count, including empty responses; cached/errored/failed
searches do not use searches. Its FAQ describes renewal dates and billing-cycle
resets, so a UTC calendar month is not a verified provider account cycle.

The implementation makes a deliberately conservative inference: reserve one local
unit for every possible HTTP operation, without inferring a refund from status,
provider cache metadata or application rejection. A successful response rejected
for wrong location/product/price evidence can still represent provider work.
Provider-reported billing is **unknown**, not zero. No provider account was accessed
and actual usage/credits remain unmeasured. A later integration must verify its
agreement, account cycle, credential transport, billing rules and usage reporting.

| Operation or outcome | Local accounting |
|---|---|
| Initial search or product lookup | One durable admission hold before the cache leader claims its logical attempt; first HTTP send uses that hold |
| Each additional page, candidate validation or detail lookup | One new reservation before each send |
| Explicit adapter retry | One new reservation; no automatic retries |
| Empty result, HTTP 2xx, app-rejected evidence, provider-cached response | Retain the reservation; 2xx increments a completed upper bound, not confirmed billing |
| HTTP error, timeout, cancellation or ambiguous connection failure | Retain as uncertain; never refund |
| Admission succeeds but no HTTP occurs, including a later cache-claim conflict | Retain the initial hold as uncertain; deliberately conservative |
| Valid shared-cache hit or same-process coalesced follower | No provider reservation; authenticated request-abuse counters still apply |
| Client/provider admission denied | Roll back all miss/unit changes; do not claim or poison the shared cache key |

Search fanout is charged per call, not per logical search. For example, a search,
two candidate lookups, a second page and one explicit retry reserve five units.
No requests are hidden inside a provider SDK. Public source rights, source
freshness and provider accounting are separate requirements.

## Atomic limits and delayed work

`ProviderBudgetLedger` uses a separate SQLite database, WAL, full synchronous
writes, a five-second busy timeout and `BEGIN IMMEDIATE` transactions. Global
provider capacity, stable-client capacity, bounded miss admission and the first
unit are claimed together. Denial rolls back every bucket. Later fanout operations
repeat the reservation transaction before sending. Policy caps are fingerprinted
in the database: a second connection cannot silently raise limits. There is no
runtime policy migration or reset command.

| Envelope | Interpretation / maximum injectable policy |
|---|---|
| Provider hour | Rolling 3,600 seconds, at most 50 |
| Provider day | Additional rolling 24-hour bound, at most 250 |
| Provider month | Rolling 31-day envelope, at most 250; protects against an unknown monthly renewal boundary |
| Client day/month | UTC calendar periods, each at most 250; stable authenticated client identity, never a caller-supplied ID |
| Global miss day/month | Rolling 24 hours / 31 days, at most 50 / 250 |
| Client miss day/month | UTC periods, at most 50 / 250 |
| Concurrent misses/requests | Default 4 each, configurable only by fixture policy up to 8; one active miss per client |
| HTTP operations per miss | Default and maximum 8, across pages/details/retries |

Unresolved reserved/dispatched holds count against **every current unit window**,
regardless of their original age. Dispatch and first completion move the hold's
charge timestamp forward to the current effective time. This prevents a request
reserved before an hour/day/month boundary from sending later after its capacity
has been reused. Completion is idempotent. Pending work also retains its global
and client in-flight slots across standalone connections and restarts. The running
service's exclusive ownership proof is required before retiring interrupted work;
one process never clears a live owner's work.

The clock is sampled after the SQLite write lock is acquired and clamped to a
persisted last-seen time. Rolling time backwards, including after restart, cannot
reopen spent capacity. The operator's UTC clock remains a trusted input: a large
forward correction can expire completed history, so correct the host clock before
starting service. This prototype does not defend against an operator altering the
clock, ledger or executable.

A crash after reservation deliberately leaves capacity and pending slots held.
A crash after send but before completion cannot prove whether provider work was
charged. The [single-instance recovery boundary](SOURCE_POLICY_RECOVERY.md)
locks all three service databases before opening them. Only a new exclusive owner
may finalize orphaned reservations as uncertain, retime their charge to recovery
and release blocked work slots. This never refunds a unit, replays a request or
clears the cache's same-day attempt claim. Standalone ledger connections without
that proof still retain pending work. Do not delete/reset the ledger or its lock
files to recover capacity. Completed/uncertain history is pruned after 62 days on
subsequent miss admission; pending rows are never pruned. Caps bound reservations
and misses in that retention window; client identity rows have a lifetime maximum
of 50.

## Cache and transport boundary

`SharedPriceCache` registers the single-flight task before awaiting provider
admission, preventing actor reentrancy from admitting duplicate leaders. Only the
leader reserves. Hits and followers bypass admission. Admission precedes the
persistent cache claim, so twenty fresh queries from a quota-exhausted client do
not consume global logical attempts or deny an eligible client that same key.
Separate cache limits remain 50/day and 250/UTC-month logical attempts. A second
process can receive `attempted_today` while the first works; it does not coalesce
across processes. No fresh fallback or timestamp renewal is added.

The cache allows four distinct active keys and up to fifty followers per key.
Queries remain 2–100 characters with no controls, result pages at most five
candidates, cache storage at most 5,000 entries, and provider response bodies at
most 1 MB. The provider factory accepts only three typed engines at exactly
`https://serpapi.com/search.json`: Target search (`q`, store 1827), Walmart search
(`query`, store 5969), and Walmart product (`product_id`, store 5969). Pages are
bounded to 1–3. It rebuilds requests from bounded values rather than following
returned URLs; arbitrary URLs, headers, secrets and hosts cannot be supplied.
See the primary [Target search](https://serpapi.com/target-search-api),
[Walmart search](https://serpapi.com/walmart-search-api) and
[Walmart product](https://serpapi.com/walmart-product-api) contracts. Credentials
are intentionally not implemented; a future approved adapter needs a separate
review before any activation.

The production boundary pins AsyncHTTPClient 1.36.2, uses HTTP/1, disallows redirects,
disables connection-establishment retry/prewarming and tracing, and uses the
library's disabled default logger. It closes each connection and never configures
provider authentication. See the pinned [configuration source](https://github.com/swift-server/async-http-client/blob/1.36.2/Sources/AsyncHTTPClient/HTTPClient.swift)
and [async execution source](https://github.com/swift-server/async-http-client/blob/1.36.2/Sources/AsyncHTTPClient/AsyncAwait/HTTPClient%2Bexecute.swift).
The library's execute deadline ends at the response head, as its
[state machine](https://github.com/swift-server/async-http-client/blob/1.36.2/Sources/AsyncHTTPClient/AsyncAwait/Transaction%2BStateMachine.swift)
explains. A separate 15-second absolute task deadline covers both headers and body
collection, with cancellation of the losing task, in addition to connect/read idle
timeouts. Real loopback fixtures verify redirect, dropped connection and continuous
slow-body cases produce one physical request and one retained reservation.

The former `local-research` server adapter has been removed and that mode is
rejected at startup. It cannot provide an unmetered anonymous retailer path around
the gate. No live retailer/provider request is needed by the tests or runtime.

## Runtime and safe metrics

`THRIFTY_PROVIDER_DATABASE_PATH` defaults to `data/provider-budgets.sqlite` relative
to the launch directory. It must be distinct from both auth and price-cache DBs,
including canonical paths, symlink and hardlink aliases. The ledger accepts only
an empty DB or its own application ID/schema, and bootstrap is atomic. DB/WAL/SHM
files must be operator-owned regular files with mode `0600`; permissive files and
unrelated schemas are rejected. Existing SQLite files are checked with `lstat`,
without raw open/read/close operations that could invalidate SQLite locks. Auth
and session-admin commands are unchanged; see [CLIENT_SESSIONS.md](CLIENT_SESSIONS.md).

Authenticated `GET /v1/usage` takes no query/body and reports schema version 1,
`provider: "serpapi"`, `accounting: "conservative_local_reservations"`,
`sourceApproved: false`, `enabled: false` at runtime,
`providerReportedUnits: null`, and five aggregate windows. Each has `scope`, `cap`,
`reserved`, `attempted` (dispatched), `consumedUpperBound` (HTTP 2xx completions),
`uncertain` (all non-2xx-finalized or pending holds), `pending` (a subset of
uncertain), and `remaining`. These fields describe local conservative spending,
never verified billed credits. Global windows and only the authenticated client's
windows are returned; no client IDs, raw search terms, products, credentials or
upstream error text are stored in the ledger or metrics. No raw queries or
credential-bearing requests are logged by the transport/error middleware.

The existing error shape remains `{ "code": "...", "message": "..." }`:

| Status | Safe code |
|---|---|
| 429 | `provider_budget_exhausted`, `client_provider_limit`, `work_pending`, `operation_limit` |
| 503 | `provider_disabled`, `provider_storage_unavailable` |
| 400 | `invalid_request` |
| 502 | `source_unavailable` |

Existing auth/cache codes remain supported. No retry/fallback is triggered by
quota errors. Native enrollment/Keychain/typed errors are separate issue #48 work.
