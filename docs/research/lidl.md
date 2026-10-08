# Lidl Chantilly source research

Selected by the user: Chantilly, VA. The official store payload identifies
**US01112**, 14445 Chantilly Crossing Lane, Chantilly VA 20151-2116; its
`offerRegion` is `1469`. The address number is not a store ID.

## Reproduced public source

The coordinator completed the ordinary favorite-store selection on the official
store page using the in-app browser. That page displayed "My Favorite Store" and
linked the current leaflet to `weekly-ad-10-7-2026-10-13-2026-3194fb/ar/1112`.
The viewer displays a 32-page weekly ad for October 7–13, 2026.

The viewer's public JavaScript constructs an unauthenticated GET to
`https://www.lidl.com/flyer/endpoints/v4/flyer` with `flyer_identifier`,
`region_id` and `region_code`. Replaying that observed request for `1112`
returned HTTP 200 with `success:true`, an active flyer, the selected code in
its region list, offer dates and 12 linked product records. No key, login,
challenge bypass, or guessed region was used. Store payload `offerRegion=1469`
and viewer link code `1112` are distinct source fields; do not interchange them.

The sanitized API-shaped fixture retains all 12 product references, exact price
strings, package description text, canonical paths, flyer dates and source
provenance. Its capture time comes from the downloaded response file's timestamp;
server `dateTime` is retained separately. Five examples include espresso coffee
(10 oz), gyro sandwich kit (38 oz), frozen breakfast croissants (four count / 18 oz),
frozen chicken fries (24 oz) and frozen crispy chicken strips (25 oz).
These are real catalog references linked from this flyer, not proof of complete
staple coverage. Milk, plain rice, eggs, bread and fresh produce have no structured
product records in this sample. Many printed flyer products are image/text-only.

## Price and condition limits

The product reference's `price` field does not identify regular versus promotional
price, membership eligibility, must-buy quantity, per-item effective dates,
availability, or store shelf verification. The flyer-level dates cannot prove
all product prices have the same offer terms. The viewer's general disclaimer
says prices may vary by location, availability is not guaranteed, and Lidl Plus
coupons can require activation. These unknowns must remain explicit; an empty
conditions field would incorrectly imply an unconditional offer.

**Adapter remains disabled pending #8 and extraction/condition validation.**
The public response is viable as flyer reference evidence, but has not passed a
five-staple local shelf-price gate. Any adapter must preserve unknown conditions
and exclude these records from cheapest-store recommendations until terms are
supported. Do not claim regular-price catalog coverage from a weekly ad.

Earlier worker-only browser availability errors were tooling limitations;
the coordinator successfully used the in-app browser, so they are not retailer
access blockers. The unsupported bare storestock probe is not price evidence.

Sources: [official Chantilly store](https://www.lidl.com/s/en-US/stores/chantilly/chantilly-crossing-lane-14445/),
[current selected-store leaflet](https://www.lidl.com/flyer/esi-flyer/weekly-ad-10-7-2026-10-13-2026-3194fb/ar/1112),
[public viewer request](https://www.lidl.com/flyer/endpoints/v4/flyer?flyer_identifier=weekly-ad-10-7-2026-10-13-2026-3194fb&region_id=1112&region_code=1112).
