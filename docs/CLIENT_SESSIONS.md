# Individual sessions for the closed pilot

Issue #43 replaces the global developer credential with genuine invitation
verification and durable individual sessions. This is a **closed, operator-invited
pilot of at most 50 client slots**, with the server still bound to loopback and
live sources disabled by default. It does not open public enrollment or deploy a
service. The iPhone's local library stays private.

## Enrollment choice and trust boundary

An operator creates a single-use, 256-bit random invitation with the local admin
executable and transfers its private file to one intended participant through a
trusted channel. Possession of that invitation is the enrollment proof. The
server verifies its hash, expiry, unused state and client revocation state in one
SQLite transaction before issuing credentials. A public app installation would
enter an invitation received separately; the binary contains no reusable server
secret. There is no endpoint that grants sessions without an invitation, no
attestation-shaped placeholder, and no simulator bypass.

Invitation possession identifies an operator-approved installation, not a person
or a verified Apple device. A stolen invitation can be redeemed by its possessor;
transfer it privately, revoke its client slot if exposed, and do not send it in a
URL. A bearer access or refresh token can also be used by whoever steals it. The
future native client must keep the pair in Keychain, serialize refreshes, replace
both tokens atomically, and clear credentials after revocation. Native onboarding
and credential storage/refresh are issue #48; this change implements the server
contract, not that UI. A reinstallation or lost/revoked family needs operator
review and a new slot. Expired, used and revoked slots are **not automatically
recycled**: the 50-slot lifetime cap bounds retained identity metadata and prevents
unlimited re-enrollment from resetting quotas. Recovery/reassignment after that
cap requires a separately reviewed operator workflow; deleting the auth database
to reset it is not a recovery procedure.

**App Attest versus accounts.** Apple's [App Attest validation guide](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
requires server-validated attestation chains, application identifiers, one-use
challenges, assertions and increasing counters. It can establish app/device
integrity, but it does not by itself establish one human participant or prevent
an invited participant sharing access. Implementing only an unverified attestation
blob would provide no authentication. Accounts could add recovery and a user
identity across devices, but would require an identity provider, account security,
personal data and recovery/support work this small pilot does not need. Neither
is silently approximated here: operator invitation verification is the selected,
working enrollment mechanism. Public self-service needs a separate abuse design,
potentially real App Attest plus accounts or another verified enrollment proof.

