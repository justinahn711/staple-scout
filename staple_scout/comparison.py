"""Dimension-safe comparisons without binary floating-point arithmetic."""

from datetime import datetime, timedelta, timezone
from decimal import Decimal, localcontext

UNITS = {
    "oz": ("oz", Decimal("1")),
    "lb": ("oz", Decimal("16")),
    "g": ("oz", None),
    "kg": ("oz", None),
    "fl_oz": ("fl_oz", Decimal("1")),
    "ml": ("fl_oz", None),
    "l": ("fl_oz", None),
    "each": ("each", Decimal("1")),
}


def unit_price(observation: dict, basis: str) -> Decimal | None:
    dimension, factor = UNITS[observation["unit"]]
    if dimension != basis:
        return None
    with localcontext() as context:
        context.prec = 50
        total = Decimal(observation["quantity"]) * observation["pack_count"]
        # Divide by an exact metric conversion to avoid rounding reciprocals.
        if observation["unit"] in {"g", "kg"}:
            total = total * (1000 if observation["unit"] == "kg" else 1) / Decimal("28.349523125")
        elif observation["unit"] in {"ml", "l"}:
            total = total * (1000 if observation["unit"] == "l" else 1) / Decimal("29.5735295625")
        else:
            total *= factor
        return Decimal(observation["price"]) / total


def compare(staple: dict, observations: list[dict], now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    offers = []
    candidates = []
    for row in observations:
        normalized = unit_price(row, staple["basis"])
        reasons = []
        if normalized is None:
            reasons.append("incompatible_dimension")
        if not row["approved"]:
            reasons.append("not_approved")
        if not row["available"]:
            reasons.append("unavailable")
        if not row.get("is_current_context", True):
            reasons.append("location_not_current")
        if not row.get("location_configured", True) or row.get("store_location", "").strip().lower() == "unselected":
            reasons.append("location_not_configured")
        if row["channel"] != "in_store":
            reasons.append("not_in_store")
        age = now - datetime.fromisoformat(row["observed_at"])
        if age < timedelta(0):
            reasons.append("future_observation")
        elif age >= timedelta(hours=48):
            reasons.append("stale")
        if row["conditions"].strip():
            reasons.append("conditional_price")
        offer = dict(row, unit_price=format(normalized, "f") if normalized is not None else None,
                     basis=staple["basis"], eligible=not reasons, exclusion_reasons=reasons)
        offers.append(offer)
        if not reasons:
            candidates.append((normalized, row["id"]))
    return {"staple": staple, "offers": offers, "winner_id": min(candidates)[1] if candidates else None}
