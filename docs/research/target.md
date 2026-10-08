# Target Chantilly source gate

Inspected 2026-10-08. **Local pricing is not validated; integration remains disconnected.**

The official [Chantilly store page](https://www.target.com/sl/chantilly-store/1827)
returns HTTP 200 and identifies store 1827 at 14391 Chantilly Crossing Ln,
Chantilly VA 20151-2118. The page's public client configuration references
RedSky's web `plp_client_v1` and grocery-page `pdp_client_v1` routes. Public
configuration establishes that these routes exist; it does not establish a
working local-price request or permission to treat an offer as shelf pricing.
No access key, session, cookie or token is saved in the fixture.

A normal in-app browser visit to the [grocery page](https://www.target.com/c/grocery/-/N-5xt1a)
stopped at a press-and-hold human verification challenge. It was not attempted
or bypassed. A direct public page request returned HTML, but no five-product
Chantilly price/stock evidence was established. Page accessibility and a visible
client configuration are insufficient to pass the pricing gate.

The sanitized access fixture records the verified store and observed blocker,
not product prices. No adapter or simulated retailer-price fixture is shipped.
Issue #4 remains open: implementation needs a reproducible supported way to
retrieve product identity, package quantity, local availability, channel, price,
conditions and evidence time for five representative staples at store 1827.
The user has no older API requests to supply; investigation started from the
websites as requested. Manual observations remain available in the app.
