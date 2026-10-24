# Source permission, single-owner recovery and refresh contract

Issue #45 extends the localhost shared service on the #44 provider ledger.
The executable still binds to `127.0.0.1`, rejects `local-research`, has no
provider credential or adapter, and starts with all five sources unapproved and
all provider caps zero. Nothing in this change activates a scheduler, account,
subscription, public endpoint or retailer request. Positive policies are injected
only into offline fixtures; there is no runtime approval/cap override.

## Source policy and evidence

`SourcePolicy` binds a provider to one retailer, exact store code and channel.
Fetch permission, public serving permission, attribution, reference limitation,
cache TTL, display TTL, maximum observation age and retention are separate
fields. Both permissions must be true and the exact context technically supported
before fetching **or serving an existing cache entry**. An injected upstream alone
does not grant permission. Source availability never derives from personal-app
capability copy.

The shared service's implemented context parser accepts Wegmans 133/in_store,
H Mart with no physical store/online, and Lidl US01112/in_store. This states
technical compatibility with existing evidence validation, not public access.
Walmart 5969/pickup is an intended context with no verified adapter. Target
1827/in_store is a requested channel placeholder whose price-channel binding is
unverified. Both have `technicallySupported: false`, `channelVerified: false` and
no enabled price context. No channel is inferred from online price fields.

Permission and the captured policy generation are checked before hits, admission,
fetch execution, after suspensions, before saving and before returning each
leader/follower. The HTTP layer checks again after awaiting the cache and before
serializing. Each provider scope checks before reservation and again after
reservation/dispatch suspensions immediately before each actual HTTP attempt,
including later pages, details and retries. A changed approval invalidates old
work even if its replacement has identical fields. Rejected or uncertain provider
work remains conservatively charged.

`SharedPriceCache.replacePolicy` is trusted operator/library configuration, not
an HTTP endpoint. It first installs a denied generation, then purges that exact
context's price/search payloads and raw keys, clears old status, and only then
installs the replacement. A purge failure leaves the current process denied;
paused work cannot publish. The executable always restarts with denied policies,
so restart cannot restore a withdrawn fixture approval. A future activation design
must define durable operator approval/revocation configuration rather than add an
environment toggle around the fixtures.

Usability is the intersection of the same UTC day, the existing strict 48-hour
observation ceiling, source observation-age limit, cache/display/retention TTLs
and the offer's start-inclusive/end-exclusive window. TTLs use original retrieval
and cache insertion times; serving never advances either. Every search candidate
is validated. Empty complete pages also expire by insertion TTL. Late previous-day
results cannot overwrite today's payload or today's source status. Partial pages
are returned explicitly once and never cached as a complete page; outages and
expired evidence cannot trigger an automatic same-day retry.

Product identity, source URL, currency, decimals, quantity, unknown availability,
conditions, exclusions and source offer dates survive unchanged. H Mart remains
an online reference with its exclusion. Lidl keeps unknown local stock, regional
exclusion and both validity dates. Policy can require an additional reference
exclusion; it cannot promote stock or remove source restrictions. H Mart URLs
accept exactly the public `fq=productId:…` member, without additional query fields.

## Persistence and retention limits

The private shared cache has application ID `1414354243`, schema version 4,
and atomic bootstrap/migration. Only an empty database, this schema, or the known
legacy version-1/version-3 cache schemas are accepted. An unrelated database is rejected
before enabling WAL or changing its tables. A failed bootstrap/migration rolls
back and can be reopened safely.

Legacy daily attempt identities become keyed HMAC tombstones inside the migration;
their daily claims and aggregate budgets remain consumed. Search cache identities
also use keyed lookups; complete search payloads contain validated public candidate
evidence without the request query or search message. The stable secret is stored
in the same private database, so this is minimization, **not anonymization** or
encryption. Missing or altered key metadata fails closed. Legacy cache payloads
are dropped during migration. See [retention and deletion](DATA_RETENTION.md) for
the field inventory, retained quota/lifetime tombstones, bounded maintenance and
backup/physical-erasure limits.

