# Staple Scout

This is an independent repository for a personal grocery comparison app. Work only
inside this checkout. Do not modify the neighboring workout app or its data.

## Product boundaries
- Stores: Wegmans, Walmart, Target, H Mart, Lidl. Costco is out of scope.
- Never fabricate live prices or silently label online prices as shelf prices.
- Preserve store, channel, observation time, source, availability and conditions.
- Product identity and approved substitution are separate concepts.
- Never compare weight, volume and count across dimensions.
- Keep sample data explicit and opt-in; the default database starts empty.
- No automated retail account logins. At most one scheduled refresh per day.
- Bind the development server to localhost; no public deployment is authorized.

## Engineering
- The shipping target is a native iPhone app using Swift, SwiftUI, SwiftData and URLSession. The user clarified this on October 8, 2026. Python/web code is historical reference and is not required by the native app.
- Use decimal arithmetic for money and quantity conversions.
- Write meaningful tests for normalization, matching, freshness and persistence.
- Do not commit databases, receipts, credentials, virtualenvs or raw private responses.
- Workers own separate files. Do not overwrite another worker's changes.
- Run `uv run pytest` before completing backend changes.
- For native changes, run `swift test --package-path iOS/Packages/StapleScoutKit` and relevant Xcode app tests. Use isolated in-memory stores for app tests; never open a user database or call live retailers from tests.

## Delegation
Use the workspace's cost-aware custom agents for substantial independent work;
prefer one worker, no recursive delegation. Tiny tasks stay local.
