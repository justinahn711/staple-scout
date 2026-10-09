# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

A grocery shopper around Chantilly and Centreville comparing acceptable groceries at the stores they already visit.

## Product Purpose

Find where to buy this week's staples using approved products, comparable unit prices, actual package costs and dated price evidence.

## Operating Context

Native iPhone app in Swift and SwiftUI, iOS17+. Local SwiftData persistence. The user clarified the native iPhone target on October8,2026 after reviewing the earlier web flow; the Python implementation remains reference, not the shipping application. No running Mac server or webview is required.

## Capabilities and Constraints

Staples, individual product-match approval, manual observations, Shelf/Pickup comparisons, shopping groups and frozen weekly reports. Wegmans133 shelf and HMart online-only reference source research may be reused through native URLSession adapters. Target/Walmart remain blocked on verified local access; Lidl remains disconnected. Manual observed prices can qualify independently. No Costco, receipts, account logins, challenge bypass, fabricated production prices, automatic substitute approval, notifications or deployment. Refresh only explicit in foreground, at most50 tracked requests per UTC day; iOS background execution is not promised.

## Product Principles

Keep product/package/store/channel/time provenance. Show gaps and excluded evidence. Approve acceptable products individually. Changing staple requirements clears approval; weekly-needed and requested-amount changes do not. Unknown stock, price, quantity or conditional offers cannot win. User data stays on device.

## Accessibility & Inclusion

Native semantic controls, system typography and Dynamic Type, VoiceOver labels,44pt minimum actions, light/dark support and destructive confirmation. Preserve the accepted app flow in native navigation.

## Open Decisions

Actual staple list and substitution choices are entered in app. Apple signing team and real-device provisioning are user-specific; simulator development requires neither account credentials nor a service subscription.
