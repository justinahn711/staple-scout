# Data retained by the local shared service

Issue #46 implements minimized search lookup, explicit operator maintenance and
client credential deletion. This is a localhost-only, single-operator prototype.
All public sources remain unapproved and all runtime provider limits remain zero.
No scheduler, backup service, public infrastructure or privacy-law compliance
certification is activated. The iPhone's private library is a separate database.

## Collection and access inventory

All three service databases, their WAL/SHM files and stable ownership lock files
are private operator-owned regular files (`0600`); containing directories must
remain private. The operating-system account and its administrators can read
these files. SQLite is not encrypted by this code. There is no data export,
analytics SDK, request logger, administrative HTTP route or public database access.

| Storage / retained fields | Purpose and retention |
|---|---|
| Cache `cache_entries`: operation, retailer, exact store/channel; public product ID for exact prices or keyed search identity; UTC day, insertion time, policy fingerprint, validated public evidence payload | At most 5,000 entries / 1 MB each. Delete on source withdrawal, policy mismatch, invalid payload, original retrieval or insertion reaching source retention. Runtime unapproved policies retain no payload. Serving never renews any date. |
| Public evidence: product ID/name/barcode, decimal price/currency/package/unit/count, availability, conditions, source URL/exclusion, original observation/retrieval and offer dates | Public product reference, independent of a client. Complete searches retain only candidate evidence, at most five candidates. No original request query, search message, client ID, library UUID, local list or match approval is serialized in the search payload. Partial pages are not cached. Names or product conditions can naturally contain the same words a user searched for. |
| Cache `cache_metadata`: database-scoped 32-byte secret, integrity check and maximum observed service time | Secret persists for database lifetime; never exposed in HTTP/usage/logs. Time persists to prevent rollback reopening pruned allowances. No reset/rotation command exists. |
| Cache `attempt_claims`: HMAC lookup and UTC day; `attempt_budgets`: day/month and aggregate count | Dedupe and logical attempt limits. Keep at least 62 days, then delete in batches of at most 5,000 per maintenance pass. A persisted clock prevents an old deleted day reopening. No client ID is stored. |
| Cache `scheduled_runs`: maximum claimed UTC day | One lifetime high-water tombstone. Never deleted by retention, client deletion or source withdrawal; a second run or clock rollback cannot replay the old run. |
| Cache `source_runs`: exact public source context, latest state/day, optional attempted/succeeded timestamps | At most configured contexts, no product, query or client. Clear on withdrawal; expire each timestamp independently at that source's retention and delete the row when neither remains. Migrated historical rows have no invented timestamps. |
| Auth `auth_clients`: stable random client ID, creation time, optional enrollment, revocation and deletion times | At most 50 lifetime client slots. Retained tombstones are pseudonymous abuse-control metadata, **not anonymous**. Deletion clears enrollment time but retains ID, creation/revocation/deletion times and the consumed slot. No slot recycling. |
| Auth `auth_invitations`: random invitation hash, client ID, expiry/use time | One per slot, default expiry one day (policy allows at most three). Explicit maintenance deletes expired, revoked or deleted-client invitations. Otherwise retained until maintenance; never plaintext. |
| Auth `auth_sessions`: random family/client IDs, current domain-separated credential hashes, expirations, revocation and generation | One family per enrolled client. Access lifetime at most 15 minutes, refresh at most 30 days from rotation. Explicit maintenance deletes expired refresh families and revoked/deleted families. No expiry extension is inferred from activity. |
| Auth `auth_refresh_history`: retired refresh hash, family ID, original expiry | Replay denial while the credential could be live, at most 30 days. Operations prune expired rows in batches of 5,000. Explicit deletion removes the deleted/revoked/expired family's history before removing its session. Unknown former credentials remain invalid. |
| Auth `auth_attempts`: trusted client-scoped or global operation scope, UTC hour/day, count; `auth_clock`: maximum observed time | Keep current quota periods; remove older periods in batches of 5,000. Current request/rotation counters survive client deletion. Clock clamping precedes verification, quota use and pruning in the same transaction, so rollback cannot revive a credential or reset a period. |
| Provider `budget_configuration`, `budget_clock` | Fixed cap-policy fingerprint and maximum observed time, retained for database lifetime. Deletion never raises caps or resets the clock. |
| Provider `budget_clients`: stable client ID | At most 50 lifetime quota identities, retained even after credential deletion. It is linked pseudonymous metadata, not a fresh anonymous identity. |
| Provider `budget_misses`: random miss/client ID, charge time, active flag, operation count; `budget_reservations`: random reservation/miss/client ID, charge time, purpose, dispatched flag, state | Retain completed/uncertain rows for at least 62 days, delete at most 5,000 per table/pass, and only remove inactive misses with no remaining reservations. Never expire reserved/dispatched work. Exclusive-owner recovery changes abandoned work to uncertain and starts a fresh conservative rolling charge window; it never refunds or replays. No query, product ID, upstream error or provider credential is stored. |

