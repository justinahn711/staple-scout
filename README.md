# Staple Scout for iPhone

A native **Swift and SwiftUI iPhone app** for comparing grocery staples at Wegmans, Walmart, Target, H Mart and Lidl around Chantilly/Centreville. The user clarified iPhone as the target on October8,2026. The Python/web prototype remains reference material and is not the shipping app.

## Open and run

1. Open `iOS/StapleScout.xcodeproj` in Xcode16 or newer (iOS17+ deployment target).
2. Select the **StapleScout** scheme and an iPhone simulator, then Run.
3. For your own iPhone, select your Apple development team in Signing & Capabilities and run on the device. No signing credentials are committed.

The app runs independently on iPhone. It does not call a Python service or require a Mac to stay online. Local SwiftData storage uses the app’s private Application Support directory. First launch has no sample staples or prices. The application has no account system, CloudKit sync or public service.

## Shopper flow

- **Staples:** add what you buy, describe acceptable substitutes, choose weight/volume/count, and mark this week’s needs. Record actual package prices and approve acceptable products individually. Requirement edits reset product reviews; need/amount edits preserve them.
- **Compare:** pick Shelf or Pickup and planned stores. Approved, available, unconditional prices under48hours old can win. Wrong-channel, unknown, estimated, unavailable and unapproved evidence stays excluded. Exact whole-package cost and excess quantity are shown separately from unit price.
- **This week:** unit-price choices grouped by store plus explicit coverage gaps. Save and reopen a weekly report with frozen requirements, reviews, contexts and cutoff evidence. Price drops require comparable immediately preceding product evidence, including timestamp ties.
- **Stores:** edit preferred immutable contexts without rewriting price history; inspect location/channel-aware source status and foreground refresh outcomes.

## Sources and limits

| Source | Native support |
|---|---|
| Wegmans Chantilly133 | Public website JSON, exact numeric product IDs, shelf only |
| H Mart | Verified composite product:SKU IDs, national online reference only |
| Target Chantilly1827 | Disconnected until reliable local access is validated |
| Walmart Chantilly5969 | Disconnected; local pickup access remains blocked |
| Lidl ChantillyUS01112 | Disconnected; regional flyer evidence does not verify regular local prices/stock |

To track a known website product, enter its retailer product ID when recording the product; product discovery and barcode scanning are not implemented. Refresh is an explicit foreground action, at most50 distinct tracked product requests in one durable attempt per UTC day. Failed requests preserve historical observations and expose an error; they do not renew old observation timestamps. New package/product details need review and never inherit approval automatically. H Mart never becomes a shelf/pickup winner. iOS background schedules are not activated or promised.

No Costco, receipts, automated retail login, challenge bypass, fabricated production prices, automatic substitute approvals, notifications or deployment. The earlier plan’s Mac scheduling approach has been superseded for the iPhone app.

## Tests

```sh
swift test --package-path iOS/Packages/StapleScoutKit
xcodebuild -project iOS/StapleScout.xcodeproj -scheme StapleScout \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test
```

The Foundation-only Swift package tests comparison/report invariants and native URLSession extraction with offline fixtures. App tests use in-memory SwiftData containers. They never open a user database or call live retailers.

Use an available iPhone simulator name from your Xcode installation in the command above. GitHub CI selects an installed iPhone simulator automatically.

See [native implementation contract](iOS/CONTRACT.md), [migration record](iOS/MIGRATION.md) and the captured research on the earlier issue branches. Existing Python PRs have not been merged or deleted. Their original immutable issue snapshot remains preserved on the goal tracking branch; native parity and source blockers must not be confused with those earlier Python PR statuses.

A cached source response that changes package identity but predates newer evidence is rejected atomically and recorded as a failed source run. It cannot replace the newer package or reset its approval.
