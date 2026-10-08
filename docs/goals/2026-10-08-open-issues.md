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
| [#9](https://github.com/justinahn711/staple-scout/issues/9) Implement the validated Wegmans price adapter | PR ready | #1, #8 | https://github.com/justinahn711/staple-scout/pull/31 |
| [#10](https://github.com/justinahn711/staple-scout/issues/10) Implement the validated Walmart local pickup adapter | blocked | #7, #8 | https://github.com/justinahn711/staple-scout/pull/32 (draft blocker checkpoint; no adapter) |
| [#11](https://github.com/justinahn711/staple-scout/issues/11) Add explicit shelf and pickup comparison modes | PR ready | #2 | https://github.com/justinahn711/staple-scout/pull/21 |
| [#12](https://github.com/justinahn711/staple-scout/issues/12) Build comparison and this-week shopping views | blocked | #3, #11, #8 | https://github.com/justinahn711/staple-scout/pull/29 (draft; final interactive validation pending) |
| [#13](https://github.com/justinahn711/staple-scout/issues/13) Validate and integrate the H Mart online catalog as reference prices | PR ready | #8 | https://github.com/justinahn711/staple-scout/pull/26 |
| [#14](https://github.com/justinahn711/staple-scout/issues/14) Validate Lidl local price coverage and integrate supported offers | PR ready | #8 | https://github.com/justinahn711/staple-scout/pull/25 |
| [#15](https://github.com/justinahn711/staple-scout/issues/15) Add reliable daily refresh and a Mac schedule | PR ready | #8 | https://github.com/justinahn711/staple-scout/pull/27 |
| [#16](https://github.com/justinahn711/staple-scout/issues/16) Compare actual package costs for a requested quantity | PR ready | #11 | https://github.com/justinahn711/staple-scout/pull/23 |

## Continuation checkpoint

Eleven issues are PR ready: #1, #2, #6, #7, #8, #9, #11, #13, #14, #15, #16. Implemented setup, comparison/shopping and weekly-report issues #3/#12/#5 have draft PR28/29/30; final interactive validation needs the old native test confirmation canceled. Source integration issues #4/#10 remain blocked on verified local price access. Research PR22 does not close #4. Lidl #14 uses its explicitly permitted documented-gap fallback and stays disconnected.

Wegmans #9 is now ready as PR31, branch issue-9-wegmans-adapter, heada907a4c, stacked on PR27. Its anonymous public client-rendered website exposes /api/products/133/<product>, with exact product/store identities and 133-Instore pricing. Store133 was independently confirmed as Chantilly. The five-product live common-path gate at 2026-10-08T13:18:22Z produced five traceable observations in a new disposable database, all matches pending. Milk remained unavailable, chicken/bananas estimated, loyalty/coupon terms conditional. 262 offline tests pass, independent review found no blockers, and push/PR CI pass. Earlier PR18 HTML-only price-access conclusions are superseded by this new evidence. The reviewed PR18 branch is now included locally; its eight historical fixtures are all replayed as negative cases and its full report retained separately. This resolves a future documentation add/add conflict without merging any GitHub PR. No pickup/delivery capability is inferred.

All16 issues now have their own branches/worktrees. Walmart #10 has draft PR32, head075c449, stacked on PR27 and incorporating reviewed PR19 research. A fresh normal public GET at 13:27:56Z on October8 again returned Robot or human? at /blocked; sanitized metadata/hash and the exact missing source gate are committed. No adapter is fabricated; #10 remains blocked. Its baseline push/PR CI passes.

All currently unblocked implementation, tests and review are complete. The UI/report stack separately has 218 Python and 11 Node tests passing. CI passes for draft PR28/29/30 at the recorded heads. Browser rendering was inspected at 1280px and 390px on disposable fixtures; final interactive checks remain. This continuation revalidated that clicking the visible Pickup control still cannot change checked state; the old-tab dialog API returns no dismissible dialog. Navigation/read-only DOM inspection works, but interactive input remains blocked. Supported browser guidance requires reusing the selected browser, and native Codex access was denied; no workaround bypasses those restrictions.

Goal is blocked after the repeated-blocker audit; its full objective remains incomplete. Across three consecutive goal turns, the same browser-input and local-source-access blockers were revalidated. Independent progress continued in the first two turns: PR31 implementation/full historical-fixture coverage and issue10 isolation/checkpoint. The latest check still cannot change the enabled visible Pickup control, the old-tab dialog is not dismissible through the supported API, and current GitHub/ledger state shows no pending or working issue. The repeated-blocker threshold is now met; no further meaningful work is available without user input or an external-state change. Further work currently requires user/external state: cancel the old confirmation in the disposable port8876 tab, then verify deletion-dialog cancellation/confirmation, keyboard/filter interactions and report generation/reopening; promote passing draft PRs and recheck CI. Target/Walmart local-price access blockers remain independent. Frozen initial issue scope is unchanged; no PR was merged.

User selected Chantilly Lidl US01112 (14445 Chantilly Crossing Lane) and has no prior Wegmans/Target API requests. No automated logins/challenge bypass. H Mart is online reference only. No fabricated real prices, automatic substitute approval, real-database tests, notification delivery, deployment or recurring-job activation.

Test servers only: port8876 uses /private/tmp/staple-scout-ui-review-20261008.sqlite3; port8877 uses /private/tmp/staple-scout-final-ui-fixtures.sqlite3. Original port8765 is user data and must not be used for tests. Fixture names are explicitly labeled. Browser input is blocked across in-app tabs; the user was already asked to cancel the old confirmation.

Old AGENTS.md instructions were explicitly revoked; Impeccable fallback completed with PRODUCT.md recorded. Scope remains unchanged.