The service does not collect names, email, Apple/device identifiers, IP addresses,
receipts or an iPhone's staple list/substitution approvals/private library. An
operator invitation identifies an approved installation, not a verified person.
The authenticated API receives search text and requested public product IDs
transiently to answer the request. A future approved provider receives the query
needed for its operation under its own agreement; this prototype enables none.

## Keyed search lookup and migration

Search normalization remains Unicode NFC, collapsed whitespace and POSIX lowercase.
Only memory contains the canonical request key. Persistent search lookup uses
HMAC-SHA256(database secret, domain + SHA256(canonical request key)); exact public
retailer/store/channel remain explicit for policy enforcement. New daily claims
use the same derivation from the **original canonical request**, not from an
already-keyed cache key. The secret is in the same private SQLite file: a reader
of that database or backup also gets the key and can test guesses. This reduces
plaintext query storage and cross-database correlation; it is not anonymity,
encryption or protection against an operator/stolen-database dictionary attack.

Cache schema 4 atomically creates the secret and transforms legacy version-1 raw
claims / version-3 SHA256 claims to the same keyed identity. Claims, aggregate
budgets and the scheduled-day tombstone remain consumed. Legacy cache payloads
and raw keys are dropped, rather than retain request metadata from an older
format. No fetch is performed by migration. A missing/invalid schema-4 secret, a mismatched integrity check, or
unsupported schema fails closed; the secret is never regenerated to reclaim work.
Migration rejects more than 100,000 legacy claims for a separately reviewed offline
migration, instead of materializing arbitrary history during server startup.
Auth schema 2 adds deletion metadata and a durable clock; provider schema remains 1.
All migrations preserve the existing database inode and commit atomically.

## Explicit maintenance and client deletion

Stop the service first, use its exact three database path settings, then run from
`server/`:

```sh
swift run --force-resolved-versions ThriftyMarketMaintenance purge
swift run --force-resolved-versions ThriftyMarketMaintenance delete-client CLIENT_ID
```

`CLIENT_ID` is the nonsecret, exact `client1_` plus 32 lowercase hexadecimal
characters from the invitation/session. Do not put credentials or request text
in command arguments. `delete-client` also performs the normal maintenance pass.
There is no network maintenance endpoint. The command acquires all three existing,
non-expiring ownership locks before opening SQLite. A running service or another
maintenance process makes it fail. Lock files are never deleted or replaced.
Each actor consumes its one-use ownership capability; an already open owner cannot
be used to create another ledger or recover live work. Constructors perform the
existing exclusive-predecessor recovery once, conservatively retaining charges.

Deletion revokes and removes the selected client's invitation, current credential
hashes, retired refresh hashes and session family in one transaction. Deletion is
idempotent for an existing slot. Prior credentials and the prior invitation can
never enroll/refresh/authenticate again; after removal they report unknown rather
than reveal a former identity. The lifetime client tombstone, still-live auth
quotas and provider-linked reservations/counters remain as listed above. Shared
public product evidence belongs to no individual client and follows its source
policy, not a client's deletion request. This is credential/metadata reduction,
not a promise to erase every pseudonymous anti-abuse record. Local iPhone Keychain
and SwiftData deletion are separate native actions; this CLI cannot erase them.

