# Fixed issue goal — 2026-10-08

Repository: **justinahn711/staple-scout**. Initial scope: **#1–#16 only**.

Initial issue/PR snapshots are immutable; JSON status is the detailed source of truth. PR ready means tested, reviewed and open. No PR has been merged. Each issue uses its own branch/worktree; reviewed stacked dependencies are permitted. Runtime supports two workers plus coordinator.

| Issue | State | Dependencies | PR / evidence |
|---|---|---|---|
| [#1](https://github.com/justinahn711/staple-scout/issues/1) Validate Wegmans Chantilly price access and capture fixtures | PR ready | — | https://github.com/justinahn711/staple-scout/pull/18 |
| [#2](https://github.com/justinahn711/staple-scout/issues/2) Persist product variants and approved staple matches | PR ready | #6 | https://github.com/justinahn711/staple-scout/pull/20 |
| [#3](https://github.com/justinahn711/staple-scout/issues/3) Build staple setup and manual price-entry screens | PR ready | #2 | https://github.com/justinahn711/staple-scout/pull/28 |
| [#4](https://github.com/justinahn711/staple-scout/issues/4) Validate and implement Target Chantilly price integration | blocked | #8 | https://github.com/justinahn711/staple-scout/pull/22 |
| [#5](https://github.com/justinahn711/staple-scout/issues/5) Build a weekly report from trusted comparisons and price history | PR ready | #12, #16, #15 | https://github.com/justinahn711/staple-scout/pull/30 |
| [#6](https://github.com/justinahn711/staple-scout/issues/6) Configure store locations without rewriting price history | PR ready | — | https://github.com/justinahn711/staple-scout/pull/17 |
| [#7](https://github.com/justinahn711/staple-scout/issues/7) Validate Walmart Chantilly pickup prices and capture fixtures | PR ready | — | https://github.com/justinahn711/staple-scout/pull/19 |
| [#8](https://github.com/justinahn711/staple-scout/issues/8) Add a typed adapter contract and safe observation ingestion | PR ready | #2 | https://github.com/justinahn711/staple-scout/pull/24 |
| [#9](https://github.com/justinahn711/staple-scout/issues/9) Implement the validated Wegmans price adapter | PR ready | #1, #8 | https://github.com/justinahn711/staple-scout/pull/31 |
| [#10](https://github.com/justinahn711/staple-scout/issues/10) Implement the validated Walmart local pickup adapter | blocked | #7, #8 | https://github.com/justinahn711/staple-scout/pull/32 (draft blocker checkpoint; no adapter) |
| [#11](https://github.com/justinahn711/staple-scout/issues/11) Add explicit shelf and pickup comparison modes | PR ready | #2 | https://github.com/justinahn711/staple-scout/pull/21 |
| [#12](https://github.com/justinahn711/staple-scout/issues/12) Build comparison and this-week shopping views | PR ready | #3, #11, #8 | https://github.com/justinahn711/staple-scout/pull/29 |
| [#13](https://github.com/justinahn711/staple-scout/issues/13) Validate and integrate the H Mart online catalog as reference prices | PR ready | #8 | https://github.com/justinahn711/staple-scout/pull/26 |
| [#14](https://github.com/justinahn711/staple-scout/issues/14) Validate Lidl local price coverage and integrate supported offers | PR ready | #8 | https://github.com/justinahn711/staple-scout/pull/25 |
| [#15](https://github.com/justinahn711/staple-scout/issues/15) Add reliable daily refresh and a Mac schedule | PR ready | #8 | https://github.com/justinahn711/staple-scout/pull/27 |
| [#16](https://github.com/justinahn711/staple-scout/issues/16) Compare actual package costs for a requested quantity | PR ready | #11 | https://github.com/justinahn711/staple-scout/pull/23 |

## Continuation checkpoint

Fourteen issues are PR ready. Only #4 (Target integration) and #10 (Walmart adapter) remain blocked on verified local source access. All 16 issues have their own isolated branches/worktrees and linked PRs. No GitHub PR has been merged. Research PR22 does not close #4; draft PR32 is a blocker checkpoint and does not close #10.

The setup, comparison/shopping and weekly-report PRs 28/29/30 are now ready at unchanged tested heads a88c90f, 2ab7be6 and 7c529e9. Their current-head CI passes. Browser input recovered in this resumed run, and final interaction checks passed using disposable databases: deletion cancellation/Escape/focus/keyboard confirmation; Shelf/Pickup, store and needed-only filters; empty store selection and shopping coverage gaps; report validation/generation/reopening/idempotency and keyboard disclosures. Current assets were reloaded before final checks. Actual 390px interactions, 44px controls and no horizontal overflow were verified. The UI/report stack has 218 Python and 11 Node tests passing. Fixture milk was changed to Not needed during filter validation in the disposable database; saved reports retain their original evidence.

Wegmans #9 remains ready as PR31 at a907a4c, stacked on PR27. Its public website exposes /api/products/133/<product>, with exact product/store identities and 133-Instore pricing; store133 was confirmed as Chantilly. The five-product live gate at 2026-10-08T13:18:22Z produced five traceable observations in a new disposable database, all matches pending. Milk stayed unavailable; chicken/bananas were estimated and loyalty/coupon terms conditional. All 262 offline tests and current-head CI pass. The reviewed PR18 research branch is incorporated locally, its original report retained separately and all eight historical fixtures replayed as negative cases. No GitHub PR was merged to accomplish this.

Target #4 was rechecked through its normal public grocery page in the evening. Some catalog cards rendered, but Fair Lakes was selected and a press-and-hold verification frame was visible. Those cards cannot establish Chantilly1827 local prices. Sanitized DOM evidence and the missing five-product gate are recorded in PR22 at 0549c7d; current-head baseline CI passes. No verification challenge was interacted with.

Walmart #10 has draft PR32 at 11e264e, stacked on PR27 and incorporating reviewed PR19 research. A normal public Chantilly5969 store-page request at 2026-10-08T21:07:04Z again redirected to human verification. Updated checkpoint documentation and current-head baseline CI pass. There is no validated local pickup source or implemented adapter. Indexed prices for other or unknown locations cannot fill that gate.

All independent implementation, tests and review are complete. The persistent goal is blocked and incomplete after three consecutive resumed turns with the same local-source barriers. Browser-input recovery allowed three UI PRs to become ready, but no verified Target/Walmart local access followed. Current issue acceptance criteria explicitly require dependable local access before implementation. Current PR22/32 remain unchanged source checkpoints; Target still shows Fair Lakes and verification. A user handoff has been requested to complete verification through normal browsing and confirm the selected Chantilly stores show product prices. There are no pending or working issues and no independent work remains. Previous audits are preserved in JSON history; no new issues were added to the frozen scope.

User selected Chantilly Lidl US01112 (14445 Chantilly Crossing Lane) and has no previous Wegmans/Target API requests. Lidl #14 uses its explicitly permitted documented-gap fallback and stays disconnected; H Mart is online reference only. No automated logins, challenge bypass, fabricated prices, automatic substitute approval, real-database tests, notifications, deployment or recurring job activation.

Test servers only: port8876 uses /private/tmp/staple-scout-ui-review-20261008.sqlite3; port8877 uses /private/tmp/staple-scout-final-ui-fixtures.sqlite3. Original port8765 contains user data and must not be used for tests. Review tabs and the Target verification page are preserved for continuation; the viewport override was reset.

Old AGENTS.md instructions were explicitly revoked; Impeccable fallback completed with PRODUCT.md recorded. Scope remains unchanged.
