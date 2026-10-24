# Native pilot coverage and source status

The **ThriftyMarketPilot** build keeps the accepted native shopping flow. Connect
with an operator invitation in **My stores**, tap **Check source status**, then
choose a listed approved store and channel. Add a staple, find store prices,
track a product as **Pending**, review its exact package and match, and approve
that product before comparing. Searching and importing never approve substitutes.
Empty and partially covered lists remain useful: the app explains missing sources
and comparison exclusions. No tutorial, account login, sample prices or catalog
coverage promise is added.

The production executable currently reports all five public sources disabled.
Walmart #5969 Pickup and Target #1827's unverified requested channel are visible
without becoming connected. These changes prepare offline-tested contracts; they
do not activate a retailer, provider subscription, public service or TestFlight.
The existing personal build retains its separate direct-source behavior.

## Status and choice contract

Authenticated `GET /v1/sources` returns the schema-version-1 envelope from
`SOURCE_POLICY_RECOVERY.md`, with optional `lastAttemptedAt` and `lastSucceededAt`
added by the retention work. The native decoder rejects unknown or duplicate
keys (including equivalent escaped keys), unknown stores/channels/states,
inconsistent permissions, wrong physical store codes, invalid times, excessive
text/TTL/body size and duplicate contexts. Catalogs are limited to five entries
and the reviewed Chantilly contexts. Multiple valid channels for the same store
are presented individually. Target's placeholder channel is never verified by
its label.

The catalog exists only in memory and is valid for five minutes after generation
and receipt, with both monotonic elapsed time and fail-closed wall-clock rollback
checks. Status updates are explicit; they never schedule product retrieval or
poll the server. Missing, expired or failed status requires a new user check.
The exact selected tuple gates searching, refreshing and tracking, independently
of the personal app's hardcoded direct-source capabilities. An unsupported old
location stays visible; choosing a validated pilot context reuses or creates the
known public location while preserving old observations at their original IDs.
Selected pilot channels are session-memory choices, not a library migration.

The pilot injects a catalog into `SessionMarketClient`; legacy personal/debug
clients preserve their existing behavior. A configured pilot cannot silently
fall back to direct requests. Catalog revisions and session epochs reject late
responses after another check, disconnect or reenrollment. The library also
checks its choice epoch before accepting asynchronous search or price results.
No eligible batch means no local daily-refresh claim; a legitimately started
batch retains its daily claim even if the request fails. Quota errors require a
later explicit user action, with no retry or refresh loop.

## Evidence and comparison

The interface labels source operation attempt and complete-success times
separately from original observation, retrieval and status-generation times.
Operation timestamps can be absent independently after retention. A cache hit
never makes a price newly observed or a source newly successful. Pending may
mean active bounded work **or no complete result yet**; it is not a job promise.
Ready may describe one result or an empty page, not full inventory or stock.

Current pilot comparisons, this week's recommendations and newly saved reports
project current public-serving permission and the stricter display/retention/
observation limits onto dated remote evidence. Unknown/expired permissions
produce visible exclusions rather than current winners. Operational outages
alone do not discard still-approved retained evidence. The projection does not
rewrite or delete original observations, match approvals or frozen saved reports;
manual observations qualify independently under existing comparison rules.
Device-side deletion guarantees remain a source-agreement activation requirement,
not a claim that changing source status erases an on-device history or backup.

H Mart stays a national online reference with a local-comparison exclusion. Lidl
stays regional offers with unknown local stock and original validity dates. Exact
package dimensions, availability, conditions, offer windows, approval and
estimated/variable-weight rules continue to apply. No UI label makes reference
or unknown-stock evidence an eligible local winner.

## Future remote Walmart and Target evidence

Existing price/search response schema 1 gains an optional per-record `provenance`
object. Old builders omit it. No current backend adapter emits an approved remote
Walmart/Target record. Fixtures prove the future boundary without enabling it:

- Exact keys: `schemaVersion`, `provider`, `store`, `storeCode`, `channel`,
  `seller`, `priceType`; version is 1.
- The approved catalog must specify `serpapi` and the same exact tuple. Walmart
  requires #5969 Pickup and first-party seller `Walmart`; Target requires #1827,
  verified Shelf/Pickup and seller `Target`. Only `regular` price type qualifies.
- Product ID, source enum and context must agree; HTTPS canonical retailer URLs
  must embed the same numeric product ID, with no credentials, query, fragment,
  port or encoded path substitution. Marketplace sellers, membership/conditional
  price types and missing or conflicting attestation are rejected.
- Existing decimal, quantity, duplicate-result, timestamp, offer and source
  exclusion checks remain. Provenance is validation-only; immutable local
  location/channel and original source/conditions/exclusions are retained in
  observations. It never substitutes for a user's product-match approval.

A future approved adapter must construct and test this attestation from verified
first-party evidence. A permission flag or optional field alone does not validate
a feed, grant public rights or enable arbitrary product URLs.

## Privacy, access and verification limits

The inline explanation says search sends entered words and exact public retailer,
store and channel; refresh sends product ID and that context. Requests use the
pilot session. Local staples, substitution rules, approvals and reports are not
uploaded. Server retention/deletion and operator revocation are separate from
local disconnect and are documented in the retention work.

Tests use synthetic wire fixtures and in-memory SwiftData. The dedicated review
simulator is used only for non-GUI builds/tests. Native system Lists, Sections,
buttons, labels, SecureField, SF Symbols, semantic text styles and minimum 44pt
actions preserve the existing accessibility approach. No screenshot, VoiceOver,
Dynamic Type, light/dark visual inspection or signed-device Keychain/HTTPS smoke
is claimed; those remain allowed-device verification and pilot activation gates.
