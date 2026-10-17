# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

A local grocery shopper comparing acceptable products across the stores they already use around Chantilly and Centreville, Virginia.

## Product Purpose

Find where to buy the groceries needed this week using comparable unit prices, explicit product approval, dated evidence and clear gaps when prices cannot be trusted.

## Operating Context

A private FastAPI app on the user's Mac, with SQLite and a phone-friendly browser interface. The fixed issue brief authorizes a small browser frontend. Setup includes staples, store locations, manually observed prices and review of product matches.

## Capabilities and Constraints

Retailers are Wegmans, Walmart, Target, H Mart and Lidl. Costco and receipts are deferred. Automated sources must pass validation before being connected. Prices have authoritative shelf, pickup or online channels. Online H Mart observations are reference prices, not verified Centreville shelf prices. No automated retail login, fabricated prices, automatic substitute approval or public deployment.

Store brands and name brands require individual review against the staple's requirements. Changing those requirements requires reapproval. Missing initial staples are collected in the app and do not block development. Real user data must not be changed during testing.

## Evidence on Hand

The API contract, fixed GitHub issue acceptance criteria and repository build plan define the product. Current source findings are research evidence; no retailer adapter is connected on this branch. No sample prices, default staples, product images or testimonials should be invented.

## Product Principles

- Preserve product, package, store, channel and observation-time provenance.
- Make missing or ineligible evidence visible.
- Let the shopper explicitly approve acceptable products.
- Keep routine setup and price entry usable without editing JSON.

## Accessibility & Inclusion

Issue #3 requires associated labels, keyboard navigation, clear focus behavior, phone and desktop layouts, and recoverable validation errors.

## Open Decisions

The user's actual staple list and substitution choices are collected in-app. Visual details are implementation choices for this issue; no standing aesthetic preference has been provided.
