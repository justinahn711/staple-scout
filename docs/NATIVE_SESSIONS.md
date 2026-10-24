# Native pilot connection

Issue #48 adds the iPhone side of the closed, operator-invited session contract
in [CLIENT_SESSIONS.md](CLIENT_SESSIONS.md). It is an offline-tested native
implementation and build configuration. No HTTPS environment, signing account,
public deployment, retailer/provider key or invitation distribution is created.
Hosted physical-device verification remains an operations activation gate.

## Choose the intended build

Open `iOS/StapleScout.xcodeproj` and select **ThriftyMarketPilot**. Its **Pilot**
configuration defines `THRIFTY_PILOT`, uses bundle identifier
`com.justinahn.staplescout.pilot`, displays **Thrifty Pilot**, and opens its own
`StapleScoutPilot/Library.store` directory. It does not migrate, read or overwrite
the personal app's library. A new installation starts empty.

The configuration's `THRIFTY_SERVICE_URL` build setting defaults to **empty**.
Once an HTTPS environment is approved, set that nonsecret build setting to the
exact root service URL. The Pilot-only `iOS/Configuration/Pilot-Info.plist` template expands it into
the `ThriftyServiceURL` Info.plist member. Only HTTPS root URLs without credentials, query, fragment or extra path
are accepted. Do not put tokens or provider keys in any build setting, scheme,
Info.plist, source file or URL. There is deliberately no example staging host
that could be mistaken for a working deployment.

A missing or invalid URL leaves the pilot in its configuration recovery state;
search and refresh fail through the shared transport. It cannot select personal
direct clients. Xcode Run environment variables, including a legacy access token,
cannot switch a Pilot build to personal mode. This path is compiled for both
physical iPhones and simulators.

The existing **StapleScout** scheme's **Debug/Release** configurations remain
explicit personal/development builds. Their simulator-only, static-token opt-in
is historical development support. It does not enroll or rotate tokens and does
not prove the physical-device pilot. `SessionEndpoint` permits HTTP loopback only
when a caller explicitly enables `allowLoopbackDevelopment`; the pilot build
never enables that exception. No broad ATS exception is added.

## Connect and recover in My stores

The native **Pilot connection** section accepts the operator's single-use
invitation in a SecureField. The app sends only version `1` and the invitation
in the bounded JSON enrollment body. It never sends the full invitation file,
local library UUID, staple list, saved reports or product approvals. Search
requests necessarily send the shopper's entered search term plus public
store/code/channel context; request privacy/retention remains server-policy work.

The session status updates during enrollment and refresh. Expired, used or
rejected invitations get safe, actionable messages. Quota and unavailable-source
responses remain visible failures; they do not trigger a direct retailer request.
The [source-status flow](PILOT_ONBOARDING.md) starts with remote availability
unverified. **Check source status** loads the versioned service catalog; the user
then chooses an approved location/channel. A saved session is not proof that any
retailer source is enabled. Expired, unsupported or unapproved status cannot
enable remote requests or silently select a personal client.

**Disconnect this device** asks for confirmation and deletes its stored session.
It preserves the local library and does not call a nonexistent server revocation
endpoint. The operator must revoke the client separately if remote revocation is
needed; reconnecting requires a new invitation. A lost or revoked session family,
ambiguous refresh outcome or expired refresh credential also requires operator
re-enrollment. Client slots are not automatically recycled by the 50-slot pilot.
Uninstalling an iOS app is not a guaranteed Keychain deletion mechanism; use the
explicit disconnect and operator revocation workflow when retiring access.

If Keychain is locked/unavailable, the app fails closed and offers **Retry secure
storage** after unlocking. This reloads a safe persisted pair without consuming a
new invitation. A failed disconnect has a distinct **Retry disconnect** action:
it retries deletion rather than reconnecting the pair the user asked to remove.
Disconnect has not completed until that deletion succeeds; terminating the app
while storage is inaccessible is not proof that the item was deleted. Corrupt,
expired or interrupted-refresh storage is cleared and requires recovery rather
than being sent back to the server.

## Credential and concurrency boundaries

