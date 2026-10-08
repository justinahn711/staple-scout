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
The original native deletion prompt blocked browser automation; the final
in-page dialog replaced it. Its final interactive check is pending cancellation
of the old browser prompt. No real staples or prices were added to user data.

### Comparison review checkpoint (#12)

Comparison and shopping screens display recorded evidence, exclusions, backend winner IDs, separate whole-package outlay, planned-store coverage and channel/context source health. Offline Node tests cover cheaper excluded offers, escaping, shopping gaps, filter URLs and cancellation. Full Python regression suite passes (200 tests). The final keyboard/phone browser check is pending: an older native confirmation in a disposable test tab currently blocks browser input. No claim of completed browser verification is made for these new screens.

### Weekly report (#5)

The local web report freezes requirements, approvals and preferred locations at first generation, clearly labels its evidence cutoff and generation time, and provides a persistent local reopening link. It groups unit-price choices, shows package outlay separately, retains excluded offers/coverage gaps and shows comparable same-package price changes without basket-savings claims. Backend fixtures cover empty history, changed packages, mixed channels, unavailable/conditional history, source cutoff boundaries, context changes, reopen and snapshot immutability. Browser input remains blocked by the earlier native test confirmation; final interactive validation is pending and the PR remains draft.

Actual rendering inspection: disposable fixture server at port8877 rendered comparison and saved-report screens in the in-app browser at 1280px and 390px. Phone document width equals viewport width, all comparison controls have associated labels and 44px label targets, and report links/buttons/disclosures are 44px. Deep-linked selected tabs scroll into view at initial phone load. The comparison visibly preserves a cheaper unapproved exclusion and package outlay; the report shows one recommendation, one gap and the traceable fixture price drop. This was a read-only rendering/accessibility inspection; interactive confirmation/keyboard checks remain pending because browser input is blocked.
