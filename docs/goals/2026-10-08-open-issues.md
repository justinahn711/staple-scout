# Fixed issue goal — 2026-10-08

Repository: **justinahn711/staple-scout**. Initial scope: **#1–#16 only**.

Initial issue/PR snapshots are immutable; JSON status is the detailed source of truth. PR ready means tested, reviewed and open. No PR has been merged. Each issue uses its own branch/worktree; reviewed stacked dependencies are permitted. Runtime supports two workers plus coordinator.

| Issue | State | Dependencies | PR / evidence |
|---|---|---|---|
| [#1](https://github.com/justinahn711/staple-scout/issues/1) Validate Wegmans Chantilly price access and capture fixtures | PR ready | — | https://github.com/justinahn711/staple-scout/pull/18 |
| [#2](https://github.com/justinahn711/staple-scout/issues/2) Persist product variants and approved staple matches | PR ready | #6 | https://github.com/justinahn711/staple-scout/pull/20 |
| [#3](https://github.com/justinahn711/staple-scout/issues/3) Build staple setup and manual price-entry screens | blocked | #2 | https://github.com/justinahn711/staple-scout/pull/28 (draft; final interactive validation pending) |
| [#4](https://github.com/justinahn711/staple-scout/issues/4) Validate and implement Target Chantilly price integration | blocked | #8 | https://github.com/justinahn711/staple-scout/pull/22 |
| [#5](https://github.com/justinahn711/staple-scout/issues/5) Build a weekly report from trusted comparisons and price history | blocked | #12, #16, #15 | https://github.com/justinahn711/staple-scout/pull/30 (draft; final interactive validation pending) |
| [#6](https://github.com/justinahn711/staple-scout/issues/6) Configure store locations without rewriting price history | PR ready | — | https://github.com/justinahn711/staple-scout/pull/17 |
| [#7](https://github.com/justinahn711/staple-scout/issues/7) Validate Walmart Chantilly pickup prices and capture fixtures | PR ready | — | https://github.com/justinahn711/staple-scout/pull/19 |
| [#8](https://github.com/justinahn711/staple-scout/issues/8) Add a typed adapter contract and safe observation ingestion | PR ready | #2 | https://github.com/justinahn711/staple-scout/pull/24 |
| [#9](https://github.com/justinahn711/staple-scout/issues/9) Implement the validated Wegmans price adapter | blocked | #1, #8 | Website research has not yielded verified local pricing access. User has no existing API requests; further website investigation may proceed, but implementation requires supported price access. See PR18. |
| [#10](https://github.com/justinahn711/staple-scout/issues/10) Implement the validated Walmart local pickup adapter | blocked | #7, #8 | Direct Walmart local-store request reaches human verification; indexed offers belong to other locations. Need supported store-local access. See PR19. |
| [#11](https://github.com/justinahn711/staple-scout/issues/11) Add explicit shelf and pickup comparison modes | PR ready | #2 | https://github.com/justinahn711/staple-scout/pull/21 |
| [#12](https://github.com/justinahn711/staple-scout/issues/12) Build comparison and this-week shopping views | blocked | #3, #11, #8 | https://github.com/justinahn711/staple-scout/pull/29 (draft; final interactive validation pending) |
| [#13](https://github.com/justinahn711/staple-scout/issues/13) Validate and integrate the H Mart online catalog as reference prices | PR ready | #8 | https://github.com/justinahn711/staple-scout/pull/26 |
| [#14](https://github.com/justinahn711/staple-scout/issues/14) Validate Lidl local price coverage and integrate supported offers | PR ready | #8 | https://github.com/justinahn711/staple-scout/pull/25 |
| [#15](https://github.com/justinahn711/staple-scout/issues/15) Add reliable daily refresh and a Mac schedule | PR ready | #8 | https://github.com/justinahn711/staple-scout/pull/27 |
| [#16](https://github.com/justinahn711/staple-scout/issues/16) Compare actual package costs for a requested quantity | PR ready | #11 | https://github.com/justinahn711/staple-scout/pull/23 |

## Continuation checkpoint

Ten issues are PR ready: #1, #2, #6, #7, #8, #11, #13, #14, #15, #16. Implemented setup, comparison/shopping and weekly report issues #3/#12/#5 have draft PR28/29/30; final interactive validation needs the old native test confirmation canceled. Source integration issues #4/#9/#10 remain blocked on verified local price access. Research PR22 does not close #4. Lidl #14 uses its explicitly permitted documented-gap fallback and stays disconnected.

All currently unblocked implementation, offline tests and code review are complete. Final integrated suite: 218 Python and 11 Node tests. CI passes for draft PR28/29/30 at the recorded heads. Browser rendering was inspected at 1280px and 390px on disposable fixtures; final interactive checks remain. Goal is still active and not complete. At the next continuation, first check whether browser cleanup has cleared the old prompt; otherwise resume after the user cancels it, then validate the replacement deletion dialog, keyboard/filter interactions and report generation/reopening, promote passing draft PRs and recheck CI. Source access blockers are independent and must remain explicit.

User selected Chantilly Lidl US01112 (14445 Chantilly Crossing Lane) and has no prior Wegmans/Target API requests. No automated logins/challenge bypass. H Mart is online reference only. No fabricated real prices, automatic substitute approval, real-database tests, notification delivery, deployment or recurring-job activation.

Test servers only: port8876 uses /private/tmp/staple-scout-ui-review-20261008.sqlite3; port8877 uses /private/tmp/staple-scout-final-ui-fixtures.sqlite3. Original port8765 is user data and must not be used for tests. Fixture names are explicitly labeled. Browser input is blocked across in-app tabs; the user was already asked to cancel the old confirmation.

Old AGENTS.md instructions were explicitly revoked; Impeccable fallback completed with PRODUCT.md recorded. Scope remains unchanged.
