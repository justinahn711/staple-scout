"""Request validation. Money and quantities enter as decimal strings."""

from datetime import datetime, timezone
from decimal import Decimal
from typing import Annotated, Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

Basis = Literal["oz", "fl_oz", "each"]
Unit = Literal["oz", "lb", "g", "kg", "fl_oz", "ml", "l", "each"]
Channel = Literal["in_store", "pickup", "online"]
Retailer = Literal["wegmans", "walmart", "target", "hmart", "lidl"]
MatchStatus = Literal["approved", "rejected", "pending"]
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
    desired_quantity: Quantity | None = None
    desired_unit: Unit | None = None

    @field_validator("desired_quantity", mode="before", json_schema_input_type=str | None)
    @classmethod
    def desired_decimal_string(cls, value):
        if value is not None and not isinstance(value, str):
            raise ValueError("Use a decimal string, not a JSON number")
        return value

    @model_validator(mode="after")
    def desired_pair_and_basis(self):
        if (self.desired_quantity is None) != (self.desired_unit is None):
            raise ValueError("desired_quantity and desired_unit must be provided together")
        if self.desired_unit is not None and ((self.basis == "oz" and self.desired_unit not in {"oz", "lb", "g", "kg"}) or (self.basis == "fl_oz" and self.desired_unit not in {"fl_oz", "ml", "l"}) or (self.basis == "each" and self.desired_unit != "each")):
            raise ValueError("desired unit is incompatible with staple basis")
        return self


class StaplePatch(StrictModel):
    name: Name | None = None
    basis: Basis | None = None
    rules: Annotated[str, Field(max_length=2000)] | None = None
    needed: bool | None = Field(default=None, strict=True)
    desired_quantity: Quantity | None = None
    desired_unit: Unit | None = None

    @field_validator("desired_quantity", mode="before", json_schema_input_type=str | None)
    @classmethod
    def desired_decimal_string(cls, value):
        if value is not None and not isinstance(value, str):
            raise ValueError("Use a decimal string, not a JSON number")
        return value

    @model_validator(mode="after")
    def reject_explicit_null(self):
        ordinary = self.model_fields_set - {"desired_quantity", "desired_unit"}
        if any(getattr(self, field) is None for field in ordinary):
            raise ValueError("Fields cannot be null; omit fields that are unchanged")
        if ("desired_quantity" in self.model_fields_set) != ("desired_unit" in self.model_fields_set):
            raise ValueError("desired_quantity and desired_unit must be provided together")
        if "desired_quantity" in self.model_fields_set and (self.desired_quantity is None) != (self.desired_unit is None):
            raise ValueError("Clear both desired quantity fields together")
        if "desired_quantity" in self.model_fields_set and self.desired_quantity is not None and self.desired_unit is not None:
            if ((self.basis == "oz" and self.desired_unit not in {"oz", "lb", "g", "kg"}) or (self.basis == "fl_oz" and self.desired_unit not in {"fl_oz", "ml", "l"}) or (self.basis == "each" and self.desired_unit != "each")):
                raise ValueError("desired unit is incompatible with staple basis")
        return self


class LocationContextCreate(StrictModel):
    location: Name
    location_id: Annotated[str, Field(min_length=1, max_length=100, pattern=r"^[A-Za-z0-9][A-Za-z0-9_-]*$")] | None = None
    channel: Channel = "in_store"
    location_status: Literal["user_reported", "tentative", "unconfigured"] = "user_reported"

    @model_validator(mode="after")
    def unconfigured_location(self):
        if self.location_status == "unconfigured":
            if self.location != "Unselected" or self.location_id is not None:
                raise ValueError("An unconfigured context must use location 'Unselected' and no location_id")
        elif self.location.lower() == "unselected":
            raise ValueError("Unselected locations must be marked unconfigured")
        return self


class StorePatch(StrictModel):
    context: LocationContextCreate | None = None
    context_id: int | None = Field(default=None, gt=0, strict=True)
    note: Annotated[str, Field(max_length=2000)] | None = None

    @model_validator(mode="after")
    def validate_selection(self):
        if any(getattr(self, field) is None for field in self.model_fields_set):
            raise ValueError("Fields cannot be null; omit unchanged fields")
        if self.context is not None and self.context_id is not None:
            raise ValueError("Provide either context or context_id, not both")
        return self


class ObservationCreate(StrictModel):
    variant_id: int | None = Field(default=None, gt=0, strict=True)
    context_id: int | None = Field(default=None, gt=0, strict=True, description="Immutable location context. Omit to use the store's current preferred context; explicit null is invalid.")
    staple_id: int = Field(gt=0, strict=True)
    store_id: Retailer
    product_name: Name
    price: Amount = Field(description="Total purchase-package price as a decimal string, e.g. '5.99'.")
    quantity: Quantity = Field(description="Quantity per pack as a decimal string, e.g. '12'.")
    quantity_kind: Literal["fixed", "estimated", "variable"] = "fixed"
    unit: Unit
    pack_count: int = Field(default=1, ge=1, le=10000, strict=True)
    channel: Channel = Field(description="in_store means a manually observed shelf price; pickup and online are not shelf prices.")
    observed_at: datetime = Field(description="Actual observation time, with timezone. Future observations are rejected.")
    source_url: Annotated[str, Field(max_length=2048)] | None = None
    available: bool = Field(default=True, strict=True)
    approved: bool = Field(default=False, strict=True, description="Explicit review for a new manual identity only. With variant_id, use the match-review endpoint; this historical flag cannot override pending or rejected reviews.")
    conditions: Annotated[str, Field(max_length=2000)] = ""

    @field_validator("context_id")
    @classmethod
    def non_null_context(cls, value):
        if value is None:
            raise ValueError("Omit context_id to use the preferred context")
        return value

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

class MatchReview(StrictModel):
    status: MatchStatus

class VariantCreate(StrictModel):
    retailer: Retailer
    retailer_product_id: Annotated[str, Field(min_length=1, max_length=200)] | None = None
    manual_identity: Annotated[str, Field(min_length=1, max_length=200)] | None = None
    barcode: Annotated[str, Field(min_length=1, max_length=100)] | None = None
    package_quantity: Quantity
    package_unit: Unit
    pack_count: int = Field(default=1, ge=1, le=10000, strict=True)
    form: Annotated[str, Field(min_length=1, max_length=200)]

    @field_validator("package_quantity", mode="before", json_schema_input_type=str)
    @classmethod
    def decimal_string(cls, value):
        if not isinstance(value, str):
            raise ValueError("Use a decimal string, not a JSON number")
        return value

    @model_validator(mode="after")
    def identity(self):
        if (self.retailer_product_id is None) == (self.manual_identity is None):
            raise ValueError("Provide exactly one retailer_product_id or manual_identity")
        return self