No Apple developer account or external identity-provider configuration is needed
to verify these invitations. A later App Attest rollout requires a registered
App ID, the correct App Attest entitlement/environment, server validation and
physical-device tests; see [Apple's app-integrity setup](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity).
Simulator/tests use the same real invitation/token checks with isolated databases;
they do not assert device integrity. Physical-device session onboarding remains
blocked on issue #48 and separately authorized HTTPS networking/hosting. The
current localhost host/origin guards intentionally remain in place.

## Local administration

Run from the same directory as the service, using matching database environment
variables. The defaults are `THRIFTY_AUTH_DATABASE_PATH=data/client-sessions.sqlite`
and `THRIFTY_DATABASE_PATH=data/shared-prices.sqlite`. The server rejects the old
`THRIFTY_ACCESS_TOKEN` setting. A simulator's existing variable of that name may
temporarily contain an issued 15-minute access token; it is not a server secret
or an automatic refresh implementation.

```sh
cd server
unset THRIFTY_ACCESS_TOKEN
umask 077
THRIFTY_OPERATOR_DIR="$(mktemp -d "${TMPDIR:-/tmp}/thrifty-session.XXXXXX")"
swift run ThriftyMarketSessionAdmin invite "$THRIFTY_OPERATOR_DIR/invitation.json"
swift run ThriftyMarketServer
```

The admin executable creates a new file using exclusive creation, no symlink
following and mode `0600`. It never prints the invitation credential and refuses
to overwrite a file. The invitation file includes its nonsecret `clientID`, the
invitation and its expiry. Keep this directory outside source control. Revoke an
invited, enrolled or already revoked client locally:

```sh
swift run ThriftyMarketSessionAdmin revoke CLIENT_ID
```

`CLIENT_ID` means the exact `client1_` plus 32 lowercase hexadecimal characters
from the invitation/session file. Revocation is idempotent, persists across
restart, and blocks that client's invitation, access and refresh credentials.
There is no network admin route or admin bearer secret. The ability to run the
CLI as the operating-system account owning the auth database is the operator
capability. Secure that account and its backups.

The auth database is separate from the shared price cache and every iPhone
library. Canonical, symlink and hardlink aliases between auth/cache paths are
rejected. Existing auth files must be owned by the operator and exactly `0600`;
permissive files are rejected rather than silently chmodded. New database,
WAL and SHM files are owner-only. SQLite's no-follow open flag also rejects a
symlink at the database filename. An empty database or identified auth schema is
accepted; unrelated SQLite schemas are rejected without migration. Schema
bootstrap and its application/version markers commit atomically, so an
interrupted bootstrap can reopen safely. Keep the containing directory private;
the executable creates missing directories with `0700` and uses umask `077`.
The prototype assumes a trusted local filesystem and operator, not hostile
concurrent filesystem replacement or a shared network filesystem.

## Version 1 HTTP contract

All session requests are `POST`, `Content-Type: application/json`, at most 1,024
bytes, with exactly the two named members below in either order. `schemaVersion`
must be the JSON integer `1`; credentials must match the exact prefix and 64
lowercase hexadecimal characters. Unknown, duplicate or escaped keys, credential
escapes, extra parameters, query strings, Authorization headers and browser Origin
headers are rejected. Host remains loopback-only. Credential values belong only
in the bounded JSON body, never a URL, command argument or request log.

| Endpoint | JSON members |
|---|---|
| `/v1/session/enroll` | `schemaVersion: 1`, `invitation: "inv1_…"` |
| `/v1/session/refresh` | `schemaVersion: 1`, `refreshToken: "ref1_…"` |

Do not send the complete invitation file: its `clientID` and `expiresAt` are not
request fields. Prepare a private request file with just the required two members,
then send it using `curl --data-binary @PRIVATE_REQUEST_FILE --output PRIVATE_RESPONSE_FILE`
with the content-type header. This keeps secrets out of process arguments and
terminal output. The full command is in [the local pilot guide](SHARED_PRICE_PILOT.md).

A successful `200` response contains:

| Field | Value |
|---|---|
| `schemaVersion` | `1` |
| `clientID` | Stable, server-generated nonsecret quota identity |
| `tokenType` | `"Bearer"` |
| `accessToken` | `acc1_` plus 64 lowercase hexadecimal characters |
| `accessExpiresAt` | Unix milliseconds; 15 minutes after issuance |
| `refreshToken` | `ref1_` plus 64 lowercase hexadecimal characters |
| `refreshExpiresAt` | Unix milliseconds; 30 days after issuance/rotation |

Responses use `Cache-Control: no-store`, JSON content type and `nosniff`. All
price, search and source requests require exactly one
`Authorization: Bearer ACCESS_TOKEN` header. Health remains unauthenticated and
minimal: service status, schema version, local-only flag and disabled/research
source mode, without identities, credentials, prices or database paths. Price
evidence wire format and shared cache keys do not change.

Refresh atomically replaces **both** tokens and retires the previous refresh
hash. Old access tokens immediately become unknown/invalid. Reusing a retired
refresh token revokes the entire current session family, including tokens from
a successful competing refresh. If two connections refresh the same token
concurrently, exactly one rotation commits, the second detects replay and revokes
the family: **neither result remains usable**. Serialize refreshes. Do not retry
a refresh blindly after an ambiguous/lost response; operator re-enrollment is
required when the client cannot safely retain the returned pair. There is no
grace period, credential retry fallback or global developer-token fallback.

Safe error bodies have the existing v1 `{ "code": "…", "message": "…" }` shape.
Clients should branch on `code`, never on message prose. They never contain the
request token/body, raw errors, retailer responses or database paths.

| HTTP | Code | Meaning |
|---|---|---|
| 400 | `invalid_request` | Invalid request shape/context/credentials format |
| 401 | `auth_invalid` | Missing, malformed, wrong-purpose or unknown access/refresh credential |
| 401 | `auth_expired` | Recognized credential reached its expiry |
| 401 | `auth_revoked` | Client or session family revoked |
| 401 | `invitation_invalid` / `invitation_expired` | Unknown invitation or invitation reached expiry |
| 409 | `invitation_used` | Single-use invitation already redeemed |
| 401 | `refresh_replayed` | Retired refresh token reused; family is now revoked |
| 429 | `request_limit` | Client or global authentication/enrollment attempt cap reached |
| 503 | `auth_unavailable` | Auth storage or secure randomness unavailable |

Existing price-cache/provider error codes remain distinct. A denied session
never reaches an upstream adapter. No request/body logging or CORS middleware is
installed; quiet boundary middleware also converts body-collection/routing
failures to safe errors instead of passing them to Vapor's logging error
middleware. Reverse proxies, future observability and hosted infrastructure must
preserve these redactions; none is enabled by this change.

## Persistence, limits and privacy

Credentials use 32 random bytes from Apple's [SecRandomCopyBytes](https://developer.apple.com/documentation/security/secrandomcopybytes(_:_:_:)),
checking its return status, and are stored only as domain-separated
[CryptoKit SHA-256 hashes](https://developer.apple.com/documentation/cryptokit/sha256).
These are uniformly random secrets, not user passwords; no custom cipher,
signature, password hash or JWT verification is implemented. Current server and
CI targets are macOS; this system-API implementation does not claim Linux support.

The auth database retains at most 50 server-generated client IDs; creation,
enrollment and revocation timestamps; one invitation hash and expiry/use state
per client; one session-family ID, current credential hashes, expirations,
revocation and rotation generation; unexpired retired refresh hashes; and bounded
quota counters. It stores no email, username, Apple/device identifier, IP address,
local UUID, staple list, match approval, receipt or plaintext credential.
Credential hashes are not added to price-cache keys. The stable client ID survives
rotation and restart and provides the quota key without uploading library data.

Default reservations are transactional across SQLite connections/processes:

| Scope | Limit |
|---|---|
| Client protected requests, including cache hits, sources and malformed authenticated queries | 1,000 per UTC day |
| Client refresh rotations | 100 per UTC day |
| Enrollment attempts, including malformed bodies and replay | 100 per UTC hour, 500 per UTC day globally |
| Refresh attempts, including malformed bodies and replay | 1,000 per UTC hour globally |
| Invalid authentication attempts | 2,000 per UTC hour globally |

Reservations commit even when verification fails. Unknown values do not create
attacker-chosen client/counter rows. Invalid-auth exhaustion does not block a
known valid client's separate quota. Global enrollment/refresh caps can still be
exhausted to delay legitimate participants: this bounded pilot chooses visible
429 failures rather than unlimited minting/retries. Gateway/network DDoS defenses
and per-network policies remain hosting work; these limits are not provider-credit
accounting (#44). Shared retailer attempt budgets and source defaults remain as
before.

Old hour/day counter buckets and refresh tombstones are pruned transactionally
on subsequent operations. Tombstones remain until the retired credential's
original expiry (at most 30 days), so pruning cannot revive it. The 50-client,
100-rotations/day and 30-day bounds cap retained refresh history; after expiry an
old token is unknown/invalid rather than a replay signal. Client, invitation and
session rows, including revoked clients, remain capped and retained. Full identity
deletion, search-term privacy, backup retention and regulatory policy remain #46.
Filesystem permissions protect credential artifacts; hashing does not encrypt
identity metadata or make backups public-safe.

## Offline verification

`swift test --package-path server --jobs 4 --force-resolved-versions` exercises real
token generation and hashes with temporary/in-memory databases, no provider or
Apple calls. Storage tests cover restart, exact expiry, revocation, single-use
enrollment, concurrent two-connection redemption/rotation, replay family
revocation, durable quotas, pruning, file permissions, alias/unrelated-database
rejection and interrupted bootstrap recovery. HTTP tests cover all protected
routes, the safe health response, strict/oversized bodies, malformed/replayed
credentials, typed failures and legacy-token rejection. Existing cache freshness,
unknown-stock, durable provider budgets and midnight-overwrite tests still pass.

No app UI, Xcode project or shared native package source changes are required by
this server-only issue. Run `uv run pytest` as required by the repository. Public
deployment, real retailer fetching and real user libraries are not test fixtures.
