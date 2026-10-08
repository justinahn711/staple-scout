"""Typed, opt-in source adapter contract and bounded ingestion results."""
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from typing import Protocol, Iterable

@dataclass(frozen=True)
class OfferEvidence:
    retailer_product_id: str
    product_name: str
    barcode: str | None
    price: Decimal
    quantity: Decimal | None
    unit: str | None
    pack_count: int
    form: str
    channel: str
    available: bool
    seller: str | None
    location_id: str | None
    observed_at: datetime
    retrieved_at: datetime
    source_url: str | None = None
    conditions: str = ""

@dataclass(frozen=True)
class AdapterContext:
    retailer: str
    location_id: str
    channel: str

class SourceAdapter(Protocol):
    retailer: str
    def fetch(self, context: AdapterContext, product_ids: Iterable[str]) -> Iterable[OfferEvidence]: ...
