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


def compare(staple: dict, observations: list[dict], now: datetime | None = None,
            channel: str = "in_store") -> dict:
    if channel not in {"in_store", "pickup"}:
        raise ValueError(f"Unknown comparison channel: {channel}")
    now = now or datetime.now(timezone.utc)
    offers = []
    candidates = []
    for row in observations:
        normalized = unit_price(row, staple["basis"])
        reasons = []
        if normalized is None:
            reasons.append("incompatible_dimension")
        # Persistent match state is authoritative. The legacy observation flag
        # is retained as historical input, never an override for a pending match.
        if "match_status" in row:
            if row["match_status"] != "approved":
                reasons.append("match_rejected" if row["match_status"] == "rejected" else "not_approved")
        elif not row["approved"]:
            reasons.append("not_approved")
        if not row["available"]:
            reasons.append("unavailable")
        if not row.get("is_current_context", True):
            reasons.append("location_not_current")
        if not row.get("location_configured", True) or row.get("store_location", "").strip().lower() == "unselected":
            reasons.append("location_not_configured")
        if row["channel"] != channel:
            reasons.append("not_in_store" if channel == "in_store" else f"not_{channel}")
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
    winner_id = min(candidates)[1] if candidates else None
    return {"staple": staple, "offers": offers, "winner_id": winner_id,
            "channel": channel,
            "gap": None if winner_id is not None else ("no_observations" if not offers else "no_eligible_offers")}
