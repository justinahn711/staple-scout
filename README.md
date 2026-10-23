# Staple Scout for iPhone

A native **Swift and SwiftUI iPhone app** for comparing grocery staples at Wegmans, Walmart, Target, H Mart and Lidl around Chantilly/Centreville. The user clarified iPhone as the target on October8,2026. The Python/web prototype remains reference material and is not the shipping app.

## Open and run

1. Open `iOS/StapleScout.xcodeproj` in Xcode16 or newer (iOS17+ deployment target).
2. Select the **StapleScout** scheme and an iPhone simulator, then Run.
3. For your own iPhone, select your Apple development team in Signing & Capabilities and run on the device. No signing credentials are committed.

The app runs independently on iPhone. It does not call a Python service or require a Mac to stay online. Local SwiftData storage uses the app’s private Application Support directory. First launch has no sample staples or prices. The application has no account system, CloudKit sync or public service.

A new [local shared-price prototype](docs/SHARED_PRICE_PILOT.md) adds a Swift server with a durable cache and an optional simulator transport. Individual clients enroll with single-use invitations and receive expiring, revocable sessions; the server no longer accepts a shared developer token. The [session contract](docs/CLIENT_SESSIONS.md) describes enrollment, rotation and local administration. The simulator can use an issued access token for its 15-minute lifetime; native enrollment, secure storage and automatic refresh remain issue #48. The service is not deployed; live sources are disabled by default and Walmart/Target access is still unresolved. Lists and approvals remain on device, and the existing personal app works without this service.

## Shopper flow

- **Staples:** add what you buy, describe acceptable substitutes, choose weight/volume/count, and mark this week’s needs. Search store catalogs automatically after adding a staple, track suitable products with fetched prices, and approve acceptable matches individually. Manual entry is an optional fallback. Requirement edits reset product reviews; need/amount edits preserve them.
- **Compare:** pick Shelf or Pickup and planned stores. Approved, available, unconditional prices under48hours old can win. Wrong-channel, unknown, estimated, unavailable and unapproved evidence stays excluded. Exact whole-package cost and excess quantity are shown separately from unit price.
- **This week:** unit-price choices grouped by store plus explicit coverage gaps. Save and reopen a weekly report with frozen requirements, reviews, contexts and cutoff evidence. Price drops require comparable immediately preceding product evidence, including timestamp ties.
- **Stores:** edit preferred immutable contexts without rewriting price history; inspect location/channel-aware source status and foreground refresh outcomes.

## Sources and limits

| Source | Native support |
|---|---|
| Wegmans Chantilly133 | Keyword discovery from the public storefront plus exact Chantilly JSON price checks; shelf only |
| H Mart | Keyword search and exact product/SKU price checks; national online reference only |
| Target Chantilly1827 | Blocked by public-site human verification; [research PR #36](https://github.com/justinahn711/staple-scout/pull/36) |
| Walmart Chantilly5969 | Public-site human verification; approved OPD developer access unavailable; [research PR #35](https://github.com/justinahn711/staple-scout/pull/35) |
| Lidl ChantillyUS01112 | Public regional in-store catalog search and exact-product refresh; stock unknown, excluded from winners |

Add a staple or choose **Find store prices** to search by name. Wegmans, H Mart and Lidl return up to five checked products each; exact price requests validate the discovered identities. Track a result to save its fetched price and a pending match, then approve products that meet your requirements. You never need to type a price or retailer product ID. Unsupported sources and partial failures remain visible. Keyword results are cached for the session and UTC day; repeated identical searches do not refetch. Barcode scanning is deferred to [backlog issue #34](https://github.com/justinahn711/staple-scout/issues/34); Walmart, Target and Lidl integrations are the current priority. Refresh is an explicit foreground action, at most50 distinct tracked product requests in one durable attempt per UTC day. Failed requests preserve historical observations and expose an error; they do not renew old observation timestamps. New package/product details need review and never inherit approval automatically. H Mart never becomes a shelf/pickup winner. Lidl uses the official Chantilly offer region US1112, preserves source observation and offer-validity dates, and does not infer local stock. Lidl candidates can be tracked for review but cannot win comparisons while stock is unknown. iOS background schedules are not activated or promised.

No Costco, receipts, automated retail login, challenge bypass, fabricated production prices, automatic substitute approvals, notifications or deployment. The earlier plan’s Mac scheduling approach has been superseded for the iPhone app.

The optional shared server now has [provider/client budget accounting](docs/PROVIDER_BUDGETS.md) around each potential provider HTTP request, including search follow-ups. Runtime provider caps are zero and sources remain disabled; the earlier unmetered `local-research` server mode is rejected. This does not change the personal app’s direct clients or establish a usable Walmart/Target feed. Local conservative reservations and provider-reported billing are reported separately; actual provider usage is still unmeasured.

## Tests

```sh
swift test --package-path iOS/Packages/StapleScoutKit
xcodebuild -project iOS/StapleScout.xcodeproj -scheme StapleScout \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

The Foundation-only Swift package tests comparison/report invariants and native URLSession extraction with offline fixtures. App tests use in-memory SwiftData containers. They never open a user database or call live retailers.

Use an available iPhone simulator name from your Xcode installation in the command above. GitHub CI selects an installed iPhone simulator automatically.

Debug builds use the selected simulator's active architecture so the app and Swift package compile for the same target. CI uses this project setting without an architecture override.

See [native implementation contract](iOS/CONTRACT.md), [migration record](iOS/MIGRATION.md) and the captured research on the earlier issue branches. Existing Python PRs have not been merged or deleted. Their original immutable issue snapshot remains preserved on the goal tracking branch; native parity and source blockers must not be confused with those earlier Python PR statuses.

A cached source response that changes package identity but predates newer evidence is rejected atomically and recorded as a failed source run. It cannot replace the newer package or reset its approval.

Wegmans search reads the public storefront configuration into memory and uses its current browser search index. No retailer keys are committed or persisted, and no account login or challenge bypass is used. Storefront configuration changes can interrupt discovery; those failures remain visible rather than falling back to invented results. User-initiated keyword searches are bounded to five candidate price checks per connected store and are separate from the once-daily tracked-product refresh.
