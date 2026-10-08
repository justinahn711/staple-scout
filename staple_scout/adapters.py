"""Runtime-validated evidence contract; adapters never approve product matches."""
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Annotated, Protocol
from urllib.parse import parse_qsl, urlsplit

from pydantic import ConfigDict, Field, field_validator, model_validator
from .models import Amount, Quantity, Unit, Channel, Retailer, StrictModel

TextID = Annotated[str, Field(min_length=1, max_length=200)]


class EvidenceModel(StrictModel):
    model_config = ConfigDict(extra='forbid', str_strip_whitespace=True, frozen=True)


class ProductRequest(EvidenceModel):
    staple_id: int = Field(gt=0, strict=True)
    retailer_product_id: TextID


class AdapterContext(EvidenceModel):
    retailer: Retailer
    context_id: int = Field(gt=0, strict=True)
    location_id: TextID | None
    channel: Channel


class OfferEvidence(EvidenceModel):
    source_record_id: TextID
    retailer_product_id: TextID
    product_name: Annotated[str, Field(min_length=1, max_length=200)]
    barcode: TextID | None = None
    price: Amount | None
    currency: str = Field(default='USD', pattern='^USD$')
    quantity: Quantity | None
    unit: Unit | None
    quantity_kind: str = Field(default='fixed', pattern='^(fixed|estimated|variable)$')
    pack_count: int = Field(default=1, ge=1, le=10000, strict=True)
    form: Annotated[str, Field(min_length=1, max_length=200)]
    channel: Channel
    available: bool | None = Field(strict=True)
    seller: TextID
    location_id: TextID | None
    observed_at: datetime
    retrieved_at: datetime
    source_url: Annotated[str, Field(min_length=1, max_length=2048)]
    conditions: Annotated[str, Field(max_length=2000)] = ''
    valid_from: datetime | None = None
    valid_until: datetime | None = None

    @field_validator('price', 'quantity', mode='before')
    @classmethod
    def decimal_input(cls, value):
        if isinstance(value, (float, bool)):
            raise ValueError('Use a decimal string or Decimal; binary floats are not evidence')
        return value

    @field_validator('observed_at', 'retrieved_at', 'valid_from', 'valid_until')
    @classmethod
    def aware_utc(cls, value):
        if value is None:
            return value
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError('Evidence timestamps require a timezone')
        return value.astimezone(timezone.utc)

    @field_validator('source_url')
    @classmethod
    def public_source(cls, value):
        parsed = urlsplit(value)
        secret_names = {'key', 'apikey', 'api_key', 'token', 'access_token', 'cookie', 'session', 'authorization', 'signature'}
        if (parsed.scheme not in {'https', 'http'} or not parsed.hostname or parsed.username or parsed.password
                or any(key.lower() in secret_names for key, _ in parse_qsl(parsed.query))):
            raise ValueError('Use a public source URL without credentials or access parameters')
        return value

    @model_validator(mode='after')
    def coherent_evidence(self):
        if (self.quantity is None) != (self.unit is None):
            raise ValueError('Unknown package quantity and unit must both be null')
        if self.observed_at > self.retrieved_at or self.retrieved_at > datetime.now(timezone.utc):
            raise ValueError('Evidence time must precede retrieval and neither may be future')
        if self.valid_from and self.valid_until and self.valid_until <= self.valid_from:
            raise ValueError('Invalid offer validity interval')
        return self


class SourceAdapter(Protocol):
    def fetch(self, context: AdapterContext, product_ids: list[str], *, timeout: float) -> list[OfferEvidence]: ...


@dataclass(frozen=True)
class AdapterRegistration:
    source_id: str
    retailer: str
    adapter: SourceAdapter
    channels: frozenset[str]
    sellers: frozenset[str]
    validated: bool = False
    timeout: float = 10.0

    def __post_init__(self):
        if not self.source_id or not self.channels or not self.sellers or not 0 < self.timeout <= 30:
            raise ValueError('A source needs identity, channel/seller policy and a bounded timeout')


class RefreshRequest(StrictModel):
    source_id: TextID
    context_id: int = Field(gt=0, strict=True)
    channel: Channel
    requests: list[ProductRequest] = Field(min_length=1, max_length=50)
    idempotency_key: Annotated[str, Field(min_length=1, max_length=100)]