Evidence payloads and price/keyed-search lookup rows are removed when unapproved, when
their policy fingerprint changes, or when original retrieval/insertion retention
expires. Maintenance runs at startup and on cache requests, status requests and
explicit worker runs. This is lazy logical deletion, not secure erasure from WAL,
backups, an idle host or a stopped process at an exact wall-clock deadline. Do not
activate a source whose agreement requires stronger deletion guarantees without
implementing and verifying them. No historical price archive is added.

Maintenance/status scans hold at most 5,000 bounded keys and one at-most-1-MB
payload at a time, rather than materializing every payload. Existing per-entry,
result-count, entry-count, concurrency and follower bounds remain in force.

## One service process and recovery

`ServiceOwnership` acquires nonblocking, exclusive kernel `flock` locks for all
three canonical database paths **before** opening service SQLite connections.
Each has a separate owner-only regular `DATABASE.owner.lock` file. Locks have no
timeout, TTL, polling, PID guessing or lease-stealing path; lock files are never
unlinked or recreated to recover a process. A second service sharing even one
auth, cache or provider DB is rejected, including an alternate provider-path
topology. The local session-admin CLI may still perform its existing transactional
invitation/revocation operations; it cannot recover provider work.

Final-component symlinks, hardlinked databases/lock files, duplicate paths, and
collisions with another DB's `-wal`, `-shm` or `.owner.lock` are rejected. Physical
parent paths are resolved; device/inode identities are checked again before
recovery and during owned work. Each owner grants a one-use capability per DB,
so a second actor cannot reuse one live owner's proof to clear its pending work.
DB/WAL/SHM checks use `lstat`, without raw opening/closing an active SQLite file.
Database and lock files must be operator-owned with `0600` permissions.

Only a newly proven exclusive owner retires predecessor `reserved`/`dispatched`
reservations. They become `uncertain`, with their conservative charge timestamp
advanced to recovery time clamped to the ledger's persisted clock. This starts a
fresh full rolling hour/day/31-day charge; HTTP success/billing is not invented.
Active miss slots are then released. Completed/uncertain history is not refunded,
quotas are not reset, and cache daily tombstones are never cleared to retry work.
No provider request is replayed by recovery. Pending source status becomes failed.
Without ownership, library fixtures retain the previous fail-closed pending
behavior and cannot request recovery.

Normal shutdown closes admission, cancels cache tasks and drains them before
releasing ownership. The provider transport has a full 15-second head/body deadline
and no redirects/connection retries. Cache fetch adapters must be cancellation
cooperative and keep every network operation inside that bounded scope; arbitrary
injected closures are not forcibly terminable. If killed, kernel lock release
permits the next proven owner to do the same conservative recovery. Never delete
or reset databases or lock files to reclaim quota. This design supports a trusted
single-operator local filesystem, not distributed/network filesystems, an operator
rewriting live files, or multiple independently running service instances.

## Explicit daily runner

`KnownProductRefreshRunner` is an opt-in **one-shot library operation**, off by
default, with no runtime switch, timer, LaunchAgent, HTTP trigger or startup task.
Its catalog is only previously accepted exact-price public cache entries still
within retention; searches do not seed it. It accepts no shopping list, search
terms, supplied product array or client identifier. A trusted already-authenticated
operator principal is used for the existing quotas, never put in the public catalog.

Before looping, the cache transactionally claims the entire UTC-day scheduled run.
The claim survives failure, cancellation, restart, alternate operator principal and
catalog changes. A persisted maximum day prevents clock rollback from scheduling
an earlier day. At most one run is claimed per UTC day. The run stops before its
next product if the day changes; a subsequent day's explicit call is a separate
run, not continuation/replay of yesterday's failed work.

The maximum is 50 exact contexts (configurable down), sequentially, with the
existing eight-provider-operations-per-miss bound, deduplication, admission and
quotas. A monotonic admission cutoff defaults to 300 seconds and is at most 900;
it is checked before each context and each provider request. An already-started
HTTP operation may finish up to its transport deadline after that cutoff. There
are no automatic retries or background polls. The summary counts context attempts
(including cache hits), successes and failures; it does not report billable HTTP
units. `/v1/usage` remains the conservative accounting contract.