`NativeSessionController` is the sole actor owning a credential pair. Its
Keychain item is scoped to the exact service URL and bundle identifier. One
atomic item contains both credentials, their expiry dates, the stable server
client ID, storage version and the refresh-in-flight marker. It uses
[WhenUnlockedThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly),
no access group shared with another app, and no synchronizable/iCloud item.
Whole-item [SecItemUpdate](https://developer.apple.com/documentation/security/secitemupdate(_:_:))
replaces the pair; delete/add is not used for rotation. Credentials never enter
SwiftData, UserDefaults, URLs, request logs, diagnostics or user-visible errors.
Library backups and session storage are separate.

Access expires after at most 15 minutes; refresh expires after at most 30 days.
The controller refreshes near access expiry and coalesces concurrent callers into
one operation. A first protected-request 401 can request one serialized rotation;
a second 401 stops and enters recovery. Explicit revocation does not retry.
A late rejection of an old access token cannot clear a newer enrollment/pair.
Response version, exact keys, token purpose/format, expiry bounds and stable
client ID are validated before persistence. Duplicate/escaped/unknown keys,
unsupported versions, nonrotated pairs and identity changes are rejected.

Before dispatching refresh, the actor atomically writes a **refresh-in-flight**
marker with the old pair. A process killed after dispatch therefore cannot replay
its stored old refresh credential at next launch. A lost response, redirect,
malformed response, cancelled/uncertain delivery or unsafe post-rotation storage
result discards the pair and requires operator recovery. There is no application
retry loop or retry of a spent refresh token. The server revokes the whole family
when it sees a replay; it provides no safe lost-response retry grace period.
An explicit, typed `429 request_limit` means no rotation occurred under the
reviewed server contract; that known refusal can retain the pair with a 60-second
local cooldown. Unknown 429 bodies do not qualify for this exception.

A generation check discards all late enrollment/refresh completions after a
sign-out or newer enrollment. A rejected persisted marker cannot turn into a
usable pair on restart, even if deleting a locked Keychain item temporarily
fails. Secure-storage write failure **before** dispatch sends no refresh and
allows an unlock/reload retry. Storage failure after a committed remote rotation
never restores the old pair.

Networking uses ephemeral URLSession configuration, no cookie store or URL cache,
system TLS validation, exact final-response URL checking and a delegate that
[rejects redirects](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)).
Session requests have a 20-second timeout and bounded JSON responses. Protected
price/search requests reuse `SharedMarketClient`'s existing exact store/channel,
product identity, decimal, evidence-time, source URL and offer-window validation.
Delivery, token rotation and errors do not renew evidence timestamps or approvals.
Online-only evidence, unknown stock and package changes keep their exclusions.
No direct fallback exists for configuration, authentication, offline, quota,
disabled/pending source or partial-service results.

## Verification and remaining activation gates

Kit tests use an injected in-memory credential store and URLProtocol fixtures;
they never touch the Mac login Keychain or a retailer. They exercise enrollment
shape, restoration, typed errors, schema/identity/expiry validation, 20-caller
refresh coalescing, sign-out/enrollment races, the durable interruption marker,
lost responses, storage failures and price transport failure boundaries.

App tests use in-memory SwiftData, including the app test host before individual
tests start. An optional actual Keychain add/update/read/delete smoke uses a fresh,
random test service namespace on the dedicated review simulator and cleans it up.
The unsigned host here returns `errSecMissingEntitlement` (`-34018`), so that one
smoke is explicitly skipped only for that exact result. It is not counted as a
passed Keychain/hardware check. Injected SecItem tests independently verify
bundle/service isolation, device-only/non-synchronizing attributes, whole-item
marker/pair update without delete, and storage failures without accessing a Mac
login Keychain. A legitimately signed-device Keychain smoke remains required.
The integration fixture enrolls, searches, approves, reopens and refreshes through
the new transport, then loses the session while preserving the private library
and original evidence. No live source or real user library is used.

Run the package suite:

```sh
swift test --package-path iOS/Packages/StapleScoutKit --scratch-path /private/tmp/thrifty-issue48-kit --jobs 4
```

Run each app scheme sequentially against the dedicated **Staple Scout Review**
simulator (`B060CBF4-D8E0-4745-94CB-64BB321607F2`), using separate temporary result
bundles/derived data. The personal iPhone17Pro simulator is not a test target.
The shared CI workflow tests both schemes and compiles Pilot for `generic/platform=iOS`
with `CODE_SIGNING_ALLOWED=NO`. Use a fresh result bundle path each run:

```sh
xcodebuild -project iOS/StapleScout.xcodeproj -scheme ThriftyMarketPilot \
  -destination 'platform=iOS Simulator,id=B060CBF4-D8E0-4745-94CB-64BB321607F2' \
  -derivedDataPath /private/tmp/thrifty-issue48-pilot \
  -resultBundlePath /private/tmp/thrifty-issue48-pilot.xcresult \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 30 -maximum-test-execution-time-allowance 30 \
  CODE_SIGNING_ALLOWED=NO test

xcodebuild -project iOS/StapleScout.xcodeproj -scheme ThriftyMarketPilot \
  -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/thrifty-issue48-device \
  CODE_SIGNING_ALLOWED=NO build
```

Local checks on October 22, 2026: 101 Kit tests pass; each app scheme runs 34
tests with 33 passing, the single unsupported unsigned-Keychain smoke skipped,
and no failures. The Pilot generic iPhone target compiles without signing.

These checks prove offline behavior and native compilation. They do **not** prove
an approved hosted deployment, signed installation on hardware, live TLS/DNS,
production retailer access, public sharing permission or App Attest. Invitations
are the selected pilot enrollment mechanism; no device-integrity claim is made.
After separately authorized HTTPS operations preparation (#47) and pilot
activation, verify a signed physical iPhone installation against that approved
environment: missing configuration, enrollment, foreground/background unlock,
expiry/rotation, process interruption, operator revocation/recovery, offline,
quota and disabled-source failures. Confirm no direct retailer traffic and no
private library upload. Test real Keychain lifecycle/lock behavior and inspect
VoiceOver, large Dynamic Type, keyboard handling and light/dark appearances.

Simulator GUI access was unavailable for this task, so no rendered visual QA or
physical-device execution is claimed. The connection UI preserves native lists,
semantic text styles, SF Symbols, the existing green accent and 44-point actions.
