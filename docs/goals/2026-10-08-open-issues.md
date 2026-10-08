# Fixed issue goal — 2026-10-08

Repository: **justinahn711/staple-scout**. Initial scope: **#1–#16 only**.

The initial issue and PR JSON snapshots are immutable. New issues are not added to this scope.
The JSON status ledger is the detailed source of truth. PR ready means reviewed, tested, and open for review; it does not mean merged. Blocked requires a specific external input or access condition, not merely an unfinished dependency.

## Execution policy

Each issue uses its own branch and isolated worktree. Dependencies may use reviewed stacked branches without merging. Up to three workers were requested; this runtime currently permits two workers plus the coordinator. Continue with independent issues while others are blocked. Do not mark integration issues complete with only research evidence.

## Status

| Issue | State | Depends on | PR / evidence / blocker |
|---|---|---|---|
| [#1](https://github.com/justinahn711/staple-scout/issues/1) Validate Wegmans Chantilly price access and capture fixtures | PR ready | — | https://github.com/justinahn711/staple-scout/pull/18 |
| [#2](https://github.com/justinahn711/staple-scout/issues/2) Persist product variants and approved staple matches | PR ready | #6 | https://github.com/justinahn711/staple-scout/pull/20 |
| [#3](https://github.com/justinahn711/staple-scout/issues/3) Build staple setup and manual price-entry screens | pending | #2 |  |
| [#4](https://github.com/justinahn711/staple-scout/issues/4) Validate and implement Target Chantilly price integration | blocked | #8 | Normal public grocery browsing reaches a press-and-hold human-verification challenge. Store1827 verified; no five-product local-price gate or validated adapter. See isolated research branch; no prior requests exist to reuse. |
| [#5](https://github.com/justinahn711/staple-scout/issues/5) Build a weekly report from trusted comparisons and price history | pending | #12, #16, #15 |  |
| [#6](https://github.com/justinahn711/staple-scout/issues/6) Configure store locations without rewriting price history | PR ready | — | https://github.com/justinahn711/staple-scout/pull/17 |
| [#7](https://github.com/justinahn711/staple-scout/issues/7) Validate Walmart Chantilly pickup prices and capture fixtures | PR ready | — | https://github.com/justinahn711/staple-scout/pull/19 |
| [#8](https://github.com/justinahn711/staple-scout/issues/8) Add a typed adapter contract and safe observation ingestion | working | #2 | Initial implementation failed review; requires strict runtime evidence validation, idempotency, exact context/variant matching, provenance and comprehensive fake-adapter tests. Worker hit usage limit; coordinator continuing. |
| [#9](https://github.com/justinahn711/staple-scout/issues/9) Implement the validated Wegmans price adapter | blocked | #1, #8 | Website research has not yielded verified local pricing access. User has no existing API requests; further website investigation may proceed, but implementation requires supported price access. See PR18. |
| [#10](https://github.com/justinahn711/staple-scout/issues/10) Implement the validated Walmart local pickup adapter | blocked | #7, #8 | Direct Walmart local-store request reaches human verification; indexed offers belong to other locations. Need supported store-local access. See PR19. |
| [#11](https://github.com/justinahn711/staple-scout/issues/11) Add explicit shelf and pickup comparison modes | PR ready | #2 | https://github.com/justinahn711/staple-scout/pull/21 |
| [#12](https://github.com/justinahn711/staple-scout/issues/12) Build comparison and this-week shopping views | pending | #3, #11, #8 |  |
| [#13](https://github.com/justinahn711/staple-scout/issues/13) Validate and integrate the H Mart online catalog as reference prices | working | #8 | Unauthenticated official VTEX HTTP206 response verified; five real product IDs/barcodes/online offers captured. Needs adapter and offline tests after #8. |
| [#14](https://github.com/justinahn711/staple-scout/issues/14) Validate Lidl local price coverage and integrate supported offers | working | #8 | Official selected store US01112 confirmed. Coordinator completed ordinary favorite-store flow and reached current regional flyer. Public viewer JSON returns 12 product references; offer terms/price semantics remain under validation. No adapter enabled. |
| [#15](https://github.com/justinahn711/staple-scout/issues/15) Add reliable daily refresh and a Mac schedule | pending | #8 |  |
| [#16](https://github.com/justinahn711/staple-scout/issues/16) Compare actual package costs for a requested quantity | pending | #11 |  |

## Initial continuation plan

1. Reuse PR17/18/19 and mark them ready for review; leave main and user databases untouched.
2. Finish #2 on PR17, then fan out #8 ingestion and #3 setup UI; implement #11 modes on the reviewed matching API.
3. Research #13 and #4 independently, then implement any viable adapter after #8.
4. Finish #12, #15, #16 and #5 on their reviewed dependencies.
5. Record #9/#10/#14 input/access blockers and revisit if the user supplies needed information.

Previous AGENTS.md instructions were explicitly revoked by the user. Existing product constraints remain in the fixed issue bodies and accepted brief.

## User clarification

On 2026-10-08, user selected Lidl in Chantilly, VA, and confirmed there are no prior Wegmans or Target API requests to reuse. Research should proceed from retailer websites. Official Lidl location: https://www.lidl.com/s/en-US/stores/chantilly/chantilly-crossing-lane-14445/.
