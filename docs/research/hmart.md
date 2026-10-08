# H Mart online catalog research

Reviewed 2026-10-08 (America/New_York). Outcome: reference-only and not yet adapter-ready. The official Hapi page is reproducible without an account and exposes names, package text and USD display prices, but no store identifier, fulfillment mode, barcode, stock quantity, seller, or source-effective timestamp. The VTEX endpoint from the brief was not reproducible: direct requests failed DNS resolution and browser fetch was inaccessible. No access key was guessed.

The fixture `tests/fixtures/hmart/hapi-products.json` records five products visible on Hapi. They are online observations with unknown stock and no location, so they must not enter shelf or pickup ranking. Retrieval time is captured; source price-effective time is null.

The sample is snack-category only, not evidence of staple or fresh-produce coverage. Produce remains an explicit gap: no produce record was observed and the page provides no store-level stock evidence. H Mart documents that online/store prices and regional offers vary, so online prices cannot be relabeled as Centreville shelf prices.

The future common adapter needs retailer product ID, barcode as a string, canonical name, exact package size/form, pack count, seller, Decimal price/currency, availability, conditions, channel, location, source URL, source-effective timestamp, and retrieval timestamp. Hapi currently supplies only name, package text, price, currency, channel, source URL, and retrieval time. Unknown quantity or variable-weight produce must remain unknown.

Before enabling an adapter, obtain a supported machine-readable request or official export returning stable IDs/barcodes and availability, then validate selected store/region representation. Sources: [Hapi](https://www.hmart.com/hapi), [online/store price FAQ](https://support.hmart.com/hc/en-us/articles/4408935803411-Why-is-there-a-price-difference-between-in-stores-and-online), [regional variation FAQ](https://support.hmart.com/hc/en-us/articles/4408935824915-Why-do-products-and-prices-vary-by-state).
