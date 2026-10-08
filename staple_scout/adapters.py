"""Typed, opt-in source adapter contract and bounded ingestion results."""
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from typing import Protocol, Iterable
from dataclasses import field

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

    def __post_init__(self):
        from datetime import timezone
        if self.price < 0: raise ValueError('invalid price')
        if self.quantity is not None and self.quantity <= 0: raise ValueError('invalid quantity')
        if self.unit is not None and self.unit not in {'oz','lb','g','kg','fl_oz','ml','l','each'}: raise ValueError('invalid unit')
        if self.observed_at.tzinfo is None or self.retrieved_at.tzinfo is None: raise ValueError('timestamps require timezone')
        if self.observed_at > self.retrieved_at or self.retrieved_at > datetime.now(timezone.utc): raise ValueError('invalid evidence time')

@dataclass(frozen=True)
class AdapterContext:
    retailer: str
    location_id: str
    channel: str

class SourceAdapter(Protocol):
    retailer: str
    def fetch(self, context: AdapterContext, product_ids: Iterable[str]) -> Iterable[OfferEvidence]: ...