Normal startup/request/status gates continue lazy cache maintenance. Explicit
maintenance also prunes inactive auth/provider history. Large eligible histories
may require repeated `purge` calls because expired claims/counter/ledger deletion
is bounded per pass; no automatic loop/timer is installed. Client-specific
credential deletion is bounded by the closed pilot (50 slots, one family each,
at most 100 rotations/client/day and 30-day replay window). There is no periodic
scheduler or wall-clock expiry guarantee on an idle/stopped host. Sources whose
agreement requires stricter deadlines cannot be enabled without implementing and
verifying that operation first.

Each connection enables SQLite `secure_delete`; maintenance requests a truncating
WAL checkpoint through SQLite itself. Checkpointing is **best effort**: another
SQLite reader can prevent a complete checkpoint and the command does not assert
all WAL frames were removed. No raw open/close of active DB/WAL/SHM is used for
inspection. There is no `VACUUM`, replacement database, lock unlink, file reset or
inode change that could invalidate service ownership. Logical deletion and page
zeroing do not prove secure physical erasure on SSDs, copied files, swap, OS
snapshots or backups; no such erasure is claimed.

## Logs, copied files and backups

The application installs no request/body/access logger or analytics exporter.
Typed HTTP failures and admin diagnostics omit raw query strings, credentials,
private library data, arbitrary upstream errors and database paths. Do not enable
proxy, shell-debug, crash-report or custom logging that records them. Operational
stdout/stderr can still reveal process startup/stop and safe error types; this
repository configures no log collector, rotation or guaranteed retention for a
terminal/shell/OS operator's copies. Synthetic-marker tests verify application
response/admin diagnostics and minimized cache payloads, not every operating
system, third-party proxy or future hosting layer.

No automatic backups or backup destination are created. For this prototype the
supported policy is **no retained service-database backups**. Operators must exclude
all three DBs, WAL/SHM, ownership locks, temporary invitation/session files and
private iPhone libraries from separately configured backup/sync/log collectors.
The program does not configure macOS Time Machine, cloud sync, APFS snapshots or
third-party tools and cannot verify their exclusions. Anyone who already copied
files must separately locate and remove them under their retention policy; a
successful maintenance command does not remove those copies or prior snapshots.
A public beta must verify host/backup/log configuration and disclose any actual
retention before collecting real users' requests. There is no promised backup
expiry or restore automation here.

Never restore an older auth/cache/provider snapshot to recover quota or service
work. Restore can resurrect issued/revoked credentials, clocks, consumed claims
and spending capacity even when ordinary maintenance is safe. A future restore
workflow must reconcile **all three** authoritative ledgers, source approvals and
credential revocations before any service/provider activation. Deleting/rotating
the lookup secret, databases or ownership locks is not recovery.

## Source status dates and verification limits

Schema-1 `/v1/sources` gains optional `lastAttemptedAt` and `lastSucceededAt` in
Unix milliseconds. Attempt means the cache leader claimed work and was about to
invoke its bounded operation; it does not prove a billable network request.
Success means complete validated price/search evidence, including an empty complete
page, was accepted. Cache hits never update these dates. Partial/failure updates
the attempt date and preserves an earlier success only within retention. Pending
crash recovery cannot invent success. Old-day or replaced-policy work cannot
advance current metadata. Original observation/retrieval/offer dates stay separate.
After all retained operation/evidence history expires the context can again be
`pending` (no retained accepted result), rather than permanently `stale`; it is
not a promise to schedule or poll. Missing dates stay unknown.

Offline tests use temporary private files and in-memory fixtures. They cover
migration/rollback, stable keyed lookup, missing-key failure, search message/query
minimization, retention boundaries, current claims and pending/uncertain ledger
preservation, client deletion/replay/lifetime cap, rollback clocks, private inode
ownership and actual CLI failure redaction. They make no live retailer/provider
calls and do not open a real iPhone library. Hardware Keychain, HTTPS hosting,
external logs/backups, source permission and public App Store privacy disclosures
remain separate activation/operational verification gates.
