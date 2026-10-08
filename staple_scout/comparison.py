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

BASE_FACTORS = {"oz": Decimal("28.349523125"), "lb": Decimal("453.59237"), "g": Decimal("1"),
                "fl_oz": Decimal("29.5735295625"), "ml": Decimal("1"), "l": Decimal("1000"), "each": Decimal("1")}

def package_outlay(observation: dict, staple: dict) -> tuple[str, str, int] | None:
    required = staple.get("desired_quantity")
    desired_unit = staple.get("desired_unit")
    if required is None or desired_unit is None:
        return None
    unit = observation["unit"]
    if (unit in {"oz", "lb", "g", "kg"} and desired_unit not in {"oz", "lb", "g", "kg"}) or (unit in {"fl_oz", "ml", "l"} and desired_unit not in {"fl_oz", "ml", "l"}) or (unit == "each") != (desired_unit == "each"):
        return None
    def grams(q, u): return Decimal(q) * (Decimal("1000") if u == "kg" else BASE_FACTORS[u])
    if unit in {"oz", "lb", "g", "kg"}: package = grams(observation["quantity"], unit); need = grams(required, desired_unit)
    elif unit in {"fl_oz", "ml", "l"}: package = Decimal(observation["quantity"]) * (Decimal("29.5735295625") if unit == "fl_oz" else Decimal("1000") if unit == "l" else Decimal("1")); need = Decimal(required) * (Decimal("29.5735295625") if desired_unit == "fl_oz" else Decimal("1000") if desired_unit == "l" else Decimal("1"))
    else: package = Decimal(observation["quantity"]); need = Decimal(required)
    package *= observation["pack_count"]
    count = int((need / package).to_integral_value(rounding="ROUND_CEILING"))
    excess = package * count - need
    return format(Decimal(observation["price"]) * count, "f"), format(excess, "f"), count


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
    cost_candidates = []
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
        outlay = package_outlay(row, staple) if not reasons else None
        if outlay:
            offer.update(purchase_cost=outlay[0], excess_quantity=outlay[1], packages_needed=outlay[2])
        offers.append(offer)
        if not reasons:
            candidates.append((normalized, row["id"]))
            if outlay:
                cost_candidates.append((Decimal(outlay[0]), row["id"]))
    winner_id = min(candidates)[1] if candidates else None
    return {"staple": staple, "offers": offers, "winner_id": winner_id,
            "unit_price_winner_id": winner_id,
            "purchase_cost_winner_id": min(cost_candidates)[1] if cost_candidates else None,
            "channel": channel,
            "gap": None if winner_id is not None else ("no_observations" if not offers else "no_eligible_offers")}
