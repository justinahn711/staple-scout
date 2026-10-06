"""Request validation. Money and quantities enter as decimal strings."""

from datetime import datetime, timezone
from decimal import Decimal
from typing import Annotated, Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

Basis = Literal["oz", "fl_oz", "each"]
Unit = Literal["oz", "lb", "g", "kg", "fl_oz", "ml", "l", "each"]
Channel = Literal["in_store", "pickup", "online"]
Name = Annotated[str, Field(min_length=1, max_length=200)]
Amount = Annotated[Decimal, Field(ge=0, le=1_000_000, max_digits=13, decimal_places=6)]
Quantity = Annotated[Decimal, Field(gt=0, le=1_000_000, max_digits=13, decimal_places=6)]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class StapleCreate(StrictModel):
    name: Name
    basis: Basis
    rules: Annotated[str, Field(max_length=2000)] = ""
    needed: bool = Field(default=True, strict=True)


class StaplePatch(StrictModel):
    name: Name | None = None
    basis: Basis | None = None
    rules: Annotated[str, Field(max_length=2000)] | None = None
    needed: bool | None = Field(default=None, strict=True)

    @model_validator(mode="after")
    def reject_explicit_null(self):
        if any(getattr(self, field) is None for field in self.model_fields_set):
            raise ValueError("Fields cannot be null; omit fields that are unchanged")
        return self


class ObservationCreate(StrictModel):
    staple_id: int = Field(gt=0, strict=True)
    store_id: Literal["wegmans", "walmart", "target", "hmart", "lidl"]
    product_name: Name
    price: Amount = Field(description="Total purchase-package price as a decimal string, e.g. '5.99'.")
    quantity: Quantity = Field(description="Quantity per pack as a decimal string, e.g. '12'.")
    unit: Unit
    pack_count: int = Field(default=1, ge=1, le=10000, strict=True)
    channel: Channel = Field(description="in_store means a manually observed shelf price; pickup and online are not shelf prices.")
    observed_at: datetime = Field(description="Actual observation time, with timezone. Future observations are rejected.")
    source_url: Annotated[str, Field(max_length=2048)] | None = None
    available: bool = Field(default=True, strict=True)
    approved: bool = Field(default=False, strict=True, description="Manual confirmation that this exact product or substitution satisfies the staple's rules. No automatic product verification occurs.")
    conditions: Annotated[str, Field(max_length=2000)] = ""

    @field_validator("price", "quantity", mode="before", json_schema_input_type=str)
    @classmethod
    def decimal_strings(cls, value):
        if not isinstance(value, str):
            raise ValueError("Use a decimal string, not a JSON number")
        return value

    @field_validator("observed_at", mode="before")
    @classmethod
    def iso_timestamp(cls, value):
        if not isinstance(value, str):
            raise ValueError("Observation time must be an ISO timestamp string")
        try:
            return datetime.fromisoformat(value)
        except ValueError:
            raise ValueError("Observation time must be an ISO timestamp string") from None

    @field_validator("observed_at")
    @classmethod
    def aware_past_time(cls, value: datetime):
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("Observation time must include a timezone")
        value = value.astimezone(timezone.utc)
        if value > datetime.now(timezone.utc):
            raise ValueError("Observation time cannot be in the future")
        return value

    @field_validator("source_url")
    @classmethod
    def public_url_syntax(cls, value):
        if value is None:
            return value
        try:
            parsed = urlsplit(value)
            valid = parsed.scheme in {"http", "https"} and bool(parsed.hostname) and not parsed.username and not parsed.password
        except ValueError:
            valid = False
        if not valid:
            raise ValueError("Source URL must be an HTTP(S) URL without credentials")
        return value
