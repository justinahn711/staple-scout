# Design notes

Restrained setup workspace: warm off-white surface, deep green navigation, native controls, clear status and error states, responsive single-column mobile forms.

The setup flow uses four sections: staples, saved store locations, manual price
entry, and product-match review. Default data is empty; source connections and
match reviews are explicit. Editing staple requirements explains reapproval;
weekly-needed and desired-quantity edits preserve reviews.

Tokens live in `staple_scout/static/app.css`: warm `#f6f7f1` background, `#1d332a`
text/header, `#176447` action/focus color, muted `#64736a`, line `#d8e0d7`, and
`#a33f35` destructive actions. System fonts and native inputs keep the local tool
compact. Forms use two columns above 620px and one below; list rows stack on
phones. Buttons/inputs have at least 44px touch targets. Labels are associated,
errors use a focusable alert, status uses a polite live region, and tabs support
keyboard arrows/Home/End. Destructive deletion uses a labeled in-page dialog
with Cancel focused by default.

Coordinator browser validation used only a disposable database on port8876:
add/edit, invalid price and desired amount recovery with preserved fields,
repeated price entry and variant reuse, approved matches, needed-only edits,
rule edits resetting review, and explicit previous-location entry. At 390px,
there was no page overflow, every input had a label and no button was below44px.
The original browser-native deletion prompt blocked automation; the final
in-page dialog replaced it. The later October 8 verification recorded in the
[fixed-scope ledger](https://github.com/justinahn711/staple-scout/blob/goal/open-issues-2026-10-08/docs/goals/2026-10-08-open-issues.md)
completed Cancel, Escape, focus restoration, keyboard confirmation and 390px
layout checks at implementation head `a88c90f`. This corrects the earlier pending
note; it does not claim a new browser run or native iPhone visual review. No real
staples or prices were added to user data.
