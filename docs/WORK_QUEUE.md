# Work queue

The GitHub issues are the execution source of truth. This page records the initial
build order; update readiness labels when prerequisites are completed. Dependencies
are linked in issue bodies, not enforced by an automated GitHub workflow.

## Ready to start

- [#6 — Configure store locations without rewriting price history](https://github.com/justinahn711/staple-scout/issues/6)
- [#1 — Validate Wegmans Chantilly price access and capture fixtures](https://github.com/justinahn711/staple-scout/issues/1)
- [#7 — Validate Walmart Chantilly pickup prices and capture fixtures](https://github.com/justinahn711/staple-scout/issues/7)

Start with store configuration for the implementation work. The two source
research tasks can proceed independently alongside it. Do not assign concurrent
workers to the same persistence, schema, or API files.

Research can finish with a documented inaccessible-source outcome. That outcome
must leave its adapter blocked; a closed research issue is not proof that the
source works. Confirmation of real store locations and initial staple choices
is required before meaningful live use, not before building the configuration API.

## First live comparison

### After store configuration

- [#2 — Persist product variants and approved staple matches](https://github.com/justinahn711/staple-scout/issues/2)

### After product identity and matching

- [#8 — Add a typed adapter contract and safe observation ingestion](https://github.com/justinahn711/staple-scout/issues/8)
- [#11 — Add explicit shelf and pickup comparison modes](https://github.com/justinahn711/staple-scout/issues/11)
- [#3 — Build staple setup and manual price-entry screens](https://github.com/justinahn711/staple-scout/issues/3)

### After a successful source gate and ingestion

- [#9 — Implement the validated Wegmans price adapter](https://github.com/justinahn711/staple-scout/issues/9)
- [#10 — Implement the validated Walmart local pickup adapter](https://github.com/justinahn711/staple-scout/issues/10)

### After the web shell, channel API and source-status contract

- [#12 — Build comparison and this-week shopping views](https://github.com/justinahn711/staple-scout/issues/12)

The first milestone is complete when 10–15 user-chosen staples can be matched
and compared in the shopper interface with traceable observations from two
validated stores. Any source/coverage gap stays visible. Do not substitute mock
prices to pass this gate. If a priority source is unavailable, revise the source
plan explicitly before changing the milestone's promised coverage.

## Daily coverage

- [#4 — Validate and implement Target Chantilly price integration](https://github.com/justinahn711/staple-scout/issues/4)
- [#13 — Validate and integrate the H Mart online catalog as reference prices](https://github.com/justinahn711/staple-scout/issues/13)
- [#14 — Validate Lidl local price coverage and integrate supported offers](https://github.com/justinahn711/staple-scout/issues/14)
- [#15 — Add reliable daily refresh and a Mac schedule](https://github.com/justinahn711/staple-scout/issues/15)

These tasks need the common ingestion contract. Scheduler code can be tested
offline; live operation needs at least one validated adapter and explicit job
activation. Lidl live validation also needs the actual location. H Mart online
catalog prices remain reference data unless a distinct local source is verified.

## Weekly shopping

- [#16 — Compare actual package costs for a requested quantity](https://github.com/justinahn711/staple-scout/issues/16)
- [#5 — Build a weekly report from trusted comparisons and price history](https://github.com/justinahn711/staple-scout/issues/5)

## Working an issue

1. Read `AGENTS.md`, the issue, and its prerequisites. Resolve any explicit input
   or source gate before doing dependent work.
2. Use an isolated checkout and a feature branch. Keep one owner for shared files.
3. Implement the stated acceptance criteria and meaningful offline tests. Never
   test against the user's real shopping data.
4. Update the API contract and relevant docs when behavior changes.
5. Open a pull request with the problem, resulting behavior, verification results,
   and any remaining limitations; link the issue.
6. Close completed work only when its criteria are met, then reassess dependent
   issues and update `status:blocked` to `status:ready` where appropriate.

`priority:p1` means needed for the first live comparison; `priority:p2` is later
coverage or weekly usefulness. Neither label is an estimate or a delivery promise.
Costco, receipts, automated retail logins, public deployment, and notification
sending remain outside this queue.
