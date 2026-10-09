# Native iPhone target

On October8,2026 the user clarified that Staple Scout is an iPhone app in Swift. The earlier pasted brief named Python/httpx/Playwright/SQLite, which drove a web prototype; that target is superseded. Native work uses branch feature/native-iphone-app and an isolated worktree. Python remains historical reference and is not required to build or run the app.

The native implementation uses SwiftUI navigation/forms, a Foundation-only Swift package, SwiftData local persistence and URLSession source clients. It retains the accepted staples/store/price/review/comparison/shopping/report flow. Domain rules preserve exact decimal money, separate quantity dimensions, explicit product approval, location/channel provenance, freshness exclusions, package outlay and immutable report snapshots.

Two Python code-review findings are addressed directly in the Swift design: timestamp+sequence ordering makes same-minute price drops visible, and source capability checks include exact location+channel rather than retailer-level validation. Native reports additionally record ingestion and source completion times to avoid future evidence leaking into a cutoff snapshot.

The former fixed scope #1–#16 remains historical; no issues or PRs were silently merged, closed or replaced. This native PR references the relevant requirements but does not claim that research alone completes Target/Walmart integrations. Both remain blocked on validated local price access. Lidl remains disconnected under its documented-gap fallback; H Mart remains online-only reference. No old Python database is automatically imported.

iPhone differences: device-local storage replaces the Mac database; native URLSession replaces Python fetchers; explicit foreground daily refresh replaces the proposed Mac scheduled job. Barcode scanning, product discovery, cloud sync, receipt parsing, push notifications, background refresh guarantees, TestFlight and App Store distribution are deferred. Actual iPhone signing/provisioning uses the user’s Apple team in Xcode.

Validation on October 8, 2026: 32 Swift package tests and 19 native app tests passed, including persistence reopening, report cutoffs, package-review resets, shared-product refreshes and approval retention across daily refreshes. The app built with Xcode 26.6 and tests ran on the dedicated iPhone 17 Pro / iOS 26.5 simulator. Fixtures are offline and all app test stores are in memory.

Visual walkthrough is pending: computer-use access to Simulator was declined, so no screenshot or interactive UI verification is claimed. The native PR remains draft for that review. Physical iPhone signing, installation and hardware verification are also pending.
