# Fixed issue goal — 2026-10-08

Repository: **justinahn711/staple-scout**. Initial scope: **#1–#16 only**.

Initial issue and PR snapshots are immutable. Status JSON is the detailed source of truth. PR ready means tested, reviewed and open; no PR has been merged. Each issue uses its own branch/worktree; reviewed stacked dependencies are permitted. Runtime supports two workers plus coordinator.

| Issue | State | Dependencies | PR / evidence |
|---|---|---|---|
| [#1](https://github.com/justinahn711/staple-scout/issues/1) Validate Wegmans Chantilly price access and capture fixtures | PR ready | — | https://github.com/justinahn711/staple-scout/pull/18 |
| [#2](https://github.com/justinahn711/staple-scout/issues/2) Persist product variants and approved staple matches | PR ready | #6 | https://github.com/justinahn711/staple-scout/pull/20 |
| [#3](https://github.com/justinahn711/staple-scout/issues/3) Build staple setup and manual price-entry screens | working | #2 | https://github.com/justinahn711/staple-scout/pull/28 |
| [#4](https://github.com/justinahn711/staple-scout/issues/4) Validate and implement Target Chantilly price integration | blocked | #8 | https://github.com/justinahn711/staple-scout/pull/22 |
| [#5](https://github.com/justinahn711/staple-scout/issues/5) Build a weekly report from trusted comparisons and price history | pending | #12, #16, #15 | — |
| [#6](https://github.com/justinahn711/staple-scout/issues/6) Configure store locations without rewriting price history | PR ready | — | https://github.com/justinahn711/staple-scout/pull/17 |
| [#7](https://github.com/justinahn711/staple-scout/issues/7) Validate Walmart Chantilly pickup prices and capture fixtures | PR ready | — | https://github.com/justinahn711/staple-scout/pull/19 |
| [#8](https://github.com/justinahn711/staple-scout/issues/8) Add a typed adapter contract and safe observation ingestion | PR ready | #2 | https://github.com/justinahn711/staple-scout/pull/24 |
| [#9](https://github.com/justinahn711/staple-scout/issues/9) Implement the validated Wegmans price adapter | blocked | #1, #8 | Website research has not yielded verified local pricing access. User has no existing API requests; further website investigation may proceed, but implementation requires supported price access. See PR18. |
| [#10](https://github.com/justinahn711/staple-scout/issues/10) Implement the validated Walmart local pickup adapter | blocked | #7, #8 | Direct Walmart local-store request reaches human verification; indexed offers belong to other locations. Need supported store-local access. See PR19. |
| [#11](https://github.com/justinahn711/staple-scout/issues/11) Add explicit shelf and pickup comparison modes | PR ready | #2 | https://github.com/justinahn711/staple-scout/pull/21 |
| [#12](https://github.com/justinahn711/staple-scout/issues/12) Build comparison and this-week shopping views | working | #3, #11, #8 | Worker implementing comparison and shopping frontend against reviewed backend; integration, source health, package outlay and browser review pending. |
| [#13](https://github.com/justinahn711/staple-scout/issues/13) Validate and integrate the H Mart online catalog as reference prices | PR ready | #8 | https://github.com/justinahn711/staple-scout/pull/26 |
| [#14](https://github.com/justinahn711/staple-scout/issues/14) Validate Lidl local price coverage and integrate supported offers | PR ready | #8 | https://github.com/justinahn711/staple-scout/pull/25 |
| [#15](https://github.com/justinahn711/staple-scout/issues/15) Add reliable daily refresh and a Mac schedule | PR ready | #8 | https://github.com/justinahn711/staple-scout/pull/27 |
| [#16](https://github.com/justinahn711/staple-scout/issues/16) Compare actual package costs for a requested quantity | PR ready | #11 | https://github.com/justinahn711/staple-scout/pull/23 |

## Continuation checkpoint

Ten issues are PR ready: #1, #2, #6, #7, #8, #11, #13, #14, #15, #16. #3 has draft PR28 pending its final deletion-dialog browser check. #12 comparison/shopping frontend is being implemented; #5 weekly report follows. #4, #9 and #10 retain precise public-access blockers; research PR22 does not close #4. Lidl #14 uses its explicitly allowed documented-gap fallback and remains disconnected.

User selected Chantilly Lidl (US01112, 14445 Chantilly Crossing Lane) and has no prior Wegmans/Target API requests. Continue from public websites without automated logins or bypassing verification. H Mart is online reference only. No fabricated prices, automatic substitute approval, real-database tests, notification delivery, deployment or schedule activation.

The old native test confirmation currently blocks in-app-browser input. User has been asked to cancel it while other work continues; final UI validation uses disposable DB and server at port8876. Do not operate the real port8765 server.

Previous AGENTS.md instructions were explicitly revoked. Impeccable context launcher fallback was completed and PRODUCT.md recorded. Initial scope remains unchanged.
