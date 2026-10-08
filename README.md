# Staple Scout

A personal grocery comparison app for Wegmans, Walmart, Target, H Mart, and Lidl
around Chantilly and Centreville, Virginia.

**Status: working local API foundation.** Add your staples, record observed
prices, and compare approved products by unit price. The shopper interface,
automated store connections, scheduled refreshes, and weekly report are planned.
No retailer is connected yet, and no prices or staples are preloaded. Costco and
receipt importing are out of scope.

## Run locally

Requires Python 3.11+ and [uv](https://docs.astral.sh/uv/getting-started/installation/).

```sh
uv sync --locked
uv run uvicorn staple_scout.main:app --host 127.0.0.1 --port 8000
```

Open [the API explorer](http://127.0.0.1:8000/docs). Use **Try it out** on an
endpoint to make a request. The root address redirects there. The API explorer
uses Swagger UI assets from a CDN and needs internet access for those assets;
the API and SQLite data remain local.

Data persists in `data/staple-scout.sqlite3`. To use a separate database:

```sh
STAPLE_SCOUT_DB=/absolute/path/to/another.sqlite3 uv run uvicorn staple_scout.main:app --host 127.0.0.1 --port 8000
```

There is no account system yet. Keep this server on localhost. Phone access and
hosting need an explicit deployment and authentication design first.

## First comparison

1. Use `GET /api/stores` to see the configured stores and source status. Use
   `PATCH /api/stores/{store_id}` to select a location; configuration does not
   connect or verify a retailer price source.
2. Use `POST /api/staples` to add something you actually buy. Choose `oz` for
   weight, `fl_oz` for liquid volume, or `each` for meaningful counts. Describe
   acceptable substitutes in `rules`; these are instructions for your manual
   review, not automatically interpreted rules.
3. Use `POST /api/observations` to record a real product, package price, quantity,
   store, shopping channel, and observation time. `quantity` is the amount in one
   pack; `pack_count` is the number of those packs included in `price`.
4. Set `approved` to true only after checking that this product satisfies your
   staple's rules. Use `in_store` only for a price actually observed at that
   location. A price from a pickup page stays `pickup`.
5. Use `GET /api/comparisons` to inspect offers, unit prices, exclusions, and
   `winner_id`. Filter by `needed_only=true` or `stores=wegmans,walmart`.

Examples below define a staple, not a real price observation:

```json
{
  "name": "Firm tofu",
  "basis": "oz",
  "rules": "Plain, refrigerated, firm. Approve brands individually. No silken tofu.",
  "needed": true
}
```

The first version chooses a **lowest observed shelf unit price**, not a cheapest
basket. It ranks only approved, available, unconditional `in_store` observations
less than 48 hours old. Other offers stay visible with reasons they cannot win.
This 48-hour threshold is an initial conservative product choice, not a claim
about how frequently any retailer changes prices. `winner_id: null` means there
is no qualifying observation; it does not mean an item is free or unavailable
everywhere. Store inventory is only as reliable as the recorded observation.
Lidl remains ineligible until you configure its actual location. Switching a
preferred location preserves old observations under their original context;
they cannot win for the new location. When recording a price, pass the
`context_id` you reviewed to avoid ambiguity if the preference changes meanwhile.
Use `GET /api/observations` to inspect the original price history.
Changing a staple's name, unit basis, or rules clears its previous approvals;
record a new approved observation after checking the revised requirements.

## Development

```sh
uv run pytest
```

- [Build plan](docs/BUILD_PLAN.md): milestones, acceptance criteria, open decisions.
- [Work queue](docs/WORK_QUEUE.md): actionable issues, prerequisites, and build order.
- [Source validation](docs/SOURCES.md): evidence and integration requirements.
- [API contract](API_CONTRACT.md): request and response shapes.
- [Architecture](docs/ARCHITECTURE.md): data boundaries and planned evolution.
- [Implementation tasks](https://github.com/justinahn711/staple-scout/issues) and
  [first live comparison milestone](https://github.com/justinahn711/staple-scout/milestone/1).

There is deliberately no scheduler yet: it should run only after live adapters
have passed source validation. The initial app doesn't call retailer websites,
sign into retail accounts, invoke an LLM, or import receipts.