Worker shutdown cancels/drains its active run **and the shared cache**, because
this is one service lifecycle, rather than leave an unstructured cache leader
running after worker shutdown. Dormant/expired catalog entries are not rediscovered;
new discovery requires an explicit user request under the same policy gates.

## Versioned iPhone source status

Authenticated `GET /v1/sources` still rejects queries/bodies/Origin headers and
returns `Cache-Control: no-store`. Its prior unversioned array is replaced by:

```json
{"schemaVersion":1,"generatedAt":1792238400000,"sources":[]}
```

`sources` contains the configured exact-context catalog, five disabled entries
in the executable. Each entry has:

| Fields | Meaning |
|---|---|
| `provider`, `store`, optional `storeCode`, `channel` | Exact configured/requested tuple; H Mart omits physical store. Channel is unverified when `channelVerified` is false. |
| `technicallySupported`, `channelVerified` | Parser/context support, independent of permission and operational connection. False for Walmart/Target. |
| `fetchingEnabled`, `publicAccessApproved` | Fetching requires policy **and** configured upstream/nonzero controller; serving permission is separate. Never infer connection from store name. |
| `attribution`, `referenceOnly`, `limitation` | Required display text/scope; H Mart national reference, Lidl regional/unknown local stock. |
| `cacheTTLSeconds`, `displayTTLSeconds`, `maximumObservationAgeSeconds`, `retentionSeconds` | Conservative policy limits, zero for all runtime unapproved entries. |
| `state` | `disabled`, `pending`, `ready`, `partial`, `failed`, or `stale`. |
| optional `evidence` | Original `observedAt`, `retrievedAt`, optional `validFrom`/`validUntil`, Unix milliseconds; no product/client/search identity. |
| optional `lastAttemptedAt`, `lastSucceededAt` | Operational attempt-start and accepted-completion dates, Unix milliseconds. Cache hits do not advance them; each expires independently. Neither is a price observation date. |
| optional `pendingMeaning` | Present only for pending; no implication that a polling client starts work. |

States describe the context's latest bounded operation and usable retained
evidence. `disabled` wins for unapproved/unconfigured/stopping service. `pending`
means active bounded work **or no accepted result yet**, not a job promise, a
permission grant, a retry interval or a reason to poll. Complete price **or search**
evidence can make the context ready; an empty complete page can also be ready
without evidence dates. Partial pages remain partial; upstream failures remain
failed. Previously accepted evidence that becomes unusable/retention-purged is
stale while retained history establishes that state, with dates omitted as their
retention expires. After all retained history is gone, pending can mean no retained
accepted result. An old day/approval's late
completion cannot overwrite today's/new approval's state. This aggregate state
does not claim every product is covered, in stock or comparable.

Price/search response schema 1 and session/usage contracts are unchanged. Source
withdrawal consistently returns HTTP 503 `source_access_not_configured`, including
per-request provider preflight; service shutdown uses 503 `service_stopping`.
Existing 400/401/429/502/storage codes remain. No endpoint response exposes raw
provider errors, keys, database paths or session credentials. Issue #49 should
decode this envelope strictly, preserve unknown/unverified status, and never
substitute the personal app's direct-fetch capability descriptions.

## Offline verification

Run `swift test --package-path server --jobs 4 --force-resolved-versions` and
`uv run pytest`. Fixtures use temporary private SQLite, deterministic clocks,
injected sources and loopback-only transport; no retailer/provider access or user
library is needed. Coverage includes withdrawal during hits/leaders/followers and
failed purge, old approval/day completions, each TTL/offer boundary, empty/partial
search and outage states, legacy migration rollback, opaque claims, real child
process lock rejection/crash recovery, retained uncertain charges, worker daily
dedupe/day boundary and cooperative shutdown. Public source agreements, live
adapter validation, hosting and actual iPhone source UI remain separate work.
